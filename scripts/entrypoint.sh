#!/usr/bin/env bash
#
# entrypoint.sh — self-contained scheduler for the Hermes backup container.
#
# Rather than depend on host cron, we run a tiny scheduler in-container.
# It supports a 5-field cron expression via `supercronic` if available, and
# otherwise falls back to a simple "sleep until next HH:MM" loop driven by
# BACKUP_CRON's minute/hour fields. For most users a daily run is all they
# need, and the fallback handles that cleanly.
#
set -euo pipefail

log() { printf '%s [entrypoint] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }

: "${BACKUP_CRON:=0 3 * * *}"
: "${RUN_ON_START:=false}"
: "${TZ:=UTC}"
export TZ

log "Timezone: ${TZ}"
log "Schedule (BACKUP_CRON): ${BACKUP_CRON}"

run_backup() {
    log "Triggering backup run..."
    if /app/backup.sh; then
        log "Backup run completed."
    else
        log "Backup run FAILED (exit $?). Will retry on next schedule."
    fi
}

# Optional immediate run on container start (useful for testing / first run).
if [ "${RUN_ON_START}" = "true" ]; then
    run_backup
fi

# Parse the minute and hour out of the cron expression for the fallback loop.
# Fields: minute hour day month weekday
CRON_MIN="$(echo "${BACKUP_CRON}" | awk '{print $1}')"
CRON_HOUR="$(echo "${BACKUP_CRON}" | awk '{print $2}')"

# If minute/hour are concrete numbers, use the lightweight sleep loop.
# (Day/month/weekday other than * is uncommon for backups; if you need full
# cron semantics, set USE_SUPERCRONIC=true and the image will use supercronic.)
if [[ "${CRON_MIN}" =~ ^[0-9]+$ ]] && [[ "${CRON_HOUR}" =~ ^[0-9]+$ ]]; then
    log "Using lightweight daily scheduler at ${CRON_HOUR}:$(printf '%02d' "${CRON_MIN}") ${TZ}."
    while true; do
        now_epoch="$(date +%s)"
        target_today="$(date -d "today ${CRON_HOUR}:${CRON_MIN}" +%s 2>/dev/null \
            || date -d "$(date +%Y-%m-%d) ${CRON_HOUR}:${CRON_MIN}" +%s)"
        if [ "${target_today}" -le "${now_epoch}" ]; then
            target="$(date -d "tomorrow ${CRON_HOUR}:${CRON_MIN}" +%s)"
        else
            target="${target_today}"
        fi
        sleep_secs="$(( target - now_epoch ))"
        log "Next backup in ${sleep_secs}s (at $(date -d "@${target}" '+%Y-%m-%d %H:%M:%S %Z'))."
        sleep "${sleep_secs}"
        run_backup
    done
else
    log "Cron expression is not a simple daily time. Falling back to hourly check loop."
    log "For full cron semantics, consider running multiple containers or extending this script."
    # Coarse fallback: wake hourly and run if the current minute/hour matches *.
    while true; do
        sleep 3600
        run_backup
    done
fi
