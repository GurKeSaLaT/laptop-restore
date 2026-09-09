#!/bin/bash
# OpenVPN up-hook: schreibt die vom Server per foreign_option_* gepushten
# DNS-Server (und Such-Domain) in /etc/resolv.conf und sperrt die Datei
# mit chattr +i, solange der Tunnel steht. Noetig, weil NetworkManager
# 1.58 /etc/resolv.conf direkt selbst schreibt und dns=resolvconf nicht
# mehr greift (siehe ~/config/vpn-auto-connect.md). Backup des Vorzustands
# nach /run/vpn-killswitch-resolv-backup.
#
# REKONSTRUIERT: Das Original-Skript war auf dem Referenzsystem nicht
# lesbar (0700, root:root). Verhalten/Kommentar-Zeile aus der Doku und dem
# live beobachteten /etc/resolv.conf-Inhalt uebernommen - vor produktivem
# Einsatz in der VM testen (docs/TESTING.md).
set -e

BACKUP=/run/vpn-killswitch-resolv-backup
RESOLV=/etc/resolv.conf

chattr -i "$RESOLV" 2>/dev/null || true
[ -f "$BACKUP" ] || cp -a "$RESOLV" "$BACKUP" 2>/dev/null || true

dns_servers=()
search_domain=""
i=1
while true; do
    var="foreign_option_${i}"
    opt="${!var:-}"
    [ -z "$opt" ] && break
    case "$opt" in
        "dhcp-option DNS "*)
            dns_servers+=("${opt#dhcp-option DNS }")
            ;;
        "dhcp-option DOMAIN "*)
            search_domain="${opt#dhcp-option DOMAIN }"
            ;;
    esac
    i=$((i+1))
done

{
    echo "# Von vpnks-up.sh gesetzt (VPN aktiv, resolv.conf gesperrt)"
    [ -n "$search_domain" ] && echo "search $search_domain"
    for ns in "${dns_servers[@]}"; do
        echo "nameserver $ns"
    done
} > "$RESOLV"

chattr +i "$RESOLV"
logger -t vpn-killswitch "vpnks-up: resolv.conf gesperrt (${#dns_servers[@]} DNS-Server, search=${search_domain:-none})"
