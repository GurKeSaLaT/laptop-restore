# laptop-restore

Ansible-Playbook, um diesen Laptop (UEFI-x86_64, Arch Linux auf ZFS-Root,
ZFSBootMenu, Hyprland/end-4-Dotfiles, VPN-Killswitch) von einem
Live-Environment aus komplett neu aufzusetzen — inklusive Partitionierung und
ZFS-Pool-Erstellung ("Bare-Metal-Restore").

Getestet werden soll das zunächst in einer VM, bevor es an echter Hardware
läuft. Siehe [`docs/TESTING.md`](docs/TESTING.md).

## Warum keine reine Alpine-Live-Umgebung?

Für den eigentlichen Bare-Metal-Teil (`scripts/00-disk-and-base-install.sh`)
wird **`pacstrap`** gebraucht — ein Arch-eigenes Tool, das es auf Alpine nicht
gibt. Empfohlen wird deshalb eine ganz normale, offizielle **Arch-Linux-Live-ISO**
(kein spezielles ZFS-Image nötig) — `scripts/00-disk-and-base-install.sh`
bootstrappt ZFS für die Live-Session selbst: baut `zfs-utils`+`zfs-dkms`
**aus dem AUR** (nicht aus dem `archzfs`-Repo — dessen vorgebaute/gecachte
Version hinkt dem Mainline-Kernel oft hinterher; live erlebt: `archzfs` hatte
nur eine OpenZFS-Version mit Support bis Kernel 6.15, während der aktuelle
Live-Kernel schon deutlich neuer war und nur das AUR-Paket damit zurechtkam).

Alpine (oder ein anderes Live-System) eignet sich nur, wenn du Schritt 0
(Partitionierung/Pool/`pacstrap`) manuell/anders löst und danach direkt bei
Stufe 1 (Ansible gegen den fertig gemounteten `/mnt`-Chroot) einsteigst.

## Ablauf in zwei Stufen

Ansible kann nicht "von außen" auf ein System wirken, das noch gar nicht
existiert (leere Platte) oder noch kein SSH/Python-Environment hat, in das
man sich einloggen könnte. Deshalb zwei Stufen:

**Stufe 0 — Shell-Skript (`scripts/00-disk-and-base-install.sh`)**
Bewusst *kein* Ansible: Partitionierung und ZFS-Pool-Erstellung sind
destruktiv, maschinenspezifisch und einmalig — das gehört in ein Skript, das
man vor dem Ausführen komplett durchliest, nicht in eine deklarative Rolle.
Das Skript:
1. fragt das Zielgerät ab und verlangt eine explizite `YES`-Bestätigung,
2. partitioniert die Platte (EFI + ZFS-Partition),
3. legt den Pool `mappepool` mit den Datasets `ROOT/arch0` und `home` an,
4. mountet unter `/mnt`,
5. `pacstrap`-t ein Minimalsystem (inkl. `ansible`, `git`, `python`),
6. schreibt `/etc/fstab` (nur die EFI-Zeile — ZFS braucht keine),
7. kopiert `/etc/resolv.conf` ins chroot (für Internetzugriff dort),
8. ruft am Ende automatisch Stufe 1 auf.

**Stufe 1 — Ansible, per `chroot`-Connection (`site.yml`)**
Alles, was danach idempotent und deklarativ beschreibbar ist: Pakete,
ZFSBootMenu, Boot-Environments (`zectl`), eigene Skripte, Dotfiles,
Hyprland-Config, VPN-Killswitch, NetworkManager. Läuft **ohne SSH** —
Ansibles `chroot`-Connection-Plugin führt Module direkt in `/mnt` aus
(siehe `inventory/chroot.ini`).

Nach Stufe 1: `/mnt` aushängen, `efibootmgr`-Eintrag prüfen, reboot, im
ZFSBootMenu-Menü das neue BE wählen.

## Nutzung

```bash
# Auf dem Live-System (als root):
git clone <URL-dieses-privaten-Repos> laptop-restore
cd laptop-restore
./scripts/00-disk-and-base-install.sh   # fragt interaktiv, ruft Stufe 1 selbst auf
```

Stufe 1 lässt sich auch einzeln (erneut) laufen, z. B. um nach einem Fehler
nur ab einer bestimmten Rolle fortzusetzen:

```bash
ansible-playbook -i inventory/chroot.ini site.yml --ask-vault-pass \
  --start-at-task="..."
# oder gezielt:
ansible-playbook -i inventory/chroot.ini site.yml --ask-vault-pass \
  --tags vpn_killswitch
```

## Secrets — nichts davon liegt im Klartext auf GitHub

GitHubs eigene "Secrets"-Funktion ist für **GitHub Actions/Codespaces**
gedacht: Werte, die zur Laufzeit *in einem GitHub-gehosteten CI-Job*
injiziert werden. Für unseren Fall — ein frisch gebootetes Live-System klont
das Repo per `git clone` und braucht die Secrets *lokal* — bringt das nichts,
weil ein simples `git clone` nie Zugriff auf Actions-Secrets bekommt.

Stattdessen: **`ansible-vault`**. Alle Geheimnisse (VPN-Zugangsdaten,
WLAN-Passwörter, …) liegen in `group_vars/all/vault.yml` — aber
**verschlüsselt** committed. Das Vault-Passwort selbst ist **nirgendwo im
Repo**, sondern:
- wird beim Playbook-Lauf interaktiv abgefragt (`--ask-vault-pass`), oder
- kommt aus einem Passwort-Manager deiner Wahl (z. B. `bw get password ...`
  in ein `--vault-password-file`-Skript verpackt).

Details, wie du das Vault-Passwort selbst sicherst (z. B. auf einem
USB-Stick, den du getrennt vom Laptop aufbewahrst): siehe
[`docs/SECRETS.md`](docs/SECRETS.md).

Ein Git-Pre-Commit-Hook (`scripts/git-hooks/pre-commit`) verweigert jeden
Commit, in dem `group_vars/all/vault.yml` *nicht* mit `$ANSIBLE_VAULT`
beginnt — also nie unverschlüsselt reinrutscht. Einrichten:

```bash
git config core.hooksPath scripts/git-hooks
```

## Was dieses Playbook abdeckt

- ZFS-Root auf `mappepool` (`ROOT/arch0`, `home`), ZFSBootMenu mit
  EFI-Fallback-Kopie (`/boot/efi/EFI/BOOT/BOOTX64.EFI`).
- `zectl` + `zectl-pacman-hook` (automatisches BE bei Kernel-Updates,
  `pacmanhook-prunecount=3`).
- Eigene Skripte unter `/usr/local/bin`: `zbe-rotate`, `safe-update`,
  `update-dotfiles` (24h-Boot-Environment-Rotation vor Updates).
- end-4/dots-hyprland (Hyprland-Dotfiles), deutsches Tastaturlayout
  (`kb_layout = "de"`, Konsole `de-latin1`).
- VPN-Auto-Connect + Kill-Switch: OpenVPN als systemd-Service (nicht über
  NetworkManager), nftables-Kill-Switch mit HOME/STRICT/PORTAL-Zuständen,
  Ruhezustand-Reconnect-Hook, NetworkManager-Dispatcher.
- Basis-Systemkonfiguration (Hostname, Locale, Zeitzone, Konsolen-Keymap,
  Benutzer, sudo).
- Paketliste (offizielle Repos + AUR via `paru`).
- **Hardware-Erkennung** (`roles/hardware`): CPU-Microcode
  (`intel-ucode`/`amd-ucode`) und GPU-Vulkan-Treiber
  (`vulkan-intel`/`vulkan-radeon`/`nvidia-open` + jeweilige `lib32-*`,
  auch mehrere gleichzeitig bei Hybrid-Grafik) werden zur Laufzeit anhand
  der tatsächlichen Zielhardware ermittelt (`/proc/cpuinfo`,
  `/sys/bus/pci`), nicht fest im Referenzsystem verdrahtet — das Playbook
  läuft damit auch auf anderer Hardware als dem einen Laptop, für den es
  ursprünglich gebaut wurde.
- **SSH-Zugriff, neu** (auf dem Referenzsystem bisher nicht aktiv): `sshd`
  aktiviert, ausschließlich Public-Key-Auth (`PasswordAuthentication no`,
  `PermitRootLogin no`). Privater Schlüssel liegt **nicht** in diesem Repo,
  sondern lokal auf diesem Rechner unter `~/.ssh/new_laptop`
  (`~/.ssh/new_laptop.pub` daneben) — Login damit:
  `ssh -i ~/.ssh/new_laptop <restore_user>@<neuer-laptop>` (`<restore_user>`
  siehe `group_vars/all/vars.yml`). Nur der öffentliche
  Teil steht in `group_vars/all/vars.yml` (`ssh_authorized_keys`). Weiteres
  Gerät zulassen: dessen Public Key einfach als zusätzliche Zeile dort
  ergänzen.
- **SSH-Client-Identitäten** (`roles/ssh_client`): `~/.ssh/config`,
  `known_hosts` sowie die privaten Schlüssel für `github.com`,
  `home_server` (Root-Zugriff Heimserver), `firewall` und `wifi_pi` —
  alle privaten Schlüssel liegen verschlüsselt in `vault.yml`
  (`vault_ssh_client_keys`), die öffentlichen (kein Geheimnis) in
  `vars.yml` (`ssh_client_public_keys`). Die eigentlichen Hostnamen/IPs
  dahinter liegen ebenfalls im Vault (`vault_ssh_client_config_extra`,
  `vault_ssh_known_hosts_extra`), nicht in dieser Doku.
- Das eigene Heimnetz-WLAN wird automatisch angelegt (`vault_wifi_networks`
  — SSID/PSK liegen verschlüsselt im Vault, nicht in dieser Doku).
- **Update-Mechanismus** (`docs/UPDATING.md`): `scripts/capture-packages.sh`
  hält die Paketliste aktuell, `scripts/capture-config.sh <pfad>` holt
  gezielt einzelne $HOME-Configs (z. B. Custom-Anpassungen an den
  end-4-Dotfiles) zurück ins Repo — bewusst kein automatischer
  `~/.config`-Vollsync (Secrets-Risiko, siehe dort).

**Nicht abgedeckt** (bewusst, siehe `docs/NOT_COVERED.md`):
- Die alte, ungenutzte NetworkManager-VPN-Verbindung `normal-1194-udp` mit
  gespeichertem Passwort im GNOME-Keyring — das lässt sich nicht sauber
  automatisiert wiederherstellen und wird laut Doku ohnehin nicht mehr
  gebraucht.
- WLAN-Passwörter für Gast-/Hotel-Netzwerke mit Captive Portal — wechseln
  ohnehin ständig, bewusst nicht automatisiert.
- Alles, was `end-4/dots-hyprland`s `./setup install` selbst an
  Nutzerkonfiguration abfragt (läuft interaktiv beim ersten Dotfiles-Setup).

## Repo-Struktur

```
.
├── scripts/
│   ├── 00-disk-and-base-install.sh   # Stufe 0: Partitionierung, ZFS, pacstrap
│   ├── capture-packages.sh           # Update-Mechanismus: Paketliste
│   ├── capture-config.sh             # Update-Mechanismus: einzelne $HOME-Configs
│   └── git-hooks/pre-commit          # verhindert Klartext-Secrets im Commit
├── site.yml                          # Stufe 1: Ansible-Einstiegspunkt
├── inventory/chroot.ini              # Ziel = /mnt via chroot-Connection
├── group_vars/all/
│   ├── vars.yml                      # normale Variablen (kein Secret)
│   └── vault.yml.example             # Vorlage — kopieren, ausfüllen, verschlüsseln
└── roles/
    ├── base_system/      # Hostname, Locale, Zeitzone, User, sudo
    ├── hardware/          # CPU-/GPU-Erkennung -> ucode_pkg/gpu_packages
    ├── packages/          # pacman + AUR (paru)
    ├── zfsbootmenu/       # generate-zbm, EFI-Fallback, efibootmgr
    ├── boot_environments/ # zectl + eigene Skripte
    ├── dotfiles/          # end-4/dots-hyprland
    ├── hyprland/          # kb_layout etc.
    ├── user_config/       # per capture-config.sh erfasste $HOME-Configs
    ├── networkmanager/    # unmanaged tun0
    ├── ssh/                # sshd, Public-Key-only
    ├── ssh_client/         # ~/.ssh Client-Identitäten (github/home_server/firewall/wifi_pi)
    └── vpn_killswitch/    # OpenVPN-Service, nftables, systemd-sleep-Hook
```
