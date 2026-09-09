#!/bin/bash
# OpenVPN down-hook: hebt die resolv.conf-Sperre (chattr +i) wieder auf
# und stellt den Stand von vor dem Tunnelaufbau wieder her.
#
# REKONSTRUIERT (siehe vpnks-up.sh) - vor produktivem Einsatz in der VM
# testen (docs/TESTING.md).
set -e

BACKUP=/run/vpn-killswitch-resolv-backup
RESOLV=/etc/resolv.conf

chattr -i "$RESOLV" 2>/dev/null || true

if [ -f "$BACKUP" ]; then
    cp -a "$BACKUP" "$RESOLV"
    rm -f "$BACKUP"
else
    : > "$RESOLV"
fi

logger -t vpn-killswitch "vpnks-down: resolv.conf-Sperre aufgehoben"
