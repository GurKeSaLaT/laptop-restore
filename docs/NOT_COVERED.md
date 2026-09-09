# Bewusst nicht automatisiert

- **Alte NetworkManager-VPN-Verbindung `normal-1194-udp`** (UUID
  `ed3ac1b0-8c61-4f31-8237-a219ccdd515d`) mit im GNOME-Keyring
  gespeichertem Passwort. Wird laut `~/config/vpn-auto-connect.md` von der
  aktuellen Automatik (systemd-Service + Kill-Switch) nicht mehr benutzt.
  Falls du sie doch brauchst: manuell in NetworkManager neu anlegen.
- **WLAN-Passwörter für Gast-/Hotel-Netzwerke** — Struktur in
  `group_vars/all/vault.yml.example` vorbereitet (`vault_wifi_networks`),
  aber die echten SSIDs/PSKs kennt nur du.
- **`./setup install`-Interaktion der end-4-Dotfiles** — das Skript fragt
  beim ersten Lauf u. U. selbst Dinge ab (Theme-Auswahl etc.). Das Playbook
  ruft es non-interaktiv auf; falls es doch nachfragt, einmal manuell im
  chroot nachholen.
- **SSH-Keys, GPG-Keys, Browser-Profile, Steam/Spiele-Library** und
  ähnliches nutzerspezifisches `$HOME`-Gedöns — außerhalb des Scopes eines
  System-Restore-Playbooks. Eigenes Backup (z. B. Restic/Borg) empfohlen,
  dieses Playbook stellt nur die *Systemkonfiguration* wieder her, nicht
  persönliche Daten.
- **Exakte ursprüngliche `zpool create`-Flags** — der Pool existiert bereits
  und wurde nicht neu angelegt, um sie zu ermitteln; `scripts/00-disk-and-base-install.sh`
  verwendet dokumentierte ZFSBootMenu-Empfehlungen (ashift=12, zstd-Kompression,
  posixacl, relatime, xattr=sa). Funktional gleichwertig, aber ggf. nicht
  byte-identisch zu den ursprünglichen Pool-Properties.
- **`vpnks-up.sh`/`vpnks-down.sh`** (OpenVPN up/down-Hooks): Auf dem
  Referenzsystem `0700 root:root`, für diese Session nicht lesbar. In
  `roles/vpn_killswitch/files/` aus der Beschreibung in
  `~/config/vpn-auto-connect.md` und dem live beobachteten
  `/etc/resolv.conf`-Inhalt (Kommentarzeile stimmt exakt überein)
  rekonstruiert — Verhalten sollte passen, aber unbedingt in der VM
  gegentesten, bevor du dich auf den Kill-Switch verlässt.
- **`generate-zbm`-Config im Detail**: Das Tool ist auf dem laufenden System
  aktuell nicht installiert (nur die fertigen EFI-Images liegen noch da) —
  `roles/zfsbootmenu` rekonstruiert eine plausible `config.yaml`, keine
  1:1-Kopie der Original-Config. Vor dem Vertrauen auf Hardware: in der VM
  testen, dass der erzeugte Boot-Eintrag tatsächlich bootet.
