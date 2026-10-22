#!/usr/bin/env bash
# Gibt das ansible-vault-Passwort aus `pass` (Eintrag laptop-restore/vault-pass)
# auf stdout aus - zur Verwendung als --vault-password-file.
# Voraussetzung: GPG-Key und Passwort-Store sind vorhanden (nicht auf frischer Hardware).
# Dort stattdessen --ask-vault-pass oder eine Datei (-f) verwenden.
set -euo pipefail
pass show laptop-restore/vault-pass | head -1
