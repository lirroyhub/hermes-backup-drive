FROM debian:bookworm-slim

# --- Install backup tooling -------------------------------------------------
# rclone          : upload to Google Drive (runs in Linux, so no macOS dyld wall)
# ca-certificates : TLS for rclone -> Google, GitHub, and the Hermes installer
# tzdata          : so the cron schedule respects your timezone
# gnupg           : optional AES-256 encryption of the archive before upload
# bash/coreutils  : the backup script is bash and uses date/find/du
# curl            : fetch supercronic + the Hermes installer (kept; Hermes may
#                   shell out to it at runtime)
# xz-utils        : the Hermes installer downloads Node.js as a .tar.xz and needs
#                   `xz` to extract it; debian-slim does NOT ship it by default.
# git             : the Hermes installer requires git (it auto-apt-installs it
#                   otherwise, but we pre-install so the build is deterministic).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
        curl \
        gnupg \
        bash \
        coreutils \
        unzip \
        xz-utils \
        git \
        rclone \
    && rm -rf /var/lib/apt/lists/*

# --- Install supercronic (container-native cron) ----------------------------
# Container-native cron that runs as PID 1, handles SIGTERM gracefully, honors
# real 5-field cron syntax, and logs job output to stdout/stderr (so it shows
# in `docker compose logs`). amd64 build for Intel Macs / x86_64 hosts.
# Version pinned and SHA1-verified so a tampered/truncated download fails the
# build instead of silently shipping.
#
# NOTE: if you run on Apple Silicon (M1/M2/M3) WITHOUT Rosetta for the Docker
# builder, switch this to the arm64 asset + its checksum from the supercronic
# releases page. See README "Architecture notes".
ENV SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.29/supercronic-linux-amd64 \
    SUPERCRONIC=supercronic-linux-amd64 \
    SUPERCRONIC_SHA1SUM=cd48d45c4b10f3f0bfdd3a57d054cd05ac96812b

RUN curl -fsSLO "$SUPERCRONIC_URL" \
    && echo "${SUPERCRONIC_SHA1SUM}  ${SUPERCRONIC}" | sha1sum -c - \
    && chmod +x "$SUPERCRONIC" \
    && mv "$SUPERCRONIC" "/usr/local/bin/${SUPERCRONIC}" \
    && ln -s "/usr/local/bin/${SUPERCRONIC}" /usr/local/bin/supercronic

# --- Install the Hermes Agent CLI ------------------------------------------
# Installed into the image so the container does not rely on a host Hermes
# install. We only need the CLI; the agent's own data lives in the read-only
# /data mount at runtime (HERMES_HOME is set per-run by backup.sh).
#
# IMPORTANT: when run as root on Linux, the installer ignores $HOME and uses a
# fixed FHS layout — command at /usr/local/bin/hermes, code under
# /usr/local/lib/hermes-agent, and its managed uv/python under
# /usr/local/share/uv. /usr/local/bin is already on PATH, so no PATH edit is
# needed. We let it use that layout rather than fighting it.
#
# Unlike the earlier draft, we DO NOT swallow installer failure: a backup image
# without a working `hermes` is useless, so we verify the binary exists and the
# build FAILS loudly if the install didn't complete. The required decompressors
# (xz-utils) and git are pre-installed above so the install is deterministic.
RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash \
    && command -v hermes >/dev/null 2>&1 \
    && hermes --version

# --- App files --------------------------------------------------------------
COPY crontab /app/crontab
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh \
    # Friendly alias so `docker compose run --rm backup backup-now` works.
    && ln -s /usr/local/bin/backup.sh /usr/local/bin/backup-now

WORKDIR /app

# supercronic must be PID 1 so it handles SIGTERM/SIGINT gracefully.
# It inherits all container env vars and logs job output to stdout/stderr,
# which surface via `docker compose logs backup`.
CMD ["supercronic", "/app/crontab"]
