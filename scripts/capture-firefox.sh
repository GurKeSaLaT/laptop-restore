#!/usr/bin/env bash
# Erfasst Firefox-Bookmarks, installierte Erweiterungen und einen kuratierten
# Ausschnitt von prefs.js aus dem Standardprofil - nach roles/firefox/files/
# bzw. roles/firefox/vars/main.yml.
#
# Bewusst EIN eigenes Skript statt Teil von capture-config.sh: Firefox-
# Profile brauchen andere Verarbeitung als ein reiner 1:1-Dateikopiervorgang
# (jsonlz4-Backups, extensions.json-Filterung, prefs.js-Deny-Liste), auch
# wenn sie (Arch-Firefox mit MOZ_LEGACY_PROFILES=0) technisch unter
# ~/.config/mozilla/firefox liegen.
#
# Was NICHT erfasst wird (bewusst, oeffentliches Repo):
#   - places.sqlite/favicons.sqlite/cookies.sqlite/history/cache/... (volle
#     Browser-Historie + Tracking-Daten)
#   - logins.json/key4.db (gespeicherte Passwoerter - eigenes Thema, nicht
#     Teil dieser Anfrage)
#   - der komplette prefs.js-Inhalt (Telemetrie-Client-IDs, Sync-/Firefox-
#     Account-Status, interne Bookkeeping-Zeitstempel) - nur eine
#     kuratierte Teilmenge per Deny-Liste (siehe DENY_PATTERNS unten)
#
# Aufruf: ./scripts/capture-firefox.sh [--vault-password-file <datei>]
set -euo pipefail

vault_password_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-password-file)
            vault_password_file="$2"
            shift 2
            ;;
        *)
            echo "FEHLER: Unbekanntes Argument '$1'" >&2
            exit 1
            ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_ROOT="$REPO_DIR/roles/firefox/files"
FIREFOX_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"

if [[ ! -f "$FIREFOX_CONFIG_DIR/profiles.ini" ]]; then
    echo "FEHLER: '$FIREFOX_CONFIG_DIR/profiles.ini' nicht gefunden - kein Arch-typisches XDG-Firefox-Profil." >&2
    exit 1
fi

# Default-Profil ueber installs.ini (die tatsaechlich fuer DIESE Installation
# aktive Zuordnung) statt profiles.ini's eigenem "Default=" Flag ermitteln -
# profiles.ini kann mehrere Profile mit je eigenem Default-Flag aus
# frueheren Installationen enthalten, installs.ini ist die Quelle der
# Wahrheit fuer die aktuell benutzte.
install_section="$(awk -F'[][]' '/^\[.+\]$/{print $2; exit}' "$FIREFOX_CONFIG_DIR/installs.ini")"
profile_rel="$(awk -F= '/^Default=/{print $2; exit}' "$FIREFOX_CONFIG_DIR/installs.ini")"

if [[ -z "$profile_rel" ]]; then
    echo "FEHLER: Kein 'Default='-Eintrag in installs.ini gefunden." >&2
    exit 1
fi

PROFILE_DIR="$FIREFOX_CONFIG_DIR/$profile_rel"
if [[ ! -d "$PROFILE_DIR" ]]; then
    echo "FEHLER: Profilverzeichnis '$PROFILE_DIR' existiert nicht." >&2
    exit 1
fi

echo "--- Firefox-Profil: $profile_rel (Install-Sektion $install_section) ---"

mkdir -p "$DEST_ROOT" "$DEST_ROOT/$profile_rel/bookmarkbackups"

# profiles.ini/installs.ini enthalten keine absoluten Pfade (IsRelative=1),
# nur den Install-Hash (deterministisch aus dem Installationspfad
# abgeleitet - bei einer Standard-Arch-Paketinstallation nach /usr/lib/firefox
# auf jedem System identisch) und den relativen Profil-Ordnernamen - 1:1
# uebernehmbar.
cp -f "$FIREFOX_CONFIG_DIR/profiles.ini" "$DEST_ROOT/profiles.ini"
cp -f "$FIREFOX_CONFIG_DIR/installs.ini" "$DEST_ROOT/installs.ini"

# --- Bookmarks: neuestes automatisches Firefox-Backup 1:1 uebernehmen ---
newest_backup="$(ls -1t "$PROFILE_DIR"/bookmarkbackups/*.jsonlz4 2>/dev/null | head -1 || true)"
if [[ -n "$newest_backup" ]]; then
    backup_dest="$DEST_ROOT/$profile_rel/bookmarkbackups/$(basename "$newest_backup")"
    cp -f "$newest_backup" "$backup_dest"
    echo "Bookmarks-Backup uebernommen: $(basename "$newest_backup")"
    echo "  Hinweis: wird beim Restore nach bookmarkbackups/ deployt, aber NICHT automatisch"
    echo "  importiert - einmalig per Firefox-Bibliothek (Strg+Umschalt+O) > Importieren und"
    echo "  Sichern > Sicherung wiederherstellen auswaehlen."

    # Bookmarks sind persoenliche Daten (Titel/URLs, koennen einiges ueber
    # Nutzungsgewohnheiten verraten) - in einem OEFFENTLICHEN Repo deshalb
    # nie im Klartext. ansible.builtin.copy entschluesselt eine per
    # ansible-vault verschluesselte Quelldatei beim Deploy automatisch
    # (voraussgesetzt --vault-password-file/-f wird an ansible-playbook
    # uebergeben) - am Task in roles/firefox/tasks/main.yml aendert sich
    # dafuer nichts, nur die Datei selbst liegt verschluesselt vor.
    if [[ -n "$vault_password_file" ]]; then
        ansible-vault encrypt --vault-password-file "$vault_password_file" "$backup_dest"
        echo "  Per ansible-vault verschluesselt (--vault-password-file)."
    else
        echo "  !! WARNUNG: NICHT verschluesselt - vor dem Commit unbedingt per" >&2
        echo "     'ansible-vault encrypt \"$backup_dest\"' verschluesseln (oder dieses Skript" >&2
        echo "     mit --vault-password-file <datei> erneut ausfuehren)." >&2
    fi
else
    echo "WARNUNG: Kein bookmarkbackups/*.jsonlz4 gefunden - Firefox legt automatisch periodisch" >&2
    echo "  eines an, aber ggf. noch keins vorhanden. Bookmarks einmal manuell aendern/Firefox" >&2
    echo "  neustarten und das Skript erneut ausfuehren." >&2
fi

# --- Erweiterungen: nur user-installierte (nicht eingebaute) AMO-Addons ---
python3 - "$PROFILE_DIR/extensions.json" "$REPO_DIR/roles/firefox/vars/main.yml" <<'PYEOF'
import json
import sys

extensions_json_path, out_path = sys.argv[1], sys.argv[2]
with open(extensions_json_path) as f:
    data = json.load(f)

kept = []
for addon in data.get("addons", []):
    if addon.get("location") != "app-profile":
        continue
    source_uri = addon.get("sourceURI") or ""
    if not source_uri.startswith("https://addons.mozilla.org/"):
        # Mozilla-Systemerweiterungen (z.B. "newtab@mozilla.org") kommen
        # ueber archive.mozilla.org, nicht AMO - die bringt Firefox selbst
        # schon mit, nicht Teil der eigentlichen "Plugins" des Nutzers.
        continue
    kept.append({"id": addon["id"], "name": addon.get("defaultLocale", {}).get("name") or addon["id"]})

with open(out_path, "w") as f:
    f.write("---\n")
    f.write("# Von scripts/capture-firefox.sh generiert - nicht von Hand pflegen.\n")
    f.write("# Installations-URL wird in roles/firefox/tasks/main.yml aus der Extension-ID gebaut\n")
    f.write("# (AMO's \"/downloads/latest/<id>/latest.xpi\" akzeptiert die rohe Erweiterungs-ID,\n")
    f.write("# liefert live geprueft die jeweils aktuelle Version aus - kein fest einprogrammierter\n")
    f.write("# Datei-Link, der mit der Zeit veraltet/deaktiviert werden koennte).\n")
    f.write("firefox_extensions:\n")
    for e in kept:
        name = e["name"].replace('"', "'")
        f.write(f'  - id: "{e["id"]}"\n')
        f.write(f'    name: "{name}"\n')

print(f"{len(kept)} Erweiterung(en) erfasst:")
for e in kept:
    print(f"  - {e['name']} ({e['id']})")
PYEOF

# --- prefs.js: Deny-Liste statt 1:1-Kopie (fast der komplette Inhalt ist
# Telemetrie-/Sync-/Bookkeeping-Rauschen, siehe Kommentar oben) ---
python3 - "$PROFILE_DIR/prefs.js" "$DEST_ROOT/$profile_rel/user.js" <<'PYEOF'
import re
import sys

prefs_js_path, out_path = sys.argv[1], sys.argv[2]

# Kategorien statt Einzel-Keys, damit spaetere erneute Laeufe (wenn der
# Nutzer echte neue Einstellungen vornimmt) automatisch mit erfasst werden,
# ohne dieses Skript anzufassen.
DENY_PATTERNS = [
    r"^app\.normandy\.",
    r"^app\.update\.lastUpdateTime\.",
    r"^browser\.contextual-services\.",
    r"^browser\.crashReports\.",
    r"^browser\.engagement\.",
    r"^browser\.ipProtection\.",
    r"^browser\.laterrun\.",
    r"^browser\.migration\.version$",
    r"^browser\.ml\.",
    r"^browser\.newtabpage\.activity-stream\.",
    r"^browser\.newtabpage\.(storageVersion|trainhopAddon)",
    r"^browser\.pagethumbnails\.",
    r"^browser\.proton\.",
    r"^browser\.region\.",
    r"^browser\.rights\.",
    r"^browser\.safebrowsing\.provider\.",
    r"^browser\.search\.(experiment|totalSearches|serpEventTelemetryCategorization|region)(\.|$)",
    r"^browser\.sessionstore\.",
    r"^browser\.shell\.mostRecentDateSetAsDefault",
    r"^browser\.startup\.(couldRestoreSession|homepage_override|lastColdStartupCheck)",
    r"^browser\.tabs\.splitview\.hasUsed",
    r"^browser\.termsofuse\.",
    r"^browser\.toolbarbuttons\.introduced\.",
    r"^browser\.topsites\.contile\.",
    r"^browser\.urlbar\.(lastUrlbarSearchSeconds|placeholderName|quickactions|quicksuggest\.migrationVersion|tipShownCount)",
    r"^captchadetection\.",
    r"^datareporting\.",
    r"^devtools\.debugger\.pending-selected-location",
    r"^distribution\.",
    r"^dom\.push\.userAgentID",
    r"^doh-rollout\.",
    r"^extensions\.(blocklist|colorway|databaseSchema|getAddons|last[AP]|pendingOperations|quarantinedDomains|signatureCheckpoint|systemAddonSet|ui\.|webextensions\.)",
    r"^gecko\.handlerService\.",
    r"^identity\.fxaccounts\.",
    r"^idle\.lastDailyNotification",
    r"^media\.(eme|gmp)",
    r"^media\.videocontrols\.picture-in-picture\.video-toggle\.first-seen-secs",
    r"^media\.webspeech\.",
    r"^messaging-system-action\.",
    r"^network\.cookie\.",
    r"^nimbus\.",
    r"^pdfjs\.",
    r"^places\.",
    r"^privacy\.(?!clearOnShutdown_v2)",
    r"^services\.settings\.",
    r"^services\.sync\.",
    r"^sidebar\.(backupState|installed\.extensions|nimbus|notification)",
    r"^signon\.",
    r"^storage\.vacuum\.",
    r"^toolkit\.(profiles|startup|telemetry)\.",
    r"^trailhead\.",
]
deny_re = re.compile("|".join(DENY_PATTERNS))

pref_re = re.compile(r'^user_pref\("([^"]+)",\s*(.*)\);\s*$')

kept_lines = []
kept_keys = []
dropped_count = 0
with open(prefs_js_path) as f:
    for line in f:
        m = pref_re.match(line.strip())
        if not m:
            continue
        key = m.group(1)
        if deny_re.search(key):
            dropped_count += 1
            continue
        kept_lines.append(line.strip())
        kept_keys.append(key)

with open(out_path, "w") as f:
    f.write("// Von scripts/capture-firefox.sh generiert - nicht von Hand pflegen.\n")
    f.write("// Firefox liest user.js bei jedem Start als Override-Schicht ueber prefs.js -\n")
    f.write("// deshalb hier statt eines fragilen prefs.js-Merges waehrend des Chroot-Laufs\n")
    f.write("// (Firefox laeuft zu diesem Zeitpunkt noch gar nicht).\n")
    for line in kept_lines:
        f.write(line + "\n")

print(f"{len(kept_keys)} Einstellung(en) uebernommen, {dropped_count} per Deny-Liste ausgefiltert.")
print("Uebernommen:")
for k in kept_keys:
    print(f"  - {k}")
PYEOF

echo
echo "--- Fertig. Bitte roles/firefox/files/ und roles/firefox/vars/main.yml vor dem Commit pruefen. ---"
