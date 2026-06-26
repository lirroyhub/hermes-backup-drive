#!/usr/bin/env bash
#
# backup.sh — produce a Hermes Agent backup archive and push it to Google Drive.
#
# Designed to run inside the container built from the accompanying Dockerfile.
# All configuration comes from environment variables (see README).
#
set -euo pipefail

log() { printf '%s [hermes-backup] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# --- config with sane fallbacks --------------------------------------------
: "${HERMES_HOME:=/data/hermes}"
: "${OUTPUT_DIR:=/backups}"
: "${RCLONE_REMOTE:=gdrive}"
: "${RCLONE_REMOTE_PATH:=hermes-backups}"
: "${BACKUP_MODE:=full}"        # full | quick
: "${RETENTION_DAYS:=14}"       # local + remote pruning; 0 disables
: "${ENCRYPT:=false}"           # true => gpg-encrypt before upload
: "${BACKUP_LABEL:=scheduled}"

export HERMES_HOME

mkdir -p "${OUTPUT_DIR}"

# --- preflight --------------------------------------------------------------
command -v hermes >/dev/null 2>&1 || die "hermes CLI not found on PATH. Check the image build (see README troubleshooting)."
command -v rclone >/dev/null 2>&1 || die "rclone not found on PATH."

if [ ! -d "${HERMES_HOME}" ]; then
    die "HERMES_HOME (${HERMES_HOME}) does not exist or is not mounted. Mount your ~/.hermes into the container."
fi

# Verify the rclone remote actually exists before we spend time making an archive.
if ! rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
    die "rclone remote '${RCLONE_REMOTE}:' not configured. Mount an rclone.conf with this remote (see README)."
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# --- 1. create the Hermes backup -------------------------------------------
# hermes backup uses SQLite's backup() API, so it is safe even if the agent
# is running. We point -o at our workdir so we control the filename.
ARCHIVE="${WORKDIR}/hermes-backup-${STAMP}.zip"

HERMES_ARGS=(backup -o "${ARCHIVE}")
if [ "${BACKUP_MODE}" = "quick" ]; then
    HERMES_ARGS+=(--quick --label "${BACKUP_LABEL}")
fi

log "Running: hermes ${HERMES_ARGS[*]}  (HERMES_HOME=${HERMES_HOME})"
if ! hermes "${HERMES_ARGS[@]}"; then
    die "hermes backup failed. See output above."
fi

[ -f "${ARCHIVE}" ] || die "Expected archive not found at ${ARCHIVE} after backup."
log "Archive created: $(basename "${ARCHIVE}") ($(du -h "${ARCHIVE}" | cut -f1))"

UPLOAD_FILE="${ARCHIVE}"

# --- 2. optional encryption -------------------------------------------------
if [ "${ENCRYPT}" = "true" ]; then
    [ -n "${GPG_PASSPHRASE:-}" ] || die "ENCRYPT=true but GPG_PASSPHRASE is not set."
    ENC="${ARCHIVE}.gpg"
    log "Encrypting archive with gpg (AES-256)..."
    gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase "${GPG_PASSPHRASE}" \
        -o "${ENC}" "${ARCHIVE}"
    UPLOAD_FILE="${ENC}"
    log "Encrypted: $(basename "${ENC}")"
fi

# --- 3. keep a local copy ---------------------------------------------------
cp "${UPLOAD_FILE}" "${OUTPUT_DIR}/"
LOCAL_COPY="${OUTPUT_DIR}/$(basename "${UPLOAD_FILE}")"
log "Local copy saved: ${LOCAL_COPY}"

# --- 4. upload to Google Drive ---------------------------------------------
REMOTE_DEST="${RCLONE_REMOTE}:${RCLONE_REMOTE_PATH}"
log "Uploading to ${REMOTE_DEST}/ ..."
if ! rclone copy "${UPLOAD_FILE}" "${REMOTE_DEST}/" --progress --stats-one-line; then
    die "rclone upload failed. Local copy is preserved at ${LOCAL_COPY}."
fi
log "Upload complete."

# --- 5. retention -----------------------------------------------------------
if [ "${RETENTION_DAYS}" -gt 0 ] 2>/dev/null; then
    log "Pruning backups older than ${RETENTION_DAYS} days (local + remote)..."

    # local
    find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'hermes-backup-*' \
        -mtime "+${RETENTION_DAYS}" -print -delete || true

    # remote (rclone understands a max-age window; we delete what's older)
    rclone delete "${REMOTE_DEST}/" \
        --min-age "${RETENTION_DAYS}d" \
        --include 'hermes-backup-*' || log "WARN: remote prune reported an issue (non-fatal)."
    log "Retention pass done."
else
    log "Retention disabled (RETENTION_DAYS=0)."
fi

log "Backup run finished successfully."
