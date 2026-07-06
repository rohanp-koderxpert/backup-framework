# Universal Linux Backup & Disaster Recovery Framework

A production-grade, config-driven backup and disaster recovery framework for Ubuntu/Debian Linux servers. Supports incremental backups with deduplication, multiple storage destinations, automated scheduling, and single-command restore with validation.

---

## What This Does

- Takes a **full filesystem backup** of your server (everything except virtual filesystems and regenerable caches)
- Generates a **structured JSON manifest** capturing installed packages, running services, ports, Docker containers, PostgreSQL clusters, cron jobs, SSL certificates, and more
- Creates **verified PostgreSQL database dumps** alongside the filesystem backup
- Stores backups at your chosen destination with **deduplication and compression** (only changed data is stored after the first backup)
- Runs **automatically every night** via a systemd timer
- Provides a **single-command restore wizard** that restores and validates automatically

---

## Supported Backup Destinations

| Destination | Description |
|-------------|-------------|
| `local` | On the server's own disk (for testing only — not real DR) |
| `sftp` | Another Linux server or Windows PC over SSH/Tailscale |
| `rclone` | Google Drive, OneDrive, Dropbox, S3, and any rclone-supported cloud |

---

## Prerequisites

### On the server (handled automatically by the installer)
- Ubuntu 24.04 LTS or Debian 12+ (other versions may work but are untested)
- Root access
- Internet connectivity (for cloning the repo and installing dependencies)
- `restic`, `jq`, `rclone`, `git`, `curl` — **installed automatically** by `install.sh`

### If using SFTP destination (local PC or another server)
Before running the installer, the remote machine must have:
- **SSH server running** with a user account you can authenticate to
- **Key-based SSH authentication** configured (password auth will not work for unattended nightly backups)
- Network reachability from the server (direct, VPN, or Tailscale)

#### Setting up your local Windows PC as an SFTP destination

1. **Install Tailscale on both machines** (recommended for secure, stable connectivity):
   - Server: `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up`
   - Windows PC: download from https://tailscale.com/download/windows
   - Sign in with the same account on both — they will appear in each other's Tailscale network

2. **Enable OpenSSH Server on Windows PC**:
   Open PowerShell as Administrator and run:
```powershell
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Start-Service sshd
   Set-Service -Name sshd -StartupType 'Automatic'
   New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

3. **Verify connectivity** from the server:
```bash
   ssh <your-windows-username>@<tailscale-ip-of-pc>
```
   You should get a Windows command prompt. Type `exit` to disconnect.

   > The setup wizard will guide you through SSH key generation and placement when you choose the SFTP destination. You do not need to set up keys manually before running the installer.

#### Setting up another Linux server as an SFTP destination

The remote server just needs SSH running and a user with write access to your chosen backup directory. The wizard handles key generation and placement interactively.

### If using Google Drive destination

rclone requires a one-time OAuth authentication with Google. This happens inside the wizard when you choose the rclone destination. You will need:
- A browser available on any machine (does not have to be the server)
- A Google account

---

## Installation

### One-line install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/rohanp-koderxpert/backup-framework/main/install.sh | sudo bash
```

This will:
1. Check you are running Ubuntu or Debian as root
2. Verify internet connectivity
3. Install `restic`, `jq`, `rclone`, and `git` if not already present
4. Clone this repository to `/opt/backup-framework`
5. Create runtime directories (`/etc/backup-framework`, `/var/backups/backup-framework`, `/var/log/backup-framework`)
6. Create a default exclude file at `/etc/backup-framework/excludes.txt`
7. Launch the interactive setup wizard automatically

### Manual install (if you have already cloned the repo)

```bash
sudo bash /opt/backup-framework/install.sh
```

---

## Setup Wizard

The wizard runs automatically after installation. It asks only the essential questions:

1. **Server name** — a friendly label used in reports and snapshot tags
2. **Backup destination** — local disk, SFTP (PC or server), or rclone (Google Drive etc.)
3. **Connection details** — varies by destination type
4. **Retention policy** — how many daily backups to keep (default: 15)
5. **Schedule** — what time to run nightly (default: 02:00)
6. **Database mode** — auto (recommended), manual, or disabled

After the wizard completes, it:
- Generates a strong random repository password and saves it to `/etc/backup-framework/.restic-password`
- Writes your configuration to `/etc/backup-framework/backup.conf`
- Tests connectivity to the chosen destination
- Initializes the restic repository

To reconfigure at any time:
```bash
sudo bash /opt/backup-framework/setup/wizard.sh
```

---

## Enabling Automated Backups

After the wizard completes, enable the systemd timer:

```bash
sudo bash /opt/backup-framework/setup/install-timer.sh
```

Verify it is scheduled:
```bash
systemctl list-timers backup-framework.timer
```

To run a backup immediately without waiting for the scheduled time:
```bash
sudo systemctl start backup-framework.service
```

To watch it run live:
```bash
journalctl -u backup-framework.service -f
```

---

## Restore

To restore from any available snapshot:

```bash
sudo bash /opt/backup-framework/restore/wizard.sh
```

This will:
1. List all available snapshots with their dates
2. Ask which snapshot to restore (defaults to the most recent)
3. Ask where to restore it (defaults to a timestamped directory in `/tmp`)
4. Check available disk space before starting
5. Run the restore
6. Automatically validate the restored data against the original manifest

### Post-restore validation only

To validate an already-restored snapshot without re-running the restore:

```bash
source /opt/backup-framework/restore/validate.sh
validate_restore /path/to/original/manifest.json /path/to/current/manifest.json
```

---

## Directory Structure
/opt/backup-framework/          # Framework code (this repository)
├── install.sh                  # One-shot installer
├── backup/run.sh               # Main backup entrypoint
├── restore/wizard.sh           # Single-command restore wizard
├── restore/restore.sh          # Core restore logic
├── restore/validate.sh         # Restore validation
├── setup/wizard.sh             # Interactive configuration wizard
├── setup/install-timer.sh      # Systemd timer installer
├── setup/ssh-helper.sh         # Guided SSH key setup for SFTP
├── core/config-loader.sh       # Safe config loading with validation
├── core/dispatcher.sh          # Decides wizard vs unattended run
├── core/lock.sh                # Concurrency guard
├── manifest/generate.sh        # JSON manifest generator
├── database/postgresql.sh      # PostgreSQL dump with verification
├── destinations/local.sh       # Local disk adapter
├── destinations/sftp.sh        # SSH/SFTP adapter
├── destinations/rclone.sh      # rclone cloud adapter
└── templates/backup.conf.example  # Annotated config template
/etc/backup-framework/          # Runtime configuration (not in git)
├── backup.conf                 # Your server's configuration
├── secrets.env                 # Credentials (chmod 600, never commit)
├── .restic-password            # Repository encryption key (never commit)
└── excludes.txt                # Paths excluded from backup
/var/backups/backup-framework/  # Generated backup data
├── manifest/manifest.json      # Latest system manifest
├── dumps/                      # PostgreSQL dumps
└── repo/                       # Restic repository (if using local destination)
/var/log/backup-framework/      # Logs

---

## Configuration Reference

The full annotated configuration template is at `templates/backup.conf.example`. Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `SERVER_NAME` | hostname | Label used in snapshots and reports |
| `DEST_TYPE` | `local` | `local`, `sftp`, or `rclone` |
| `RETENTION_DAILY` | `15` | Number of daily snapshots to keep |
| `SCHEDULE_TIME` | `02:00` | Nightly backup time (24h) |
| `SCHEDULE_JITTER_MINUTES` | `30` | Random delay added to schedule time |
| `DB_MODE` | `auto` | `auto`, `manual`, or `disabled` |
| `VERIFY_BACKUP` | `true` | Run `restic check` after each backup |
| `BACKUP_COMPRESSION` | `auto` | `auto`, `max`, or `off` |

---

## Important Notes

- **Never commit** `/etc/backup-framework/` contents to git — it contains your encryption password and credentials
- The repository password at `/etc/backup-framework/.restic-password` is the **only way to decrypt your backups** — store a copy somewhere safe off this server
- The first backup to a remote destination (SFTP/rclone) transfers your full filesystem and may take 1-2 hours depending on connection speed — daily incremental backups after that are much smaller
- SFTP backups over an unstable connection may require multiple retries to complete the initial full backup

---

## Troubleshooting

**Backup failed — check logs:**
```bash
journalctl -u backup-framework.service --no-pager -n 50
```

**Repository locked (previous run crashed):**
```bash
export RESTIC_REPOSITORY=/var/backups/backup-framework/repo
export RESTIC_PASSWORD_FILE=/etc/backup-framework/.restic-password
restic unlock
```

**Test destination connectivity:**
```bash
source /opt/backup-framework/core/config-loader.sh
load_config /etc/backup-framework/backup.conf
load_config /etc/backup-framework/secrets.env
source /opt/backup-framework/destinations/${DEST_TYPE}.sh
test_destination
```

**List available snapshots:**
```bash
export RESTIC_REPOSITORY=/var/backups/backup-framework/repo
export RESTIC_PASSWORD_FILE=/etc/backup-framework/.restic-password
restic snapshots
```

---

## License

MIT
