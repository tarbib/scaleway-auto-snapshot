#!/bin/sh
# Snapshot an Instance volume -> export QCOW2 to a bucket
# -> delete the snapshot -> retain the N most recent exports.
set -eu

: "${SCW_ACCESS_KEY:?required}"
: "${SCW_SECRET_KEY:?required}"
: "${VOLUME_ID:?required}"
: "${BUCKET:?required}"

ZONE="${ZONE:-${SCW_DEFAULT_ZONE:-fr-par-1}}"
REGION="${REGION:-$(echo "$ZONE" | sed 's/-[0-9]*$//')}"
RETENTION="${RETENTION:-3}"
PREFIX="${PREFIX:-snapshots}"
EXPORT_TIMEOUT="${EXPORT_TIMEOUT:-7200}"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR $*" >&2; exit 1; }

case "$RETENTION" in
  ''|*[!0-9]*) die "RETENTION must be a positive integer (got '$RETENTION')" ;;
esac
[ "$RETENTION" -ge 1 ] || die "RETENTION must be >= 1 (0 would delete every export on each run, including the one just created)"
case "$EXPORT_TIMEOUT" in
  ''|*[!0-9]*) die "EXPORT_TIMEOUT must be a positive integer number of seconds (got '$EXPORT_TIMEOUT')" ;;
esac

# rclone: "scw" remote defined solely via environment variables
export RCLONE_CONFIG="/tmp/rclone.conf"; : > "$RCLONE_CONFIG"
export RCLONE_CONFIG_SCW_TYPE="s3"
export RCLONE_CONFIG_SCW_PROVIDER="Scaleway"
export RCLONE_CONFIG_SCW_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export RCLONE_CONFIG_SCW_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
export RCLONE_CONFIG_SCW_REGION="$REGION"
export RCLONE_CONFIG_SCW_ENDPOINT="${S3_ENDPOINT:-https://s3.$REGION.scw.cloud}"

# Single lookup: gives both the owning server's name (for LABEL) and the volume type.
VOLUME_INFO="$(scw instance volume get "$VOLUME_ID" zone="$ZONE" -o json 2>/dev/null)" || VOLUME_INFO=""

# Folder = name of the instance the volume is attached to, otherwise its UUID
LABEL="${LABEL:-}"
if [ -z "$LABEL" ]; then
  LABEL="$(echo "$VOLUME_INFO" | jq -r '.volume.server.name // empty' 2>/dev/null)" || LABEL=""
fi
[ -n "$LABEL" ] || LABEL="$VOLUME_ID"
LABEL="$(echo "$LABEL" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' | sed 's/-*$//')"

NAME="autosnap-$(date -u +%Y%m%d-%H%M%S)"
DIR="$PREFIX/$LABEL"
KEY="$DIR/$NAME.qcow2"

log "volume=$VOLUME_ID zone=$ZONE -> s3://$BUCKET/$KEY (retention=$RETENTION)"

VOLUME_TYPE="$(echo "$VOLUME_INFO" | jq -r '.volume.volume_type // empty' 2>/dev/null)" || VOLUME_TYPE=""
if [ "$VOLUME_TYPE" = "l_ssd" ]; then
  log "INFO: Local Storage volume (l_ssd). Export to Object Storage is supported for this type, but if the snapshot goes to 'error'/'invalid_data' during export, check: bucket SSE-KMS encryption (not supported), snapshot size (must be between 1 GB and 1 TB), and IAM permissions on the bucket."
fi

# If the script stops (error, timeout) before the snapshot is deleted normally,
# avoid leaving it orphaned (otherwise it keeps being billed).
SNAP=""
cleanup() {
  if [ -n "$SNAP" ]; then
    log "cleanup: deleting snapshot $SNAP following an error"
    scw instance snapshot delete "$SNAP" zone="$ZONE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

status() {
  raw="$(scw instance snapshot get "$1" zone="$ZONE" -o json 2>&1)" || {
    log "warning: 'scw instance snapshot get' failed (retrying): $(echo "$raw" | tr '\n' ' ')"
    echo "unknown"
    return 0
  }
  STATUS_RAW="$raw"
  st="$(echo "$raw" | jq -r '.snapshot.state // .state' 2>&1)" || {
    log "warning: non-JSON response from scw (retrying): $(echo "$raw" | tr '\n' ' ')"
    echo "unknown"
    return 0
  }
  echo "$st"
}

# Wait for a stable status. If $2 is set, also wait for the object to be
# visible in the bucket: multipart upload only publishes it at the end.
wait_stable() {
  end=$(( $(date +%s) + $3 ))
  fail_count=0
  while :; do
    st="$(status "$1")"
    if [ "$st" = "unknown" ]; then
      fail_count=$((fail_count + 1))
      [ "$fail_count" -lt 5 ] || die "unable to query snapshot $1 status after $fail_count consecutive attempts"
    else
      fail_count=0
    fi
    case "$st" in
      error|invalid_data)
        detail="$(echo "$STATUS_RAW" | jq -c . 2>/dev/null)"
        [ -n "$detail" ] || detail="$(echo "$STATUS_RAW" | tr '\n' ' ')"
        log "error detail: $detail"
        die "snapshot $1 is '$st'"
        ;;
    esac
    if [ "$st" = "available" ]; then
      if [ -z "$2" ]; then
        return 0
      fi
      size_out="$(rclone lsf --format s "scw:$BUCKET/$2" 2>&1)" || die "bucket visibility check failed: $(echo "$size_out" | tr '\n' ' ')"
      case "$size_out" in
        *[!0-9]*|'') : ;;  # object not visible yet, keep waiting
        0) log "warning: export object exists but is 0 bytes so far, waiting" ;;
        *) EXPORT_SIZE="$size_out"; return 0 ;;
      esac
    fi
    [ "$(date +%s)" -lt "$end" ] || die "timeout after ${3}s (status=$st)"
    sleep 15
  done
}

die_snapshot_create_failed() {
  die "unable to create the snapshot.
  Likely cause: snapshots of Local Storage volumes (l_ssd) via the Instance API
  are no longer supported by Scaleway. The volume must be migrated to Block Storage
  (SBS), then 'scw instance snapshot' replaced with 'scw block snapshot' and
  '.snapshot.state' with '.status' in this script.
  https://www.scaleway.com/en/docs/instances/how-to/migrate-local-storage-to-sbs/"
}

if ! CREATE_OUT="$(scw instance snapshot create volume-id="$VOLUME_ID" name="$NAME" zone="$ZONE" -o json)"; then
  die_snapshot_create_failed
fi
SNAP="$(echo "$CREATE_OUT" | jq -r '.snapshot.id // .id' 2>/dev/null)" || SNAP=""
if [ -z "$SNAP" ] || [ "$SNAP" = "null" ]; then
  SNAP=""
  die_snapshot_create_failed
fi
log "snapshot $SNAP created"

wait_stable "$SNAP" "" 1800
EXPORT_OUT="$(scw instance snapshot export \
  snapshot-id="$SNAP" bucket="$BUCKET" key="$KEY" zone="$ZONE" 2>&1)" || {
  log "error detail (export): $(echo "$EXPORT_OUT" | tr '\n' ' ')"
  die "export call failed"
}
log "export in progress..."

wait_stable "$SNAP" "$KEY" "$EXPORT_TIMEOUT"
log "export complete: s3://$BUCKET/$KEY (${EXPORT_SIZE:-unknown} bytes)"

scw instance snapshot delete "$SNAP" zone="$ZONE" >/dev/null
log "snapshot deleted"
SNAP=""

# Written to files (not piped) so a failure at any stage reaches die() instead
# of being swallowed by the exit status of the final pipeline stage.
RETENTION_LIST="/tmp/retention.json"
RETENTION_STALE="/tmp/retention-stale.txt"

rclone lsjson "scw:$BUCKET/$DIR" > "$RETENTION_LIST" || die "retention: 'rclone lsjson' failed"
# 0-byte (or smaller) exports are leftovers from a failed/interrupted run: they
# don't count as a real backup, so they're excluded from the N kept and always
# deleted, regardless of retention.
jq -r --argjson n "$RETENTION" \
  '[ .[] | select(.IsDir == false) | select(.Name | endswith(".qcow2")) ] as $all
   | ($all | map(select(.Size > 0)) | sort_by(.ModTime) | reverse | .[$n:])
     + ($all | map(select(.Size <= 0)))
   | .[] | .Path' \
  "$RETENTION_LIST" > "$RETENTION_STALE" || die "retention: failed to compute stale objects"

while IFS= read -r obj; do
  [ -n "$obj" ] || continue
  log "retention: deleting $DIR/$obj"
  rclone deletefile "scw:$BUCKET/$DIR/$obj" || die "retention: failed to delete $DIR/$obj"
done < "$RETENTION_STALE"
rm -f "$RETENTION_LIST" "$RETENTION_STALE"

log "done"
