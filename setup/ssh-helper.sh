#!/bin/bash
#
# setup/ssh-helper.sh
#
# Guided SSH key setup for the SFTP destination. Sourced by setup/wizard.sh
# when the operator chooses "sftp" and the named host alias doesn't already
# have a working, key-based connection.
#
# Public entry point: ensure_ssh_ready "<alias>"
#   - If the alias already exists in /root/.ssh/config AND connects cleanly,
#     this is a no-op (returns 0 immediately).
#   - Otherwise it walks the operator through generating a keypair, placing
#     the public key on the remote machine, writing the Host block, and
#     verifying the connection — retrying on failure rather than giving up
#     after one attempt.
#
# Depends on prompt_with_default(), already defined in setup/wizard.sh.
# This file assumes it is sourced, not executed standalone.

SSH_CONFIG="/root/.ssh/config"
SSH_KEY_PATH="/root/.ssh/id_ed25519"

# --- helpers -----------------------------------------------------------

ssh_alias_exists() {
    local alias_name="$1"
    [[ -f "$SSH_CONFIG" ]] && grep -qE "^Host[[:space:]]+${alias_name}\$" "$SSH_CONFIG"
}

ensure_keypair() {
    if [[ -f "$SSH_KEY_PATH" ]]; then
        echo "Existing SSH key found at $SSH_KEY_PATH, reusing it."
        return 0
    fi

    echo ""
    echo "No SSH key found. Generating a new ed25519 keypair for backup use."
    echo "(No passphrase is set — this key must work unattended for nightly backups.)"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "backup-framework-$(hostname)" -q

    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        echo "FATAL: key generation failed, aborting SSH setup." >&2
        return 1
    fi
    echo "Key generated: $SSH_KEY_PATH"
}

prompt_remote_os() {
    echo "" >&2
    echo "What kind of machine are you connecting to?" >&2
    echo "  1) Linux server" >&2
    echo "  2) Windows PC (with OpenSSH Server)" >&2
    local choice
    choice="$(prompt_with_default "Choose remote OS" "1")"
    case "$choice" in
        2|windows|Windows) echo "windows" ;;
        *)                 echo "linux" ;;
    esac
}

show_pubkey_instructions() {
    local os_type="$1"
    local pubkey
    pubkey="$(cat "${SSH_KEY_PATH}.pub")"

    echo ""
    echo "=== Public key (copy the full line below) ==="
    echo "$pubkey"
    echo "==============================================="
    echo ""

    if [[ "$os_type" == "windows" ]]; then
        cat <<'EOF'
Windows (OpenSSH Server) setup:
  1. Make sure "OpenSSH Server" is installed and running:
       Settings -> Apps -> Optional Features -> OpenSSH Server
       (or: Get-WindowsCapability -Online | ? Name -like 'OpenSSH.Server*'
            then: Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0)
     Start it: Start-Service sshd
     Autostart: Set-Service -Name sshd -StartupType 'Automatic'

  2. Paste the public key above into:
       C:\Users\<remote-username>\.ssh\authorized_keys
     (create the .ssh folder and file if they don't exist)

  3. IMPORTANT — Windows OpenSSH is strict about file permissions on
     authorized_keys. If the file is inherited-readable by other accounts,
     SSH will silently ignore it. From an elevated PowerShell:
       icacls "C:\Users\<remote-username>\.ssh\authorized_keys" /inheritance:r
       icacls "C:\Users\<remote-username>\.ssh\authorized_keys" /grant "<remote-username>:F"
       icacls "C:\Users\<remote-username>\.ssh\authorized_keys" /grant "SYSTEM:F"

  4. If <remote-username> is an Administrator account, Windows OpenSSH uses
     a DIFFERENT file instead: C:\ProgramData\ssh\administrators_authorized_keys
     (with the same permissions lockdown, restricted to Administrators + SYSTEM).
EOF
    else
        cat <<'EOF'
Linux server setup:
  Easiest path, if password auth is temporarily available:
    ssh-copy-id -i /root/.ssh/id_ed25519.pub <remote-username>@<remote-host>

  Manual path (no password auth, or ssh-copy-id unavailable):
    1. On the remote machine, ensure ~/.ssh exists:
         mkdir -p ~/.ssh && chmod 700 ~/.ssh
    2. Append the public key above to:
         ~/.ssh/authorized_keys
       then:
         chmod 600 ~/.ssh/authorized_keys
EOF
    fi
    echo ""
    read -rp "Press Enter once the key has been placed on the remote machine..." _
}

write_ssh_config_block() {
    local alias_name="$1" remote_host="$2" remote_user="$3"

    if ssh_alias_exists "$alias_name"; then
        echo "Host alias '$alias_name' already present in $SSH_CONFIG, leaving it untouched."
        return 0
    fi

    mkdir -p /root/.ssh
    touch "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"

    {
        echo ""
        echo "Host $alias_name"
        echo "    HostName $remote_host"
        echo "    User $remote_user"
        echo "    IdentityFile $SSH_KEY_PATH"
        echo "    IdentitiesOnly yes"
        echo "    StrictHostKeyChecking accept-new"
    } >> "$SSH_CONFIG"

    echo "Added Host block for '$alias_name' to $SSH_CONFIG."
}

check_tailscale_reachable() {
    local remote_host="$1"

    command -v tailscale >/dev/null 2>&1 || return 0   # tailscale not in use, skip silently

    # Only meaningful for tailscale IPs (100.x.x.x) or magicDNS names; skip otherwise
    echo ""
    echo "Tailscale detected — checking reachability of $remote_host before attempting SSH..."
    if tailscale ping -c 1 --timeout=5s "$remote_host" >/dev/null 2>&1; then
        echo "Tailscale ping to $remote_host succeeded."
        return 0
    else
        echo "WARNING: Tailscale ping to $remote_host failed."
        echo "Check that:"
        echo "  - Tailscale is installed and running on the REMOTE machine too"
        echo "  - The remote machine is powered on and connected to the network"
        echo "  - You're using the correct Tailscale IP or MagicDNS name"
        return 1
    fi
}

test_ssh_connection() {
    local alias_name="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$alias_name" exit 2>/dev/null
}

# --- main entry point ----------------------------------------------------

ensure_ssh_ready() {
    local alias_name="$1"
    local os_hint="${2:-}"

    if ssh_alias_exists "$alias_name" && test_ssh_connection "$alias_name"; then
        echo "SSH alias '$alias_name' already configured and reachable. Skipping setup."
        return 0
    fi

    echo ""
    echo "=== SSH setup required for destination alias '$alias_name' ==="
    echo "This is a one-time setup. Unattended nightly backups require"
    echo "key-based auth with no password prompts."

    ensure_keypair || return 1

    local os_type remote_host remote_user
    if [[ -n "$os_hint" ]]; then
        os_type="$os_hint"
    else
        os_type="$(prompt_remote_os)"
    fi
    remote_host="$(prompt_with_default "Remote host/IP (e.g. Tailscale IP)" "")"
    if [[ -z "$remote_host" ]]; then
        echo "FATAL: remote host cannot be empty." >&2
        return 1
    fi
    remote_user="$(prompt_with_default "Remote username" "$(whoami)")"

    check_tailscale_reachable "$remote_host"   # warns only, doesn't block

    show_pubkey_instructions "$os_type"
    write_ssh_config_block "$alias_name" "$remote_host" "$remote_user"

    local attempt=1
    local max_attempts=3
    while (( attempt <= max_attempts )); do
        echo ""
        echo "Testing connection ($attempt/$max_attempts)..."
        if test_ssh_connection "$alias_name"; then
            echo "SUCCESS: '$alias_name' connects with key-based auth, no prompts."
            return 0
        fi
        echo "Connection test FAILED."
        if (( attempt < max_attempts )); then
            echo "Double-check the key was placed correctly and permissions are right,"
            echo "then we'll try again."
            read -rp "Press Enter to retry..." _
        fi
        ((attempt++))
    done

    echo ""
    echo "FATAL: could not establish key-based SSH after $max_attempts attempts." >&2
    echo "You can re-run setup and choose SFTP again once connectivity is fixed." >&2
    return 1
}
