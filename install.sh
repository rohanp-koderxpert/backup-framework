#!/bin/bash
#
# install.sh
#
# One-shot installer for the Universal Linux Backup & Disaster
# Recovery Framework. Downloads and installs all dependencies,
# creates the required directory structure, and launches the
# interactive setup wizard.
#
# Usage (from GitHub):
#   curl -fsSL https://raw.githubusercontent.com/rohanp-koderxpert/backup-framework/main/install.sh | sudo bash
#
# Or after cloning:
#   sudo bash install.sh

set -euo pipefail

FRAMEWORK_REPO="https://github.com/rohanp-koderxpert/backup-framework.git"
FRAMEWORK_DIR="/opt/backup-framework"
CONFIG_DIR="/etc/backup-framework"
BACKUP_DIR="/var/backups/backup-framework"
LOG_DIR="/var/log/backup-framework"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_section() { echo ""; echo -e "${GREEN}═══════════════════════════════════${NC}"; echo -e "${GREEN} $1${NC}"; echo -e "${GREEN}═══════════════════════════════════${NC}"; }

# --- Preflight checks ---
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root. Use: sudo bash install.sh"
        exit 1
    fi
}

check_os() {
    if ! grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
        log_error "This framework currently supports Ubuntu and Debian only."
        log_error "Detected OS: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
        exit 1
    fi
    log_info "OS check passed: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
}

check_internet() {
    if ! curl -fsSL --max-time 10 https://github.com >/dev/null 2>&1; then
        log_error "No internet connectivity detected. This installer requires internet access."
        exit 1
    fi
    log_info "Internet connectivity confirmed."
}

# --- Dependency installation ---
install_dependencies() {
    log_section "Installing dependencies"

    log_info "Updating package lists..."
    apt-get update -qq

    local deps_needed=()
    command -v restic &>/dev/null || deps_needed+=("restic")
    command -v jq     &>/dev/null || deps_needed+=("jq")
    command -v rclone &>/dev/null || deps_needed+=("rclone")
    command -v git    &>/dev/null || deps_needed+=("git")
    command -v curl   &>/dev/null || deps_needed+=("curl")

    if [[ ${#deps_needed[@]} -eq 0 ]]; then
        log_info "All dependencies already installed."
    else
        log_info "Installing: ${deps_needed[*]}"
        apt-get install -y "${deps_needed[@]}" -qq
        log_info "Dependencies installed successfully."
    fi

    log_info "restic  $(restic version | head -1)"
    log_info "jq      $(jq --version)"
    log_info "rclone  $(rclone version | head -1)"
}

# --- Framework installation ---
install_framework() {
    log_section "Installing framework"

    if [[ -d "$FRAMEWORK_DIR/.git" ]]; then
        log_info "Framework already cloned at $FRAMEWORK_DIR, pulling latest..."
        git -C "$FRAMEWORK_DIR" pull --ff-only
    elif [[ -f "$FRAMEWORK_DIR/backup/run.sh" ]]; then
        log_info "Framework files already present at $FRAMEWORK_DIR (non-git install), skipping clone."
    else
        log_info "Cloning framework to $FRAMEWORK_DIR..."
        git clone "$FRAMEWORK_REPO" "$FRAMEWORK_DIR"
    fi

    chmod +x "$FRAMEWORK_DIR/bin/"*          2>/dev/null || true
    chmod +x "$FRAMEWORK_DIR/backup/"*.sh    2>/dev/null || true
    chmod +x "$FRAMEWORK_DIR/restore/"*.sh   2>/dev/null || true
    chmod +x "$FRAMEWORK_DIR/setup/"*.sh     2>/dev/null || true
    chmod +x "$FRAMEWORK_DIR/destinations/"*.sh 2>/dev/null || true
    chmod +x "$FRAMEWORK_DIR/database/"*.sh  2>/dev/null || true

    log_info "Framework installed at $FRAMEWORK_DIR"
}

# --- Directory structure ---
create_directories() {
    log_section "Creating runtime directories"

    mkdir -p "$CONFIG_DIR"
    mkdir -p "$BACKUP_DIR/manifest"
    mkdir -p "$BACKUP_DIR/dumps"
    mkdir -p "$LOG_DIR"

    chmod 700 "$CONFIG_DIR"
    chmod 755 "$BACKUP_DIR"
    chmod 755 "$LOG_DIR"

    if [[ ! -f "$CONFIG_DIR/excludes.txt" ]]; then
        cp "$FRAMEWORK_DIR/templates/default-excludes.txt" "$CONFIG_DIR/excludes.txt"
        log_info "Default exclude file created at $CONFIG_DIR/excludes.txt"
    else
        log_info "Exclude file already exists, leaving it untouched."
    fi

    if [[ ! -f /usr/local/bin/backup-framework ]]; then
        ln -sf "$FRAMEWORK_DIR/bin/backup-framework" /usr/local/bin/backup-framework
        log_info "Command 'backup-framework' available system-wide."
    fi

    log_info "Runtime directories ready."
}

# --- Summary and launch wizard ---
launch_wizard() {
    log_section "Installation complete"

    echo ""
    log_info "Framework installed successfully."
    echo ""
    echo "  Framework directory:  $FRAMEWORK_DIR"
    echo "  Config directory:     $CONFIG_DIR"
    echo "  Backup storage:       $BACKUP_DIR"
    echo "  Logs:                 $LOG_DIR"
    echo ""

    if [[ -f "$CONFIG_DIR/backup.conf" ]]; then
        log_warn "Existing configuration found at $CONFIG_DIR/backup.conf"
        log_warn "Skipping wizard — run it manually to reconfigure:"
        echo ""
        echo "    sudo bash $FRAMEWORK_DIR/setup/wizard.sh"
        echo ""
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_warn "Running via pipe (curl | bash) — cannot launch interactive wizard."
        echo ""
        echo "  Installation is complete. Now run the setup wizard:"
        echo ""
        echo "    sudo bash $FRAMEWORK_DIR/setup/wizard.sh"
        echo ""
        echo "  Then enable automated backups:"
        echo ""
        echo "    sudo bash $FRAMEWORK_DIR/setup/install-timer.sh"
        echo ""
        return 0
    fi

    log_info "Launching setup wizard..."
    echo ""
    bash "$FRAMEWORK_DIR/setup/wizard.sh"
}

# --- Main ---
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   Universal Linux Backup & DR Framework          ║"
    echo "║   Installer v1.0                                 ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    check_root
    check_os
    check_internet
    install_dependencies
    install_framework
    create_directories
    launch_wizard
}

main "$@"
