# Self-contained image for backing up a Hermes Agent install and pushing
# the archive to Google Drive. Nothing is required on the host except Docker
# and the Hermes data directory you want to back up.
FROM debian:bookworm-slim

# --- base tooling -----------------------------------------------------------
# curl/ca-certificates: fetch installers
# unzip/tar/gzip: archive handling
# gnupg: optional encryption of the backup before upload
# tzdata: makes the in-container schedule respect TZ
# python3: Hermes installer pulls uv/python, but having python3 present avoids
#          a cold-start surprise on some bases
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        unzip \
        tar \
        gzip \
        gnupg \
        tzdata \
        bash \
        coreutils \
    && rm -rf /var/lib/apt/lists/*

# --- rclone (Google Drive client) ------------------------------------------
# Installed from the official static binary so we don't depend on distro repos.
RUN curl -fsSL https://rclone.org/install.sh | bash \
    && rclone version

# --- Hermes Agent CLI -------------------------------------------------------
# Installed into the image so the container does not rely on a host install.
# The installer drops binaries under ~/.local/bin and sets up its own python.
# We run it as root here; HERMES_HOME is overridden at runtime to the mounted
# data volume so the install's own home is only used for the CLI itself.
ENV HERMES_INSTALL_HOME=/opt/hermes
RUN mkdir -p ${HERMES_INSTALL_HOME} \
    && HOME=${HERMES_INSTALL_HOME} \
       curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash \
    || echo "WARNING: Hermes installer exited non-zero; see README troubleshooting."

# Put Hermes + uv on PATH for all later shells.
ENV PATH="/opt/hermes/.local/bin:${PATH}"

# --- backup runtime ---------------------------------------------------------
WORKDIR /app
COPY scripts/backup.sh /app/backup.sh
COPY scripts/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/backup.sh /app/entrypoint.sh

# Defaults (override via .env / compose). Documented in README.
ENV TZ=UTC \
    BACKUP_CRON="0 3 * * *" \
    HERMES_HOME=/data/hermes \
    OUTPUT_DIR=/backups \
    RCLONE_REMOTE=gdrive \
    RCLONE_REMOTE_PATH=hermes-backups \
    BACKUP_MODE=full \
    RETENTION_DAYS=14 \
    ENCRYPT=false \
    RUN_ON_START=false

ENTRYPOINT ["/app/entrypoint.sh"]
