# Automating Arch Linux Cleanup: A Hardened Nightly Maintenance Script

Arch Linux gives you full control over your system — but with that control comes responsibility. Over time, package caches grow, orphaned dependencies accumulate, AUR build directories pile up, and logs quietly consume disk space.

If you prefer a lean, predictable system without manually cleaning things every few weeks, automation is the solution.

This article walks through a **production-grade, hardened cleanup script** that:

- Removes package bloat  
- Prunes cache intelligently  
- Cleans AUR artifacts  
- Maintains journal logs  
- Prevents race conditions  
- Logs everything  
- Runs automatically every night at 11 PM  

---

## Why Arch Needs Periodic Cleanup

Arch does not automatically remove:

- Orphaned dependencies  
- Old package versions in cache  
- AUR build artifacts  
- Stale `/tmp` files  
- Aged systemd journal logs  

Over months, this can consume several gigabytes of space.

The solution: automate it safely.

---

# What This Script Does

Here is a structured overview of the cleanup process:

| Step | Action                                                   |
|------|----------------------------------------------------------|
| 1    | Removes orphaned packages (`pacman -Rns`)                |
| 2    | Prunes pacman cache (keeps last 2 versions per package) |
| 3    | Removes yay/AUR cache for uninstalled packages          |
| 4    | Deletes leftover `src` build directories in yay cache   |
| 5    | Removes broken symlinks in `/usr/share` and `/etc`      |
| 6    | Vacuums systemd journal logs (keeps 2 weeks)            |
| 7    | Cleans `/tmp` files older than 7 days                   |
| 8    | Prints disk usage summary to log                        |

This is not a blind `rm -rf everything` script. It is structured, logged, and concurrency-safe.

---

# The Cleanup Script

Save this as:

```
/usr/local/bin/arch-cleanup
```

```bash
#!/usr/bin/env bash
# =============================================================================
# Arch Linux Cleanup Script (Final Hardened Version)
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

trap 'rm -f "$LOCK_FILE"' EXIT

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
else
    log "paccache not found. Install pacman-contrib."
fi

# -----------------------------------------------------------------------------
# 3. Clean Yay (AUR) Cache
# -----------------------------------------------------------------------------
log "Cleaning yay cache..."
if [[ -d "$YAY_CACHE" ]]; then

    declare -A AUR_LOOKUP=()
    while IFS= read -r pkg; do
        AUR_LOOKUP["$pkg"]=1
    done < <(pacman -Qqm || true)

    shopt -s nullglob
    for dir in "$YAY_CACHE"/*/; do
        pkg=$(basename "$dir")
        if [[ -z "${AUR_LOOKUP[$pkg]:-}" ]]; then
            rm -rf "$dir"
            log "Removed uninstalled AUR cache: $pkg"
        fi
    done
    shopt -u nullglob

    find "$YAY_CACHE" -mindepth 2 -maxdepth 2 -type d -name "src" \
        -exec rm -rf {} \; 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 4. Remove Broken Symlinks
# -----------------------------------------------------------------------------
find /usr/share /etc -xtype l -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
# 5. Vacuum Journal Logs (2 Weeks)
# -----------------------------------------------------------------------------
journalctl --vacuum-time=2weeks || true

# -----------------------------------------------------------------------------
# 6. Clean /tmp (older than 7 days)
# -----------------------------------------------------------------------------
find /tmp -type f -atime +7 -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
# 7. Disk Usage Summary
# -----------------------------------------------------------------------------
df -h /

log "===== Arch Cleanup Finished Successfully ====="
```

---

# One-Time Setup

## 1. Install Required Packages

```bash
sudo pacman -S pacman-contrib cronie
```

- `pacman-contrib` → provides `paccache`  
- `cronie` → provides cron scheduler  

---

## 2. Enable Cron

```bash
sudo systemctl enable --now cronie
```

---

## 3. Copy Script

```bash
sudo cp arch-cleanup.sh /usr/local/bin/arch-cleanup
sudo chmod +x /usr/local/bin/arch-cleanup
```

---

## 4. Test Manually

```bash
sudo arch-cleanup
```

Check logs:

```bash
cat /var/log/arch-cleanup.log
```

You should see:

```
===== Arch Cleanup Finished Successfully =====
```

---

# Automating the Script (Daily at 11 PM)

Edit root crontab:

```bash
sudo EDITOR=nano crontab -e
```

Add:

```
0 23 * * * /usr/local/bin/arch-cleanup
```

Verify:

```bash
sudo crontab -l
```

---

# Understanding the Cron Expression

Format:

```
minute hour day month weekday
```

| Field   | Value | Meaning     |
|---------|-------|------------|
| Minute  | 0     | Top of hour |
| Hour    | 23    | 11 PM       |
| Day     | *     | Every day   |
| Month   | *     | Every month |
| Weekday | *     | Any weekday |

---

# Monitoring & Logs

Check full log:

```bash
cat /var/log/arch-cleanup.log
```

Last run only:

```bash
tail -50 /var/log/arch-cleanup.log
```

Live follow:

```bash
sudo arch-cleanup && tail -f /var/log/arch-cleanup.log
```

---

# Key Files Explained

| Path                            | Purpose                  |
|----------------------------------|--------------------------|
| `/usr/local/bin/arch-cleanup`   | Script location          |
| `/var/log/arch-cleanup.log`     | Execution log            |
| `/var/run/arch-cleanup.lock`    | Prevents concurrent runs |
| `/home/jathinshyam/.cache/yay`  | AUR build cache          |

---

# Why This Script Is Production-Safe

This implementation includes:

- `set -Eeuo pipefail` (strict error handling)  
- Lock file with `flock`  
- Root execution enforcement  
- Graceful failure handling (`|| true`)  
- Structured logging with timestamps  
- Safe nullglob handling  
- Scoped directory cleanup (no unsafe wildcards)  

It is safe for:

- Cron  
- systemd timers  
- Long-term unattended usage  

---

# Troubleshooting

### `paccache: command not found`

```bash
sudo pacman -S pacman-contrib
```

---

### `crontab: command not found`

```bash
sudo pacman -S cronie
sudo systemctl enable --now cronie
```

---

### Cron Not Running?

Check:

```bash
sudo systemctl status cronie
```

Start if needed:

```bash
sudo systemctl start cronie
```

---

# Final Thoughts

Arch Linux does not hold your hand — and that is its strength.

Automating maintenance ensures your system remains:

- Fast  
- Minimal  
- Predictable  
- Clean  

If you run Arch daily for development or production workloads, this kind of automation prevents subtle storage creep and keeps your environment disciplined.

Lean systems are happy systems.