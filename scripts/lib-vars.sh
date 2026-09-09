#!/usr/bin/env bash
# Liest die Nicht-Secret-Variablen aus group_vars/all/vars.yml fuer die
# Shell-Skripte in scripts/ - vermeidet, dieselben Werte zweimal pflegen zu
# muessen (einmal fuer Ansible, einmal fuer Bash).
#
# Bewusst kein PyYAML/python-yaml benutzt: auf einem frischen Live-ISO ist
# das i.d.R. nicht installiert. vars.yml enthaelt nur flache "key: value"-
# Paare, dafuer reicht ein simpler grep/sed-Parser.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS_FILE="$REPO_DIR/group_vars/all/vars.yml"

_yaml_get() {
    local key="$1"
    grep -E "^${key}:" "$VARS_FILE" \
        | head -n1 \
        | sed -E "s/^${key}:[[:space:]]*//; s/^\"(.*)\"\$/\1/; s/[[:space:]]*#.*\$//"
}

# Nur als Vorschlag/Default fuer scripts/00-disk-and-base-install.sh
# gedacht (z.B. auf echter Hardware wieder das gleiche NVMe-Geraet) - das
# Skript fragt das tatsaechliche Zielgeraet trotzdem immer interaktiv ab.
DEFAULT_DISK_DEVICE="$(_yaml_get disk_device)"
ZPOOL_NAME="$(_yaml_get zpool_name)"
ROOT_DATASET="${ZPOOL_NAME}/ROOT/arch0"
HOME_DATASET="${ZPOOL_NAME}/home"
ZBM_KERNEL_CMDLINE="$(_yaml_get zbm_kernel_cmdline)"
CONSOLE_KEYMAP="$(_yaml_get console_keymap)"
KERNEL_PKG="$(_yaml_get kernel_pkg)"
KERNEL_HEADERS_PKG="$(_yaml_get kernel_headers_pkg)"
