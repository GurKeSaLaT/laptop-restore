#!/usr/bin/env bash
# Nimmt einen oder mehrere Pfade unter $HOME entgegen und uebernimmt sie
# 1:1 in roles/user_config/files/ (gleiche relative Struktur), damit sie
# beim naechsten Restore automatisch mit deployed werden.
#
# Explizite Pfade statt eines blinden ~/.config-Vollsyncs: ~/.config
# enthaelt bei fast jedem System irgendwo Session-Tokens, API-Keys oder
# sonstige De-facto-Geheimnisse (Browser, Discord, diverse Tools) - ein
# unkontrollierter Sync wuerde frueher oder spaeter genau das versehentlich
# ins Repo ziehen.
#
# "--auto" automatisiert die Auswahl trotzdem, aber kontrolliert: dots-
# hyprlands eigenes ./setup install fuehrt in
# ~/.config/illogical-impulse/installed_listfile minutioes Buch ueber
# JEDE Datei, die es selbst unter $HOME anlegt (siehe cp_file()/rsync_dir*()
# in sdata/subcmd-install/3.files.sh im dots-hyprland-Repo - jeder Aufruf
# haengt die installierten Pfade an genau diese Datei an). Damit laesst
# sich zuverlaessig unterscheiden zwischen "kommt automatisch vom
# Dotfiles-Install" (in der Liste) und "hast du selbst danach angepasst/
# hinzugefuegt" (NICHT in der Liste) - ohne 3.files-legacy.sh manuell
# nachpflegen zu muessen, wenn sich dots-hyprland aendert. Findet z.B.
# ii-Einstellungen, die nur ueber eine In-Shell-GUI geschrieben werden
# (Bar-Stil, gewaehltes Wallpaper/Farbschema, ...) und sonst nirgends
# auftauchen wuerden.
#
# Aufruf:
#   ./scripts/capture-config.sh ~/.config/foot/foot.ini ~/.config/fish/config.fish
#   ./scripts/capture-config.sh --auto [Scan-Verzeichnis, Default: ~/.config]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_ROOT="$REPO_DIR/roles/user_config/files"

secret_warning() {
    local f="$1"
    if grep -qEi 'BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY|password\s*[:=]|token\s*[:=]|api[_-]?key\s*[:=]|secret\s*[:=]' "$f" 2>/dev/null; then
        echo "  !! WARNUNG: '$f' enthaelt evtl. ein Geheimnis (Muster wie 'password=', 'token:', 'PRIVATE KEY' gefunden)." >&2
        echo "     Bitte pruefen, bevor du committest - ggf. lieber per ansible-vault statt hier." >&2
    fi
}

capture_path() {
    local src="$1" rel dest
    src="$(realpath -e "$src")"
    rel="${src#"$HOME"/}"
    if [[ "$src" == "$rel" ]]; then
        echo "FEHLER: '$src' liegt nicht unter \$HOME ($HOME) - uebersprungen." >&2
        return
    fi
    dest="$DEST_ROOT/$rel"
    mkdir -p "$(dirname "$dest")"
    if [[ -d "$src" ]]; then
        cp -a "$src/." "$dest/"
        find "$src" -type f -print0 | while IFS= read -r -d '' f; do secret_warning "$f"; done
    else
        cp -a "$src" "$dest"
        secret_warning "$src"
    fi
    echo "Erfasst: ~/$rel"
}

if [[ "${1:-}" == "--auto" ]]; then
    shift
    scan_root="$(realpath -e "${1:-$HOME/.config}")"
    listfile="$HOME/.config/illogical-impulse/installed_listfile"
    if [[ ! -f "$listfile" ]]; then
        echo "FEHLER: $listfile nicht gefunden - wurde ./setup install (dots-hyprland) auf diesem System schon mal ausgefuehrt?" >&2
        exit 1
    fi

    declare -A installed_set=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && installed_set["$line"]=1
    done < "$listfile"

    # Buchhaltungsdateien des Installers selbst - kein echtes Config,
    # wuerden sonst faelschlich als "nicht automatisch" markiert, weil sie
    # sich selbst nicht in der eigenen Liste auffuehren.
    exclude_exact=(
        "$HOME/.config/illogical-impulse/installed_listfile"
        "$HOME/.config/illogical-impulse/installed_true"
    )

    # Browser-/Electron-Profilverzeichnisse (kompletter Unterbaum wird
    # uebersprungen) - Cache/Crashpad/leveldb/etc. sind Laufzeitzustand,
    # keine "Einstellungen", und Cookie-/Token-Dateien darin sind de-facto
    # Login-Credentials. Live erprobt: ohne diese Liste wurden aus einem
    # einzigen Electron-App-Profil (balenaEtcher) mehrere hundert
    # Cache-Dateien miterfasst.
    prune_dirs='mozilla|BraveSoftware|google-chrome|chromium|microsoft-edge|dconf|discord|Discord|Slack|signal-desktop|vivaldi|Element|Cache|Code Cache|GPUCache|DawnGraphiteCache|DawnWebGPUCache|Crashpad|sentry|Partitions|Shared Dictionary|leveldb|Dictionaries|telemetry|Service Worker|Session Storage|Local Storage|IndexedDB'

    found_any=0
    while IFS= read -r -d '' f; do
        rf="$(realpath -e "$f")" || continue
        # muss nach dem Aufloesen von Symlinks immer noch unter $HOME liegen
        [[ "$rf" == "$HOME"/* ]] || continue
        skip=0
        for ex in "${exclude_exact[@]}"; do
            [[ "$rf" == "$ex" ]] && skip=1 && break
        done
        [[ $skip -eq 1 ]] && continue
        case "$(basename "$rf")" in
            *[Cc]ookie*|*[Tt]oken*|lock|*.sqlite|*.sqlite3|*.db|*.log|"Network Persistent State"|Preferences|DIPS|SharedStorage|TransportSecurity|*.pid|*.sock|recently-used.xbel|QuotaManager|LOCK|CURRENT|MANIFEST-*)
                continue ;;
        esac
        # Wiresharks "recent"/"recent_common": laut eigenem Dateikopf "regenerated
        # each time Wireshark is quit" - reiner Laufzeitzustand, keine bewusste
        # Konfiguration. Live gefunden: enthielt echte IPs/MAC/WLAN-SSID aus einer
        # frueheren Capture-Session (recent.capture_file/-display_filter-Zeilen) -
        # deshalb per exaktem Pfad (nicht per Basename, um z.B. "dfilters"/
        # "colorfilters" im selben Verzeichnis weiter erfassbar zu lassen) statt
        # per genereller Verzeichnis-Sperre ausgeschlossen.
        case "$rf" in
            "$HOME/.config/wireshark/recent"|"$HOME/.config/wireshark/recent_common")
                continue ;;
        esac
        [[ "$rf" =~ /($prune_dirs)/ ]] && continue
        if [[ -z "${installed_set[$rf]+x}" ]]; then
            capture_path "$rf"
            found_any=1
        fi
    done < <(find "$scan_root" \( -type f -o -type l \) -print0)

    if [[ $found_any -eq 0 ]]; then
        echo "Nichts gefunden unter $scan_root, das nicht schon in $listfile steht."
    fi
elif [[ $# -eq 0 ]]; then
    echo "Usage: $0 <pfad-unter-\$HOME> [weitere-pfade...]" >&2
    echo "       $0 --auto [Scan-Verzeichnis, Default: ~/.config]" >&2
    exit 1
else
    for src in "$@"; do
        capture_path "$src"
    done
fi

echo
echo "roles/user_config/tasks/main.yml deployed roles/user_config/files/ als Ganzes -"
echo "kein weiterer Schritt noetig, damit es beim naechsten Restore mitkommt."
echo
cd "$REPO_DIR"
git status --short roles/user_config/files/ || true
echo
echo "Passt das? Dann: git add roles/user_config/files/ && git commit -m 'Config-Aenderungen uebernehmen' && git push"
