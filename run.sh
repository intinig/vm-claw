#!/bin/bash
set -euo pipefail

VM_NAME="bridge-vm"

# Abort if vmnet's NAT bridge subnet collides with an active host interface.
# When this happens, the VM gets an IP already in use on the LAN and return
# traffic is misrouted (asymmetric routing on duplicate /24), so the guest
# reaches the gateway but not the internet.
#
# Source of truth is the live bridge interface (e.g. bridge100), not the
# vmnet plist: the plist is mode 0640 (unreadable without sudo) and vmnet
# may pick a different subnet at boot than what's configured.
check_vmnet_subnet_collision() {
    # Find the active vmnet bridge: a bridge* interface whose member is vmenet*.
    local bridge_iface bridge_ip bridge_prefix
    for iface in $(ifconfig -l); do
        [[ "$iface" == bridge* ]] || continue
        if ifconfig "$iface" 2>/dev/null | grep -q "member: vmenet"; then
            bridge_iface="$iface"
            bridge_ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet [0-9]/ {print $2; exit}')
            [[ -n "$bridge_ip" ]] && bridge_prefix="${bridge_ip%.*}"
            break
        fi
    done

    # If no vmnet bridge is up yet, fall back to the configured plist value
    # (sudo -n; if unreadable, assume vmnet's compiled-in default).
    local check_prefix source_label
    if [[ -n "$bridge_prefix" ]]; then
        check_prefix="$bridge_prefix"
        source_label="$bridge_iface ($bridge_ip)"
    else
        local configured
        configured=$(sudo -n defaults read /Library/Preferences/SystemConfiguration/com.apple.vmnet Shared_Net_Address 2>/dev/null || echo "192.168.64.1")
        check_prefix="${configured%.*}"
        source_label="vmnet plist ($configured)"
    fi

    local conflict=""
    for iface in $(ifconfig -l); do
        case "$iface" in
            lo*|utun*|gif*|stf*|awdl*|llw*|anpi*|ap*|bridge*|vmenet*) continue ;;
        esac
        local ip
        ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet [0-9]/ && !/127\./ {print $2; exit}')
        [[ -z "$ip" ]] && continue
        if [[ "${ip%.*}" == "$check_prefix" ]]; then
            conflict="$iface ($ip) vs $source_label"
            break
        fi
    done

    if [[ -n "$conflict" ]]; then
        echo "Error: vmnet subnet collides with active host interface."
        echo "  $conflict"
        echo ""
        echo "The VM would get an IP already in use on your LAN, breaking internet access."
        echo "Pick a non-overlapping subnet for vmnet (e.g. 192.168.66.0/24):"
        echo ""
        echo "  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.vmnet Shared_Net_Address -string 192.168.66.1"
        echo "  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.vmnet Shared_Net_Mask -string 255.255.255.0"
        echo "  sudo reboot   # vmnet only re-reads this config at boot"
        echo ""
        echo "After reboot, verify it stuck:"
        echo "  ifconfig ${bridge_iface:-bridge100} | grep 'inet '"
        exit 1
    fi
}

# Verify VM exists
if ! tart list | grep -q "[[:space:]]$VM_NAME[[:space:]]"; then
    echo "Error: VM '$VM_NAME' not found. Run ./setup.sh first."
    exit 1
fi

check_vmnet_subnet_collision

echo "Starting VM '$VM_NAME':"
echo "  - Network: softnet (isolated from host VPN and routes)"
echo "  - Clipboard: enabled"
echo ""

tart run "$VM_NAME" \
    --net-softnet
