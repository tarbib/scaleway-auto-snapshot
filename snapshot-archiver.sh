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

# rclone: "scw" remote defined solely via environment variables
export RCLONE_CONFIG="/tmp/rclone.conf"; : > "$RCLONE_CONFIG"
export RCLONE_CONFIG_SCW_TYPE="s3"
export RCLONE_CONFIG_SCW_PROVIDER="Scaleway"
export RCLONE_CONFIG_SCW_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export RCLONE_CONFIG_SCW_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
export RCLONE_CONFIG_SCW_REGION="$REGION"
export RCLONE_CONFIG_SCW_ENDPOINT="${S3_ENDPOINT:-https://s3.$REGION.scw.cloud}"

# Folder = name of the instance the volume is attached to, otherwise its UUID
LABEL="${LABEL:-}"
if [ -z "$LABEL" ]; then
  LABEL="$(scw instance server list zone="$ZONE" -o json 2>/dev/null \
    | jq -r --arg v "$VOLUME_ID" '.[] | select([.volumes[]?.id] | index($v)) | .name' \
    | head -n1)" || true
fi
[ -n "$LABEL" ] || LABEL="$VOLUME_ID"
LABEL="$(echo "$LABEL" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' | sed 's/-*$//')"

NAME="autosnap-$(date -u +%Y%m%d-%H%M%S)"
DIR="$PREFIX/$LABEL"
KEY="$DIR/$NAME.qcow2"

log "volume=$VOLUME_ID zone=$ZONE -> s3://$BUCKET/$KEY (retention=$RETENTION)"

VOLUME_TYPE="$(scw instance volume get "$VOLUME_ID" zone="$ZONE" -o json 2>/dev/null \
  | jq -r '.volume.volume_type // empty')" || true
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
  while :; do
    st="$(status "$1")"
    case "$st" in
      error|invalid_data)
        raw="$(scw instance snapshot get "$1" zone="$ZONE" -o json 2>&1)"
        detail="$(echo "$raw" | jq -c . 2>/dev/null)"
        [ -n "$detail" ] || detail="$(echo "$raw" | tr '\n' ' ')"
        log "error detail: $detail"
        die "snapshot $1 is '$st'"
        ;;
    esac
    if [ "$st" = "available" ]; then
      if [ -z "$2" ]; then
        return 0
      fi
      if rclone lsf "scw:$BUCKET/$2" 2>/dev/null | grep -q .; then
        return 0
      fi
    fi
    [ "$(date +%s)" -lt "$end" ] || die "timeout after ${3}s (status=$st)"
    sleep 15
  done
}

SNAP="$(scw instance snapshot create volume-id="$VOLUME_ID" name="$NAME" zone="$ZONE" -o json \
        | jq -r '.snapshot.id // .id')"
if [ -z "$SNAP" ] || [ "$SNAP" = "null" ]; then
  SNAP=""
  die "unable to create the snapshot.
  Likely cause: snapshots of Local Storage volumes (l_ssd) via the Instance API
  are no longer supported by Scaleway. The volume must be migrated to Block Storage
  (SBS), then 'scw instance snapshot' replaced with 'scw block snapshot' and
  '.snapshot.state' with '.status' in this script.
  https://www.scaleway.com/en/docs/instances/how-to/migrate-local-storage-to-sbs/"
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
log "export complete"

scw instance snapshot delete "$SNAP" zone="$ZONE" >/dev/null
log "snapshot deleted"
SNAP=""

rclone lsjson "scw:$BUCKET/$DIR" \
  | jq -r --argjson n "$RETENTION" \
      '[ .[] | select(.IsDir == false) | select(.Name | endswith(".qcow2")) ]
       | sort_by(.ModTime) | reverse | .[$n:] | .[] | .Path' \
  | while IFS= read -r obj; do
      [ -n "$obj" ] || continue
      log "retention: deleting $DIR/$obj"
      rclone deletefile "scw:$BUCKET/$DIR/$obj"
    done

log "done"
