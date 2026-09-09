#!/usr/bin/env bash
# Aktualisiert roles/packages/vars/main.yml aus dem tatsaechlich auf DIESEM
# Rechner installierten Paketbestand (pacman -Qqe / -Qqm). Lauf das hier,
# nachdem du Pakete installiert/entfernt hast, dann committen+pushen.
#
# Aufruf: ./scripts/capture-packages.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS_FILE="$REPO_DIR/roles/packages/vars/main.yml"
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/lib-vars.sh"

mapfile -t explicit < <(pacman -Qqe | sort)
mapfile -t foreign < <(pacman -Qqm | sort)
mapfile -t pacman_only < <(comm -23 <(printf '%s\n' "${explicit[@]}") <(printf '%s\n' "${foreign[@]}"))

{
    echo "---"
    echo "# Automatisch erzeugt von scripts/capture-packages.sh am $(date -I)."
    echo "# Nicht von Hand editieren - Aenderungen gehen beim naechsten Lauf verloren,"
    echo "# stattdessen: Pakete installieren/entfernen, Skript erneut laufen lassen."
    echo "#"
    echo "# pacman_packages = pacman -Qqe MINUS pacman -Qqm (offizielle Repos)."
    echo "# aur_packages    = pacman -Qqm (alles nicht aus offiziellen Repos),"
    echo "#                   ohne paru/paru-debug - die baut roles/packages per"
    echo "#                   eigenem Bootstrap-Task (Henne-Ei: paru installiert"
    echo "#                   sich nicht selbst)."
    echo "#"
    echo "# CPU-Microcode + GPU-Vulkan-Treiber (intel-ucode/amd-ucode,"
    echo "# vulkan-intel/-radeon, lib32-Pendants, nvidia*) bewusst NICHT hier -"
    echo "# die erkennt roles/hardware zur Laufzeit von der Zielhardware, sonst"
    echo "# wuerde dieses Skript sie von DIESEM Rechner aus fest eintragen und"
    echo "# das Playbook wieder an genau diese Hardware binden."
    echo
    echo "pacman_packages:"
    for p in "${pacman_only[@]}"; do
        case "$p" in
            "$KERNEL_PKG") echo '  - "{{ kernel_pkg }}"' ;;
            "$KERNEL_HEADERS_PKG") echo '  - "{{ kernel_headers_pkg }}"' ;;
            fish) : ;; # separat ueber fish_package unten
            intel-ucode|amd-ucode) : ;; # roles/hardware -> ucode_pkg
            vulkan-intel|lib32-vulkan-intel|vulkan-radeon|lib32-vulkan-radeon) : ;; # roles/hardware -> gpu_packages
            nvidia|nvidia-open|nvidia-utils|lib32-nvidia-utils) : ;; # roles/hardware -> gpu_packages
            *) echo "  - $p" ;;
        esac
    done
    echo
    echo "aur_packages:"
    for p in "${foreign[@]}"; do
        case "$p" in
            paru|paru-debug) : ;;
            *) echo "  - $p" ;;
        esac
    done
    echo
    echo "fish_package: fish"
} > "$VARS_FILE"

echo "Aktualisiert: $VARS_FILE"
echo
cd "$REPO_DIR"
git --no-pager diff -- roles/packages/vars/main.yml || true
echo
echo "Passt das? Dann: git add roles/packages/vars/main.yml && git commit -m 'Pakete aktualisieren' && git push"
