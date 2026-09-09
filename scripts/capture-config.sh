#!/usr/bin/env bash
# Nimmt einen oder mehrere Pfade unter $HOME entgegen und uebernimmt sie
# 1:1 in roles/user_config/files/ (gleiche relative Struktur), damit sie
# beim naechsten Restore automatisch mit deployed werden.
#
# Bewusst explizit statt eines automatischen ~/.config-Vollsyncs: ~/.config
# enthaelt bei fast jedem System irgendwo Session-Tokens, API-Keys oder
# sonstige De-facto-Geheimnisse (Browser, Discord, diverse Tools) - ein
# blinder Sync wuerde frueher oder spaeter genau das versehentlich ins
# Repo ziehen. Du entscheidest pro Pfad bewusst, was es wert ist, getrackt
# zu werden.
#
# Aufruf:
#   ./scripts/capture-config.sh ~/.config/foot/foot.ini ~/.config/fish/config.fish
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <pfad-unter-\$HOME> [weitere-pfade...]" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_ROOT="$REPO_DIR/roles/user_config/files"

secret_warning() {
    local f="$1"
    if grep -qEi 'BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY|password\s*[:=]|token\s*[:=]|api[_-]?key\s*[:=]|secret\s*[:=]' "$f" 2>/dev/null; then
        echo "  !! WARNUNG: '$f' enthaelt evtl. ein Geheimnis (Muster wie 'password=', 'token:', 'PRIVATE KEY' gefunden)." >&2
        echo "     Bitte pruefen, bevor du committest - ggf. lieber per ansible-vault statt hier." >&2
    fi
}

for src in "$@"; do
    src="$(realpath -e "$src")"
    rel="${src#"$HOME"/}"
    if [[ "$src" == "$rel" ]]; then
        echo "FEHLER: '$src' liegt nicht unter \$HOME ($HOME) - uebersprungen." >&2
        continue
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
done

echo
echo "roles/user_config/tasks/main.yml deployed roles/user_config/files/ als Ganzes -"
echo "kein weiterer Schritt noetig, damit es beim naechsten Restore mitkommt."
echo
cd "$REPO_DIR"
git status --short roles/user_config/files/ || true
echo
echo "Passt das? Dann: git add roles/user_config/files/ && git commit -m 'Config-Aenderungen uebernehmen' && git push"
