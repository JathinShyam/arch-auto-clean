#!/usr/bin/env bash
# =============================================================================
# Arch Linux Cleanup Script (Final Hardened Version)
# User: jathinshyam
# Safe for root cron or systemd timer
# =============================================================================
set -Eeuo pipefail

LOG_FILE="/var/log/arch-cleanup.log"
LOCK_FILE="/var/run/arch-cleanup.lock"
REAL_USER="jathinshyam"
YAY_CACHE="/home/${REAL_USER}/.cache/yay"

# -----------------------------------------------------------------------------
# Root Check
# -----------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# -----------------------------------------------------------------------------
# Prevent Concurrent Execution
# -----------------------------------------------------------------------------
exec 9>"$LOCK_FILE"
flock -n 9 || {
    echo "Another cleanup instance is running. Exiting."
    exit 1
}

# Clean up lock file on any exit (crash, error, or success)
trap 'rm -f "$LOCK_FILE"' EXIT

# -----------------------------------------------------------------------------
# Logging Setup (after lock is confirmed)
# -----------------------------------------------------------------------------
touch "$LOG_FILE" || {
    echo "Cannot write to $LOG_FILE"
    exit 1
}
exec >>"$LOG_FILE" 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "===== Arch Cleanup Started ====="

# -----------------------------------------------------------------------------
# 1. Remove Orphaned Packages
# -----------------------------------------------------------------------------
log "Checking for orphaned packages..."
mapfile -t ORPHANS < <(pacman -Qdtq || true)

if (( ${#ORPHANS[@]} > 0 )); then
    log "Removing orphaned packages: ${ORPHANS[*]}"
    pacman -Rns --noconfirm "${ORPHANS[@]}"
else
    log "No orphaned packages found."
fi

# -----------------------------------------------------------------------------
# 2. Clean Pacman Cache
# -----------------------------------------------------------------------------
if command -v paccache >/dev/null 2>&1; then
    log "Pruning pacman cache (keeping last 2 versions)..."
    paccache -rk2
    log "Removing cache for uninstalled packages..."
    paccache -ruk0
    log "Pacman cache pruning complete."
else
    log "paccache not found. Install pacman-contrib: pacman -S pacman-contrib"
fi

# -----------------------------------------------------------------------------
# 3. Clean Yay (AUR) Cache
# -----------------------------------------------------------------------------
log "Cleaning yay cache..."
if [[ -d "$YAY_CACHE" ]]; then
    log "Found yay cache at $YAY_CACHE"

    # Build associative lookup for installed AUR packages
    declare -A AUR_LOOKUP=()
    while IFS= read -r pkg; do
        AUR_LOOKUP["$pkg"]=1
    done < <(pacman -Qqm || true)

    # nullglob: prevent literal '*' expansion if cache dir is empty
    shopt -s nullglob
    for dir in "$YAY_CACHE"/*/; do
        pkg=$(basename "$dir")
        if [[ -z "${AUR_LOOKUP[$pkg]:-}" ]]; then
            rm -rf "$dir"
            log "Removed uninstalled AUR cache: $pkg"
        fi
    done
    shopt -u nullglob

    log "Removing leftover build src directories..."
    find "$YAY_CACHE" -mindepth 2 -maxdepth 2 -type d -name "src" \
        -exec rm -rf {} \; 2>/dev/null || true
    log "Yay cache cleanup complete."
else
    log "Yay cache directory not found at $YAY_CACHE."
fi

# -----------------------------------------------------------------------------
# 4. Remove Broken Symlinks
# -----------------------------------------------------------------------------
log "Removing broken symlinks in /usr/share and /etc..."
find /usr/share /etc -xtype l -print -delete 2>/dev/null || true
log "Broken symlink cleanup complete."

# -----------------------------------------------------------------------------
# 5. Vacuum Journal Logs (2 Weeks Retention)
# -----------------------------------------------------------------------------
log "Vacuuming systemd journal (2 weeks retention)..."
journalctl --vacuum-time=2weeks || true

# -----------------------------------------------------------------------------
# 6. Clean /tmp (files older than 7 days)
# -----------------------------------------------------------------------------
log "Cleaning /tmp files older than 7 days..."
find /tmp -type f -atime +7 -delete 2>/dev/null || true
log "/tmp cleanup complete."

# -----------------------------------------------------------------------------
# 7. Disk Usage Summary
# -----------------------------------------------------------------------------
log "Disk usage summary (root partition):"
df -h /

log "===== Arch Cleanup Finished Successfully ====="