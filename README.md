# Hermes Backup → Google Drive (Dockerized)

A self-contained Docker setup that runs **[Hermes Agent](https://github.com/NousResearch/hermes-agent)**'s
first-party `hermes backup` on a daily schedule and uploads the resulting
archive to a **Google Drive** folder — with optional encryption and automatic
retention.

Everything runs inside the container. You do **not** need Hermes, rclone, or
any other tool installed on the host — only Docker and Docker Compose.

---

## What it does

On a schedule (default: daily at 03:00):

1. Runs `hermes backup`, which produces a consistent zip of your Hermes
   config, skills, sessions, and memory — safe to run even while the agent is
   running, because it uses SQLite's online `backup()` API.
2. Optionally encrypts the archive with `gpg` (AES-256).
3. Saves a local copy under `./backups/`.
4. Uploads the archive to your Google Drive folder via `rclone`.
5. Prunes backups older than `RETENTION_DAYS`, locally and on Drive.

> **Why encryption matters:** the Hermes backup includes your `.env` with API
> keys and bot tokens. If the archive leaks, those leak with it. Turning on
> `ENCRYPT=true` is strongly recommended for anything pushed off-machine.

---

## Requirements

- Docker and Docker Compose on the host.
- A Hermes data directory on the host (normally `~/.hermes`). This is what gets
  backed up. The container mounts it **read-only**.
- A Google account / Google Drive.

---

## Quick start

```bash
# 1. Clone your copy of this repo
git clone <your-repo-url> hermes-backup-docker
cd hermes-backup-docker

# 2. Configure
cp .env.example .env
$EDITOR .env            # set TZ, HERMES_DATA_PATH, schedule, etc.

# 3. Set up the Google Drive remote (one-time; see next section)
#    This produces an rclone.conf in the project directory.

# 4. Build and start
docker compose up -d --build

# 5. (Optional) trigger a test run immediately
docker compose run --rm -e RUN_ON_START=true hermes-backup
# ...or set RUN_ON_START=true in .env for the first boot.

# Watch logs
docker compose logs -f
```

---

## Setting up the Google Drive remote

`rclone` needs a one-time OAuth authorization to talk to Google Drive. Because
authorization opens a browser, the easiest path is to authorize **once on any
machine that has a browser**, then copy the resulting `rclone.conf` into this
project. You do not need to keep rclone installed afterward.

### Option A — authorize on a machine with a browser (recommended)

On any desktop/laptop with a browser:

```bash
# Install rclone temporarily (or use an existing install)
curl -fsSL https://rclone.org/install.sh | sudo bash

# Run the interactive config
rclone config
#  n) New remote
#  name> gdrive                 # must match RCLONE_REMOTE in .env
#  Storage> drive               # Google Drive
#  client_id / client_secret>   # press Enter to use rclone's defaults
#                               # (for heavy use, create your own — see rclone docs)
#  scope> 1                     # full access, or 3 for drive.file (app-created files only)
#  Edit advanced config> n
#  Use auto config> y           # opens a browser to authorize
#  Configure as a Shared Drive (Team Drive)> n  (unless you use one)
#  y) Yes this is OK
#  q) Quit config

# Find where the config was written
rclone config file
# e.g. /home/you/.config/rclone/rclone.conf
```

Copy that `rclone.conf` into this project directory (next to
`docker-compose.yml`), or point `RCLONE_CONFIG_PATH` in `.env` at it.

### Option B — headless server with no browser

Run `rclone config` on the server; when it asks **"Use auto config?"** answer
**n**. rclone prints a command to run on a machine that *does* have a browser
(`rclone authorize "drive"`). Run it there, paste the token back into the
server prompt. Result is the same `rclone.conf`.

### Verify the remote works

```bash
rclone listremotes                 # should list "gdrive:"
rclone lsd gdrive:                 # should list your Drive folders
```

The container runs this same check on startup and refuses to proceed if the
remote isn't found, so you'll get a clear error rather than silent failure.

> **Tip — target a specific folder or Shared Drive:** set
> `RCLONE_REMOTE_PATH` to the folder path inside the remote (e.g.
> `Backups/Hermes`). rclone creates it if it doesn't exist. For a Shared Drive,
> configure the `team_drive` ID during `rclone config`.

---

## Configuration reference

All settings live in `.env` (copied from `.env.example`).

| Variable             | Default        | Description                                                                 |
|----------------------|----------------|-----------------------------------------------------------------------------|
| `TZ`                 | `UTC`          | Timezone for the schedule, e.g. `America/Montevideo`.                       |
| `BACKUP_CRON`        | `0 3 * * *`    | When to run (5-field cron). Default: daily 03:00. See scheduling notes.    |
| `HERMES_DATA_PATH`   | `~/.hermes`    | Host path to the Hermes data dir being backed up (mounted read-only).      |
| `RCLONE_CONFIG_PATH` | `./rclone.conf`| Host path to your rclone config with the Drive remote.                     |
| `RCLONE_REMOTE`      | `gdrive`       | Name of the rclone remote (must match `rclone.conf`).                      |
| `RCLONE_REMOTE_PATH` | `hermes-backups`| Folder path inside the remote to upload into.                             |
| `BACKUP_MODE`        | `full`         | `full` (complete) or `quick` (state-only fast snapshot).                   |
| `RETENTION_DAYS`     | `14`           | Delete backups older than N days, local + remote. `0` = keep everything.   |
| `ENCRYPT`            | `false`        | `true` to gpg-encrypt (AES-256) before upload.                             |
| `GPG_PASSPHRASE`     | _(empty)_      | Required if `ENCRYPT=true`. Store it OUTSIDE this repo.                     |
| `RUN_ON_START`       | `false`        | `true` to run one backup immediately on container start.                   |

---

## Scheduling notes

The container schedules itself — no host cron involved. The bundled scheduler
handles a **simple daily time** (concrete minute + hour in `BACKUP_CRON`)
directly and precisely. Examples that work out of the box:

- `0 3 * * *` → every day at 03:00
- `30 23 * * *` → every day at 23:30

If you set a more complex expression (ranges, lists, weekday filters), the
scheduler falls back to an hourly check. For full cron semantics you can:

- run multiple containers with different daily times, or
- swap the scheduler for `supercronic`/`cron` (the `entrypoint.sh` is small and
  documented for this).

---

## Restoring a backup

To restore, you use Hermes' own import command against an unpacked archive.
On the machine where you want the data restored (with Hermes installed, or
using this image interactively):

```bash
# If encrypted, decrypt first:
gpg --decrypt hermes-backup-YYYYMMDD-HHMMSS.zip.gpg > hermes-backup.zip

# Stop the gateway before importing to avoid conflicts, then:
hermes import hermes-backup.zip            # prompts before overwriting
hermes import hermes-backup.zip --force    # overwrite without prompting
```

The restored install comes back with memory, skills, and config intact.

> **Test your restores.** A backup you've never restored is a hope, not a
> backup. Periodically pull an archive and do a dry restore on a scratch
> profile or throwaway machine.

---

## Project layout

```
hermes-backup-docker/
├── Dockerfile             # image: Debian + Hermes CLI + rclone + gpg
├── docker-compose.yml     # volumes + env wiring
├── .env.example           # copy to .env and edit
├── .gitignore             # keeps secrets/backups out of git
├── README.md
└── scripts/
    ├── entrypoint.sh      # self-contained scheduler loop
    └── backup.sh          # backup → (encrypt) → local copy → Drive → prune
```

---

## Troubleshooting

**`hermes CLI not found on PATH` at runtime.**
The Hermes installer runs at image build time. If it failed (network policy,
upstream change), the build prints a warning but still completes. Rebuild with
logs visible: `docker compose build --no-cache --progress=plain` and check the
Hermes install step. The installer needs outbound access to
`raw.githubusercontent.com` and `github.com`.

**`rclone remote 'gdrive:' not configured`.**
The container couldn't find your remote in the mounted `rclone.conf`. Confirm
`RCLONE_REMOTE` matches the remote name, and that `RCLONE_CONFIG_PATH` points
at a real file. Test on the host: `rclone --config ./rclone.conf listremotes`.

**`HERMES_HOME does not exist or is not mounted`.**
Set `HERMES_DATA_PATH` in `.env` to your real Hermes directory. A literal `~`
in compose volume paths can be unreliable depending on your shell/Docker
version — prefer an absolute path like `/home/youruser/.hermes`.

**Google OAuth token expired.**
rclone refreshes tokens automatically, but if Drive was de-authorized you'll
need to re-run `rclone config` (reconnect) and replace `rclone.conf`.

**Backup runs but the upload is slow / partial.**
A local copy is always written to `./backups/` first, so a failed upload never
costs you the archive. rclone resumes/retries; check `docker compose logs`.

---

## Security checklist

- Keep `ENCRYPT=true` for off-machine backups (the archive contains secrets).
- Store `GPG_PASSPHRASE` in a password manager, never in the repo.
- `.env` and `rclone.conf` are gitignored — keep it that way.
- Consider `drive.file` scope (option 3) during `rclone config` to limit the
  remote's access to only files it creates.

---

## License

MIT. Use, modify, and reuse freely.
