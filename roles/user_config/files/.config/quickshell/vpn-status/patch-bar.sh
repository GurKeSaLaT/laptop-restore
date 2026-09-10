#!/bin/bash
# Fuegt ein VPN-Kill-Switch-Status-Icon in BarContent.qml ein (neben WLAN/Bluetooth).
# Idempotent: tut nichts, wenn der Marker-Kommentar schon vorhanden ist. Wird per
# systemd --user Path-Unit automatisch erneut ausgefuehrt, sobald BarContent.qml sich
# aendert (z. B. durch einen dots-hyprland Installer-Lauf, der die Datei zuruecksetzt).
set -euo pipefail

BAR_FILE="$HOME/.config/quickshell/ii/modules/ii/bar/BarContent.qml"
MARKER="// BEGIN vpn-killswitch-icon-patch"

if [ ! -f "$BAR_FILE" ]; then
    logger -t vpn-killswitch "patch-bar.sh: BarContent.qml nicht gefunden, ueberspringe"
    exit 0
fi

if grep -qF "$MARKER" "$BAR_FILE"; then
    exit 0
fi

python3 - "$BAR_FILE" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

marker = "// BEGIN vpn-killswitch-icon-patch"
if marker in content:
    sys.exit(0)

if "import Quickshell.Io" not in content:
    content = "import Quickshell.Io\n" + content

anchor = 'text: BluetoothStatus.connected ? "bluetooth_connected" : BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"'
idx = content.find(anchor)
if idx == -1:
    print("WARNUNG: Bluetooth-Anker nicht gefunden, Patch nicht eingefuegt", file=sys.stderr)
    sys.exit(1)

import re
rest = content[idx:]
close_match = re.search(r'\n(\s*)\}\n', rest)
if not close_match:
    print("WARNUNG: schliessende Klammer nicht gefunden, Patch nicht eingefuegt", file=sys.stderr)
    sys.exit(1)

indent = close_match.group(1)
insert_pos = idx + close_match.end()

patch = f'''{indent}// BEGIN vpn-killswitch-icon-patch
{indent}FileView {{
{indent}    id: vpnKillswitchDisplayFile
{indent}    path: "/run/vpn-killswitch-display"
{indent}    watchChanges: true
{indent}    onFileChanged: reload()
{indent}    onLoaded: vpnKillswitchIcon.killswitchState = vpnKillswitchDisplayFile.text().trim()
{indent}}}
{indent}MaterialSymbol {{
{indent}    id: vpnKillswitchIcon
{indent}    Layout.leftMargin: indicatorsRowLayout.realSpacing
{indent}    property string killswitchState: "STRICT_DOWN"
{indent}    property var iconMap: ({{
{indent}        "HOME": "home",
{indent}        "PORTAL_DOWN": "public",
{indent}        "STRICT_DOWN": "block",
{indent}        "CONNECTED": "shield",
{indent}        "OVERRIDE": "warning"
{indent}    }})
{indent}    property var colorMap: ({{
{indent}        "HOME": rightSidebarButton.colText,
{indent}        "PORTAL_DOWN": "#f9a825",
{indent}        "STRICT_DOWN": "#e53935",
{indent}        "CONNECTED": "#43a047",
{indent}        "OVERRIDE": "#fb8c00"
{indent}    }})
{indent}    text: iconMap[killswitchState] ?? "help"
{indent}    iconSize: Appearance.font.pixelSize.larger
{indent}    color: colorMap[killswitchState] ?? rightSidebarButton.colText
{indent}}}
{indent}// END vpn-killswitch-icon-patch
'''

content = content[:insert_pos] + patch + content[insert_pos:]

with open(path, "w") as f:
    f.write(content)

print("Patch eingefuegt")
PYEOF

logger -t vpn-killswitch "BarContent.qml VPN-Status-Icon-Patch angewendet"
