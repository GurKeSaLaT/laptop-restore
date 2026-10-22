#!/usr/bin/env bash
# Meldet Abweichungen zwischen dem laufenden System und diesem Repo:
#  1. explizit installierte Pakete (pacman -Qqe), die nicht in roles/packages/vars stehen
#     (und umgekehrt: dort stehen, aber nicht explizit installiert sind)
#  2. Dateien aus roles/user_config/files und roles/laptop_tools/files, die lokal fehlen
#     oder vom Repo abweichen
# Aufruf: ./scripts/check-drift.sh        Exit 0 = keine Abweichung, 1 = Abweichung
# Bewusst ignoriert: illogical-impulse-* (baut dots-hyprland selbst), *-debug, Basis-/Kernel-/GPU-
# Pakete (roles/hardware erkennt sie).
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
drift=0
# Bekannt volatil bzw. hardwareabhaengig: kein Drift melden
IGNORE=("$HOME/.config/QtProject.conf" "$HOME/.config/wavemon/wavemonrc")

echo "== Pakete =="
python3 - "$REPO_DIR/roles/packages/vars/main.yml" <<'PY' || drift=1
import re, subprocess, sys, yaml
v = yaml.safe_load(open(sys.argv[1]))
decl = {p for p in v["pacman_packages"] + v["aur_packages"] + [v["fish_package"]] if "{{" not in p}
exp = set(subprocess.run(["pacman", "-Qqe"], capture_output=True, text=True).stdout.split())
skip = re.compile(r"^(illogical-impulse-|base$|base-devel$|ansible|linux-lts|intel-ucode|amd-ucode|vulkan-|lib32-vulkan-|paru|yay-bin-debug)|-debug$")
extra = sorted(p for p in exp - decl if not skip.search(p))
for p in extra:
    print("  installiert, nicht im Repo:", p)
# Im Repo, aber nicht explizit installiert: als Abhaengigkeit installiert ist ok, gar nicht ist Drift
inst = set(subprocess.run(["pacman", "-Qq"], capture_output=True, text=True).stdout.split())
for p in sorted(decl - inst - {"zfsbootmenu"}):  # zfsbootmenu: bewusst nur fuer generate-zbm im Restore
    print("  im Repo, nicht installiert:", p)
sys.exit(1 if extra or decl - inst - {"zfsbootmenu"} else 0)
PY

echo "== Dateien =="
check_tree() {  # $1 Repo-Verzeichnis, $2 Ziel-Praefix, $3 optionales Mapping (bin->.local/bin ...)
    local src="$1" dst="$2"
    [[ -d "$src" ]] || return 0
    while IFS= read -r -d '' f; do
        local target="$dst/${f#"$src"/}"
        [[ " ${IGNORE[*]} " == *" $target "* ]] && continue
        if [[ ! -e "$target" ]]; then echo "  fehlt lokal: $target"; drift=1
        elif ! cmp -s "$f" "$target"; then echo "  weicht ab:   $target"; drift=1; fi
    done < <(find "$src" -type f -print0)
}
check_tree "$REPO_DIR/roles/user_config/files" "$HOME"
check_tree "$REPO_DIR/roles/laptop_tools/files/bin" "$HOME/.local/bin"
check_tree "$REPO_DIR/roles/laptop_tools/files/fish" "$HOME/.config/fish"
check_tree "$REPO_DIR/roles/laptop_tools/files/systemd" "$HOME/.config/systemd/user"

(( drift )) && echo "ABWEICHUNGEN gefunden" || echo "keine Abweichungen"
exit "$drift"
