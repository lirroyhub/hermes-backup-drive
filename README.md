# Hermes Agent → Google Drive Backup (Dockerized)

A small, standalone Docker Compose stack that backs up a **[Hermes Agent](https://github.com/NousResearch/hermes-agent)**
install running directly on your machine, and uploads the archive to **Google
Drive** on a daily schedule — with optional encryption and automatic retention.

It runs Hermes' own `hermes backup` command (which takes a *consistent* SQLite
snapshot even while the agent is running), inside a container, so the only
things you need on the host are Docker and rclone-for-auth (one-time).

> **Scope:** this stack does **not** run Hermes. It assumes Hermes is already
> installed and running on the host, and backs up its data directory
> (`~/.hermes`). The backup container is the only service here.

---

## How it works

A container-native cron (`supercronic`) runs once a day (default 03:30, your
timezone) and executes `backup.sh`, which:

1. Runs `hermes backup` against your mounted `~/.hermes` → a consistent zip
   (config, skills, sessions, memory). Uses SQLite's online `backup()` API, so
   it's safe even while the agent is live.
2. Optionally encrypts the zip with `gpg` (AES-256).
3. Uploads it to a **dated folder** in Google Drive
   (`gdrive:hermes-backups/2026-06-26/`) via rclone.
4. Keeps a local staging copy and prunes anything older than `RETENTION_DAYS`,
   both locally and on Drive.

```
┌──────────────────────────── your Mac / Linux host ────────────────────────┐
│                                                                            │
│   Hermes Agent (installed natively)  ──writes──►  ~/.hermes                │
│                                                      │ (bind mount, ro)    │
│   ┌─────────────── docker compose (this repo) ───────┼──────────────────┐  │
│   │  backup container                                ▼                  │  │
│   │   supercronic ──► backup.sh ──► hermes backup ──► /data (ro)         │  │
│   │                         │                                           │  │
│   │                         ├─► gpg (optional)                          │  │
│   │                         └─► rclone copy ──────────────────────────► │──┼──► Google Drive
│   └─────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Requirements

- Docker + Docker Compose on the host.
- A Hermes install on the host (its data dir, normally `~/.hermes`).
- A Google account / Google Drive.
- rclone on the host **once**, only to authorize Google Drive (see section 4).
  On macOS Catalina, use the bundled installer for a compatible build.

---

## 1. Get the repo and configure

```bash
git clone <your-repo-url> hermes-backup
cd hermes-backup

cp .env.example .env
$EDITOR .env
```

In `.env`, the one value you **must** get right is `HERMES_DATA_PATH` — the
absolute path to your Hermes data dir on the host:

```ini
HERMES_DATA_PATH=/Users/you/.hermes      # macOS
# HERMES_DATA_PATH=/home/you/.hermes     # Linux
# HERMES_DATA_PATH=/root/.hermes         # root install
```

Use an **absolute** path. A literal `~` is unreliable as a Compose volume
source.

---

## 2. Build the image

```bash
docker compose build
```

This installs rclone, supercronic, and the Hermes CLI into the image. The
Hermes installer needs outbound access to `github.com` and
`raw.githubusercontent.com`.

> If the Hermes install step errors, the build still finishes (so a transient
> network blip doesn't wipe your tooling). `backup.sh` checks for the `hermes`
> binary at runtime and fails with a clear message. See **Troubleshooting**.

---

## 3. Start the scheduler

```bash
docker compose up -d
docker compose logs -f          # watch it report the schedule
```

The container now sits idle until the daily cron fires. It restarts on reboot
(`restart: unless-stopped`).

---

## 4. Connect Google Drive (one-time, host-side)

**Why host-side:** authorizing rclone from *inside* the container does not work
on a Mac. rclone's OAuth flow opens a local server on `127.0.0.1:53682` that
your host browser can't reach across the container boundary. So you authorize
on the host, then copy the resulting config into the container's volume.

### 4a. Install rclone on the host (skip if you already have it)

Modern macOS / Linux: `curl -fsSL https://rclone.org/install.sh | sudo bash`

**macOS Catalina (10.15):** newer rclone builds crash with a `dyld: Symbol not
found: _SecTrustCopyCertificateChain` error. Use the bundled installer, which
pins the last Catalina-compatible release (v1.70.3) into `~/bin`, no sudo:

```bash
./install-rclone-catalina.sh
```

### 4b. Authorize Google Drive

```bash
rclone config
#  n) New remote
#  name> gdrive                 # MUST match RCLONE_REMOTE in .env
#  Storage> drive               # Google Drive
#  client_id / client_secret>   # Enter for rclone defaults (fine for personal use)
#  scope> 1                     # full access  (or 3 = drive.file, app-created files only)
#  Edit advanced config> n
#  Use auto config> y           # opens a browser to authorize
#  Shared Drive (Team Drive)> n (unless you use one)
#  y) Yes this is OK   →   q) Quit
```

Headless host with no browser? Answer **n** to "Use auto config" and follow
rclone's `rclone authorize "drive"` prompt on a machine that has a browser,
then paste the token back.

### 4c. Copy the host config into the container's rclone volume

```bash
docker compose run --rm \
  -v ~/.config/rclone:/host-rclone:ro \
  backup sh -c "mkdir -p /config/rclone && cp /host-rclone/rclone.conf /config/rclone/rclone.conf && echo copied"
```

(On Catalina the host config is in the same place: `~/.config/rclone/rclone.conf`.)

### 4d. Verify

```bash
docker compose run --rm backup rclone listremotes      # should list: gdrive:
docker compose run --rm backup rclone lsd gdrive:       # should list your Drive folders
```

The credential now lives in the `backup-rclone` named volume and survives image
rebuilds.

---

## 5. Test it end-to-end (don't wait for 03:30)

```bash
docker compose run --rm backup backup-now
```

Watch it go: `hermes backup` → (encrypt) → upload → prune, ending in `done.`
Then confirm the file landed:

```bash
docker compose run --rm backup rclone ls gdrive:hermes-backups
```

…and check Google Drive in a browser. You should see a dated folder with a
`hermes-backup_<timestamp>.zip` (or `.zip.gpg` if encryption is on).

---

## 6. Restore (test this at least once)

A backup you've never restored is a hope, not a backup.

```bash
# If encrypted, decrypt first:
gpg --decrypt hermes-backup_YYYY-MM-DD_HHMMSS.zip.gpg > restore.zip

# Stop Hermes on the host first to avoid conflicts, then:
hermes import restore.zip            # prompts before overwriting
hermes import restore.zip --force    # overwrite without prompting
```

Do this once against a scratch profile or throwaway machine so you trust it.

---

## Configuration reference

All in `.env`:

| Variable           | Default             | Description                                                         |
|--------------------|---------------------|---------------------------------------------------------------------|
| `HERMES_DATA_PATH` | `/Users/you/.hermes`| **Absolute** host path to the Hermes data dir (mounted read-only).  |
| `BACKUP_MODE`      | `full`              | `full` (complete) or `quick` (state-only fast snapshot).            |
| `RETENTION_DAYS`   | `30`                | Delete dated backups older than N days, local + Drive. `0` = keep all. |
| `TZ`               | `America/Montevideo`| Timezone for schedule and container clock.                          |
| `ENCRYPT`          | `false`             | `true` to gpg-encrypt (AES-256) before upload.                      |
| `GPG_PASSPHRASE`   | _(empty)_           | Required if `ENCRYPT=true`. Store OUTSIDE this repo.                 |
| `RCLONE_REMOTE`    | `gdrive`            | rclone remote name (must match what you configured).                |
| `RCLONE_DEST_PATH` | `hermes-backups`    | Folder path inside Drive; dated subfolders created underneath.      |

**Change the schedule:** edit `backup/crontab` (5-field cron) and rebuild
(`docker compose up -d --build`). Default `30 3 * * *` = daily at 03:30.

---

## Architecture notes

The Dockerfile pulls the **amd64** supercronic build, correct for Intel Macs
and most Linux hosts. On **Apple Silicon** without Rosetta in the Docker
builder, swap `SUPERCRONIC_URL`/`SUPERCRONIC`/`SUPERCRONIC_SHA1SUM` in
`backup/Dockerfile` to the `arm64` asset and its checksum from the
[supercronic releases](https://github.com/aptible/supercronic/releases).

---

## Project layout

```
hermes-backup/
├── docker-compose.yml          # the single backup service + named volumes
├── .env.example                # copy to .env and edit
├── .gitignore                  # keeps secrets, creds, backups out of git
├── install-rclone-catalina.sh  # host-side rclone for macOS 10.15
├── README.md
└── backup/
    ├── Dockerfile              # debian + rclone + supercronic + hermes CLI
    ├── backup.sh               # hermes backup → (encrypt) → Drive → prune
    └── crontab                 # supercronic schedule (daily 03:30)
```

---

## Troubleshooting

**`hermes CLI not found on PATH` at runtime / build fails on the Hermes step.**
The image build runs Hermes' installer, which downloads Node.js as a `.tar.xz`
and shells out to `git`; on debian-slim those decompressors aren't present by
default. This image pre-installs `xz-utils` and `git` so the install is
deterministic, and the build now *fails loudly* (runs `hermes --version`) rather
than shipping a broken image. If it still fails, rebuild with logs visible:
`docker compose build --no-cache --progress=plain` and read the Hermes step. The
installer needs `github.com` + `raw.githubusercontent.com` reachable. Note the
installer uses a root FHS layout (`/usr/local/bin/hermes`), already on PATH.

**`rclone remote 'gdrive:' not configured`.**
Section 4 didn't complete, or `RCLONE_REMOTE` in `.env` doesn't match the name
you used in `rclone config`. Re-run 4c/4d.

**`HERMES_HOME (/data) is not mounted` / empty backup.**
`HERMES_DATA_PATH` points at the wrong place. Confirm your real Hermes dir:
`ls ~/.hermes` on the host should show `SOUL.md`, `memories/`, `skills/`,
`state.db`. Put that absolute path in `.env` and `docker compose up -d`.

**macOS rclone `dyld: Symbol not found` on the host.**
You're on Catalina with too-new an rclone. Use `./install-rclone-catalina.sh`.

**Upload slow or interrupted.**
A local copy is always written under the staging volume first, so a failed
upload never costs you the archive. rclone retries; check `docker compose logs`.

---

## Security checklist

- Keep `ENCRYPT=true` for off-machine backups — the archive contains your
  `.env` with API keys and bot tokens.
- Store `GPG_PASSPHRASE` in a password manager, never in the repo.
- `.env` and `rclone.conf` are gitignored — keep it that way.
- Consider `drive.file` scope (option 3 in `rclone config`) to limit the
  remote to only files it creates.

---

## License

MIT.
