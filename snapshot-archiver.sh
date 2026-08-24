#!/bin/sh
# Snapshot d'un volume Instance -> export QCOW2 vers un bucket
# -> suppression du snapshot -> retention des N derniers exports.
set -eu

: "${SCW_ACCESS_KEY:?requis}"
: "${SCW_SECRET_KEY:?requis}"
: "${VOLUME_ID:?requis}"
: "${BUCKET:?requis}"

ZONE="${ZONE:-${SCW_DEFAULT_ZONE:-fr-par-1}}"
REGION="${REGION:-$(echo "$ZONE" | sed 's/-[0-9]*$//')}"
RETENTION="${RETENTION:-3}"
PREFIX="${PREFIX:-snapshots}"
EXPORT_TIMEOUT="${EXPORT_TIMEOUT:-7200}"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERREUR $*" >&2; exit 1; }

# rclone : remote "scw" defini uniquement par variables d'environnement
export RCLONE_CONFIG="/tmp/rclone.conf"; : > "$RCLONE_CONFIG"
export RCLONE_CONFIG_SCW_TYPE="s3"
export RCLONE_CONFIG_SCW_PROVIDER="Scaleway"
export RCLONE_CONFIG_SCW_ACCESS_KEY_ID="$SCW_ACCESS_KEY"
export RCLONE_CONFIG_SCW_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
export RCLONE_CONFIG_SCW_REGION="$REGION"
export RCLONE_CONFIG_SCW_ENDPOINT="${S3_ENDPOINT:-https://s3.$REGION.scw.cloud}"

# Dossier = nom de l'instance a laquelle le volume est attache, sinon son UUID
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
  log "INFO : volume en Local Storage (l_ssd). L'export vers Object Storage est supporte pour ce type, mais si le snapshot passe en 'error'/'invalid_data' pendant l'export, verifier : chiffrement SSE-KMS du bucket (non supporte), taille du snapshot (doit etre entre 1 Go et 1 To), et les permissions IAM sur le bucket."
fi

# Si le script s'arrete (erreur, timeout) avant la suppression normale du
# snapshot, on evite de le laisser orphelin (il continue sinon a etre facture).
SNAP=""
cleanup() {
  if [ -n "$SNAP" ]; then
    log "nettoyage : suppression du snapshot $SNAP suite a une erreur"
    scw instance snapshot delete "$SNAP" zone="$ZONE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

status() {
  raw="$(scw instance snapshot get "$1" zone="$ZONE" -o json 2>&1)" || {
    log "avertissement : echec de 'scw instance snapshot get' (retente) : $(echo "$raw" | tr '\n' ' ')"
    echo "unknown"
    return 0
  }
  st="$(echo "$raw" | jq -r '.snapshot.state // .state' 2>&1)" || {
    log "avertissement : reponse non-JSON de scw (retente) : $(echo "$raw" | tr '\n' ' ')"
    echo "unknown"
    return 0
  }
  echo "$st"
}

# Attend un statut stable. Si $2 est renseigne, attend aussi que l'objet soit
# visible dans le bucket : l'upload multipart ne le publie qu'a la fin.
wait_stable() {
  end=$(( $(date +%s) + $3 ))
  while :; do
    st="$(status "$1")"
    case "$st" in
      error|invalid_data)
        raw="$(scw instance snapshot get "$1" zone="$ZONE" -o json 2>&1)"
        detail="$(echo "$raw" | jq -c . 2>/dev/null)"
        [ -n "$detail" ] || detail="$(echo "$raw" | tr '\n' ' ')"
        log "detail de l'erreur : $detail"
        die "snapshot $1 en '$st'"
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
    [ "$(date +%s)" -lt "$end" ] || die "timeout apres $3s (statut=$st)"
    sleep 15
  done
}

SNAP="$(scw instance snapshot create volume-id="$VOLUME_ID" name="$NAME" zone="$ZONE" -o json \
        | jq -r '.snapshot.id // .id')"
if [ -z "$SNAP" ] || [ "$SNAP" = "null" ]; then
  SNAP=""
  die "creation du snapshot impossible.
  Cause probable : les snapshots de volumes Local Storage (l_ssd) via l'API Instance
  ne sont plus supportes par Scaleway. Il faut migrer le volume vers Block Storage
  (SBS), puis remplacer 'scw instance snapshot' par 'scw block snapshot' et
  '.snapshot.state' par '.status' dans ce script.
  https://www.scaleway.com/en/docs/instances/how-to/migrate-local-storage-to-sbs/"
fi
log "snapshot $SNAP cree"

wait_stable "$SNAP" "" 1800
EXPORT_OUT="$(scw instance snapshot export \
  snapshot-id="$SNAP" bucket="$BUCKET" key="$KEY" zone="$ZONE" 2>&1)" || {
  log "detail de l'erreur (export) : $(echo "$EXPORT_OUT" | tr '\n' ' ')"
  die "echec de l'appel export"
}
log "export en cours..."

wait_stable "$SNAP" "$KEY" "$EXPORT_TIMEOUT"
log "export termine"

scw instance snapshot delete "$SNAP" zone="$ZONE" >/dev/null
log "snapshot supprime"
SNAP=""

rclone lsjson "scw:$BUCKET/$DIR" \
  | jq -r --argjson n "$RETENTION" \
      '[ .[] | select(.IsDir == false) | select(.Name | endswith(".qcow2")) ]
       | sort_by(.ModTime) | reverse | .[$n:] | .[] | .Path' \
  | while IFS= read -r obj; do
      [ -n "$obj" ] || continue
      log "retention : suppression de $DIR/$obj"
      rclone deletefile "scw:$BUCKET/$DIR/$obj"
    done

log "termine"
