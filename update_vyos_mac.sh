#!/bin/bash
# update_vyos_mac.sh
# Updates a VyOS config.boot ethernet interface MAC address
# based on the MAC of a physical NIC identified by its PCI bus address.
#
# Usage:
#   ./update_vyos_mac.sh --pci <PCI_ADDR> --iface <VYOS_IFACE> --config <CONFIG_PATH>
#
# Example:
#   ./update_vyos_mac.sh \
#     --pci 0000:04:00.0 \
#     --iface eth1 \
#     --config /var/lib/libvirt/images/vyos/config.boot

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
PCI_ADDR=""
VYOS_IFACE=""
CONFIG_FILE=""
DRY_RUN=false
BACKUP=true

# ─── Helpers ─────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

  -p, --pci     PCI bus address of the physical NIC  (e.g. 0000:04:00.0)
  -i, --iface   VyOS interface name to update         (e.g. eth1)
  -c, --config  Path to config.boot file
  -n, --dry-run Print what would change, do not write
  --no-backup   Skip creating a .bak file before editing

EOF
    exit 1
}

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--pci)     PCI_ADDR="$2";    shift 2 ;;
        -i|--iface)   VYOS_IFACE="$2";  shift 2 ;;
        -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=true;     shift   ;;
        --no-backup)  BACKUP=false;     shift   ;;
        -h|--help)    usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "$PCI_ADDR"    ]] && die "--pci is required"
[[ -z "$VYOS_IFACE"  ]] && die "--iface is required"
[[ -z "$CONFIG_FILE" ]] && die "--config is required"
[[ -f "$CONFIG_FILE" ]] || die "config.boot not found: $CONFIG_FILE"

# ─── Normalise PCI address (pad domain if omitted: 04:00.0 → 0000:04:00.0) ──
if [[ "$PCI_ADDR" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; then
    PCI_ADDR="0000:${PCI_ADDR}"
fi

log "PCI address  : $PCI_ADDR"
log "VyOS iface   : $VYOS_IFACE"
log "config.boot  : $CONFIG_FILE"

# ─── Resolve PCI address → network interface name ─────────────────────────────
# The symlink /sys/bus/pci/devices/<addr>/net/<ifname> exists when the NIC
# is bound to a kernel driver.  If the device is already passed through /
# bound to vfio-pci this symlink won't exist — handle that case too.

SYSFS_NET="/sys/bus/pci/devices/${PCI_ADDR}/net"

if [[ -d "$SYSFS_NET" ]]; then
    # Kernel driver still owns the device — read MAC directly from sysfs
    mapfile -t ifaces < <(ls "$SYSFS_NET")
    [[ ${#ifaces[@]} -eq 0 ]] && die "No net interfaces found under $SYSFS_NET"
    [[ ${#ifaces[@]} -gt 1 ]] && warn "Multiple interfaces under PCI addr; using first: ${ifaces[0]}"
    HOST_IFACE="${ifaces[0]}"
    MAC_FILE="${SYSFS_NET}/${HOST_IFACE}/address"
    [[ -f "$MAC_FILE" ]] || die "MAC address file not found: $MAC_FILE"
    NEW_MAC=$(cat "$MAC_FILE" | tr '[:upper:]' '[:lower:]')
    log "Host interface: $HOST_IFACE"

elif [[ -d "/sys/bus/pci/devices/${PCI_ADDR}" ]]; then
    # Device exists but is bound to vfio-pci (already passed through).
    # Try to retrieve MAC via 'ip link' by matching PCI address in ethtool output,
    # or fall back to a pre-saved MAC cache (see below).
    log "Device bound to vfio-pci — attempting ethtool/cache lookup"

    # Attempt: iterate all interfaces, check if any report this PCI slot
    NEW_MAC=""
    for iface in $(ls /sys/class/net/); do
        IFACE_PCI=$(ethtool -i "$iface" 2>/dev/null | awk '/^bus-info:/{print $2}') || true
        if [[ "$IFACE_PCI" == "$PCI_ADDR" ]]; then
            NEW_MAC=$(cat "/sys/class/net/${iface}/address" | tr '[:upper:]' '[:lower:]')
            HOST_IFACE="$iface"
            log "Found via ethtool: $HOST_IFACE"
            break
        fi
    done

    # Last resort: read from a cached file written before passthrough binding
    if [[ -z "$NEW_MAC" ]]; then
        CACHE_FILE="/etc/vyos-mac-cache/${PCI_ADDR//:/_}.mac"
        if [[ -f "$CACHE_FILE" ]]; then
            NEW_MAC=$(cat "$CACHE_FILE" | tr '[:upper:]' '[:lower:]')
            log "Using cached MAC from: $CACHE_FILE"
        else
            die "Device is vfio-bound and no cache found at $CACHE_FILE. " \
                "Run this script BEFORE binding to vfio-pci, or pre-populate the cache."
        fi
    fi
else
    die "PCI device not found in sysfs: ${PCI_ADDR}. Check lspci output."
fi

# ─── Validate MAC format ──────────────────────────────────────────────────────
if [[ ! "$NEW_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
    die "MAC address looks invalid: '$NEW_MAC'"
fi
log "New MAC      : $NEW_MAC"

# ─── Parse current MAC from config.boot ───────────────────────────────────────
# VyOS config.boot stanza we're targeting:
#
#   ethernet eth1 {
#       hw-id aa:bb:cc:dd:ee:ff
#       ...
#   }
#
# We use awk to find the right interface block then grab hw-id.

CURRENT_MAC=$(awk -v iface="$VYOS_IFACE" '
    /ethernet[[:space:]]+/ {
        current = $2
    }
    current == iface && /hw-id/ {
        print $2
        exit
    }
' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')

if [[ -z "$CURRENT_MAC" ]]; then
    die "Could not find hw-id for interface '$VYOS_IFACE' in $CONFIG_FILE"
fi

log "Current MAC  : $CURRENT_MAC"

if [[ "$CURRENT_MAC" == "$NEW_MAC" ]]; then
    log "MAC is already up to date — nothing to do."
    exit 0
fi

# ─── Apply the update ─────────────────────────────────────────────────────────
if $DRY_RUN; then
    log "[DRY RUN] Would replace '$CURRENT_MAC' → '$NEW_MAC' for $VYOS_IFACE"
    exit 0
fi

if $BACKUP; then
    BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    log "Backup saved : $BACKUP_FILE"
fi

# Use a temp file + atomic move so the config is never half-written
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

# Replace the hw-id ONLY inside the correct interface block using awk
awk -v iface="$VYOS_IFACE" -v old_mac="$CURRENT_MAC" -v new_mac="$NEW_MAC" '
    /ethernet[[:space:]]+/ {
        in_block = ($2 == iface)
    }
    in_block && /hw-id/ && $2 == old_mac {
        sub(old_mac, new_mac)
    }
    { print }
' "$CONFIG_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$CONFIG_FILE"
log "config.boot updated successfully."
log "  $VYOS_IFACE hw-id: $CURRENT_MAC  →  $NEW_MAC"
