#!/usr/bin/env bash
#
# Hermes Agent backup — runs INSIDE the backup container (scheduled by supercronic).
# -----------------------------------------------------------------------------
# Approach (option A): use Hermes' OWN `hermes backup` command, which uses
# SQLite's online backup() API to produce a CONSISTENT snapshot even while the
# agent is running — safer than a raw tar of a live SQLite database.
#
# What's mounted into this container (see docker-compose.yml):
#   - Your host ~/.hermes at /data        (READ-ONLY: we only read it)
#   - rclone config at /config/rclone     (persists the Google Drive token)
#   - a staging volume at /backups        (local working copy before upload)
#
# Environment variables (set on the service in docker-compose.yml):
#   RCLONE_REMOTE       - name of the configured rclone remote (e.g. gdrive)
#   RCLONE_DEST_PATH    - folder path inside Google Drive
#   RETENTION_DAYS      - how many days of dated folders to keep
#   BACKUP_MODE         - full | quick
#   ENCRYPT             - true | false (gpg AES-256 before upload)
#   GPG_PASSPHRASE      - required when ENCRYPT=true
#   TZ                  - timezone (also drives the cron schedule)

set -euo pipefail

# ---- Settings (overridable via env) ----------------------------------------
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"
RCLONE_DEST_PATH="${RCLONE_DEST_PATH:-hermes-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
BACKUP_MODE="${BACKUP_MODE:-full}"        # full | quick
ENCRYPT="${ENCRYPT:-false}"
BACKUP_LABEL="${BACKUP_LABEL:-scheduled}"
# Hermes reads its data from here. /data is the read-only mount of host ~/.hermes.
export HERMES_HOME="${HERMES_HOME:-/data}"
# supercronic runs jobs with a minimal PATH. Make sure the Hermes CLI and its
# managed uv/python (root FHS install) are reachable regardless of how we're
# invoked (cron vs. interactive `backup-now`).
export PATH="/usr/local/bin:/usr/local/share/uv/bin:/usr/bin:/bin:${PATH}"
# ----------------------------------------------------------------------------

DATE="$(date +%Y-%m-%d)"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
WORK_DIR="/backups/${DATE}"
LOG_TAG="[hermes-backup ${STAMP}]"

log() { echo "${LOG_TAG} $*"; }
die() { echo "${LOG_TAG} ERROR: $*" >&2; exit 1; }

log "starting (mode=${BACKUP_MODE}, HERMES_HOME=${HERMES_HOME})"

# ---- Preflight -------------------------------------------------------------
command -v hermes >/dev/null 2>&1 \
    || die "hermes CLI not found on PATH. The image build step for Hermes likely failed — see README troubleshooting."
command -v rclone >/dev/null 2>&1 \
    || die "rclone not found on PATH."

[ -d "${HERMES_HOME}" ] \
    || die "HERMES_HOME (${HERMES_HOME}) is not mounted. Check the bind mount of your host ~/.hermes in docker-compose.yml."

# Fail early if the rclone remote isn't configured, before spending time on the archive.
if ! rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
    die "rclone remote '${RCLONE_REMOTE}:' not configured. Run the host-side auth flow and copy rclone.conf in (README section 4)."
fi

mkdir -p "$WORK_DIR"

# ---- 1. Create the Hermes backup (consistent snapshot) ---------------------
ARCHIVE="${WORK_DIR}/hermes-backup_${STAMP}.zip"

HERMES_ARGS=(backup -o "${ARCHIVE}")
if [ "${BACKUP_MODE}" = "quick" ]; then
    HERMES_ARGS+=(--quick --label "${BACKUP_LABEL}")
fi

log "running: hermes ${HERMES_ARGS[*]}"
hermes "${HERMES_ARGS[@]}" || die "hermes backup failed (see output above)."
[ -f "${ARCHIVE}" ] || die "expected archive not found at ${ARCHIVE} after backup."
log "archive created: $(basename "${ARCHIVE}") ($(du -h "${ARCHIVE}" | cut -f1))"

UPLOAD_TARGET="${ARCHIVE}"

# ---- 2. Optional encryption ------------------------------------------------
# The Hermes archive contains your .env (API keys, bot tokens). Encrypt before
# it leaves the machine.
if [ "${ENCRYPT}" = "true" ]; then
    [ -n "${GPG_PASSPHRASE:-}" ] || die "ENCRYPT=true but GPG_PASSPHRASE is not set."
    ENC="${ARCHIVE}.gpg"
    log "encrypting archive with gpg (AES-256)..."
    gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase "${GPG_PASSPHRASE}" \
        -o "${ENC}" "${ARCHIVE}"
    rm -f "${ARCHIVE}"          # don't keep the plaintext copy around
    UPLOAD_TARGET="${ENC}"
    log "encrypted: $(basename "${ENC}")"
fi

# ---- 3. Upload to Google Drive (dated folder) ------------------------------
log "uploading to ${RCLONE_REMOTE}:${RCLONE_DEST_PATH}/${DATE} ..."
rclone copy "$WORK_DIR" "${RCLONE_REMOTE}:${RCLONE_DEST_PATH}/${DATE}" \
    --transfers=4 --checkers=8 --contimeout=60s --timeout=300s --retries=3 \
    || die "rclone upload failed. Local copy preserved under ${WORK_DIR}."
log "upload complete."

# ---- 4. Prune old backups (local + remote) ---------------------------------
if [ "${RETENTION_DAYS}" -gt 0 ] 2>/dev/null; then
    log "pruning local backups older than ${RETENTION_DAYS} days..."
    find /backups -mindepth 1 -maxdepth 1 -type d -mtime +"${RETENTION_DAYS}" \
        -exec rm -rf {} + || true

    log "pruning remote backups older than ${RETENTION_DAYS} days..."
    rclone delete "${RCLONE_REMOTE}:${RCLONE_DEST_PATH}" \
        --min-age "${RETENTION_DAYS}d" --rmdirs || true
else
    log "retention disabled (RETENTION_DAYS=0) — keeping everything."
fi

log "done."
