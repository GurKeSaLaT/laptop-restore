# roles/user_config

Anfangs leer (kein `files/`-Verzeichnis). Befüllt wird das ausschließlich
über `scripts/capture-config.sh <pfad-unter-$HOME>` — siehe
`docs/UPDATING.md`. `tasks/main.yml` deployed dann automatisch alles, was
dort landet, mit identischer relativer Struktur nach
`/home/{{ restore_user }}/`.

Bewusst kein automatischer `~/.config`-Vollsync: siehe Kommentar am Kopf
von `scripts/capture-config.sh`.
