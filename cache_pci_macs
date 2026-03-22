#!/bin/bash
# cache_pci_macs.sh
# Run this BEFORE binding NICs to vfio-pci.
# Saves MAC addresses keyed by PCI bus address so they can be
# retrieved later by update_vyos_mac.sh even after the kernel
# driver has been unbound.
#
# Usage:
#   ./cache_pci_macs.sh [PCI_ADDR ...]
#
# Examples:
#   ./cache_pci_macs.sh                  # cache ALL ethernet interfaces
#   ./cache_pci_macs.sh 0000:04:00.0     # cache a specific PCI device

set -euo pipefail

CACHE_DIR="/etc/vyos-mac-cache"
mkdir -p "$CACHE_DIR"

cache_iface() {
    local iface="$1"
    local pci_addr mac cache_key cache_file

    # Get PCI bus address via ethtool
    pci_addr=$(ethtool -i "$iface" 2>/dev/null | awk '/^bus-info:/{print $2}') || return
    [[ -z "$pci_addr" ]] && return

    mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null | tr '[:upper:]' '[:lower:]') || return
    [[ -z "$mac" ]] && return

    # Skip loopback / virtual interfaces
    [[ "$mac" == "00:00:00:00:00:00" ]] && return

    cache_key="${pci_addr//:/_}"
    cache_file="${CACHE_DIR}/${cache_key}.mac"
    echo "$mac" > "$cache_file"
    echo "[CACHED] $pci_addr  ($iface)  →  $mac  (${cache_file})"
}

if [[ $# -gt 0 ]]; then
    # Specific PCI addresses given — find matching interfaces
    for pci in "$@"; do
        found=false
        for iface in $(ls /sys/class/net/); do
            iface_pci=$(ethtool -i "$iface" 2>/dev/null | awk '/^bus-info:/{print $2}') || continue
            if [[ "$iface_pci" == "$pci" ]]; then
                cache_iface "$iface"
                found=true
            fi
        done
        $found || echo "[WARN]  No interface found for PCI $pci"
    done
else
    # Cache everything
    for iface in $(ls /sys/class/net/); do
        cache_iface "$iface"
    done
fi

echo ""
echo "Cache contents (${CACHE_DIR}):"
ls -1 "$CACHE_DIR"/*.mac 2>/dev/null | while read -r f; do
    printf "  %-45s %s\n" "$(basename "$f")" "$(cat "$f")"
done || echo "  (empty)"
