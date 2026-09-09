# In der VM testen

Bevor irgendetwas davon an echte Hardware kommt: komplett in einer VM
durchspielen (UEFI, nicht BIOS/CSM — ZFSBootMenu braucht ein EFI-System).

## Voraussetzungen

- QEMU/libvirt (oder VirtualBox/VMware, solange UEFI-Firmware unterstützt
  wird) mit `OVMF`-Firmware (UEFI).
- VM-Disk: mindestens 20G, `virtio` oder `nvme` als Controller. Welches
  Geraet das im Live-System wird (`/dev/vda`, `/dev/nvme0n1`, …), fragt
  `scripts/00-disk-and-base-install.sh` interaktiv ab (Liste aller
  Laufwerke außer dem Boot-Medium) — vorher nichts in `vars.yml` anpassen
  nötig.
- Als Live-System: eine ganz normale, offizielle Arch-ISO — im QEMU-CDROM
  einhängen, mit `OVMF_CODE.fd` booten. ZFS für die Live-Session bootstrappt
  `scripts/00-disk-and-base-install.sh` selbst (siehe README, Abschnitt
  "Warum keine reine Alpine-Live-Umgebung?").
- Mindestens 4G RAM für die VM — das Skript vergrößert das archiso-Overlay
  (`cowspace`, defaultmäßig oft nur ~256M egal wie viel RAM da ist) selbst
  auf die Hälfte des RAM, aber dafür muss natürlich genug RAM da sein.
- Netzwerk in der VM (für `pacstrap`, AUR-Pakete, Dotfiles-Clone).

## Kurzer Testlauf

```bash
qemu-img create -f qcow2 test.qcow2 20G
qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
  -drive if=virtio,file=test.qcow2,format=qcow2 \
  -cdrom archlinux-x86_64.iso \
  -bios /usr/share/ovmf/x64/OVMF.4m.fd \
  -boot d
```

Im Live-System dann wie in der Haupt-`README.md` beschrieben vorgehen -
`scripts/00-disk-and-base-install.sh` zeigt dir beim Start eine Liste aller
verfügbaren Laufwerke (das Boot-Medium ist raus) und du wählst per Nummer
das Test-Ziel (z. B. `/dev/vda`) aus.

## Was konkret prüfen

- [ ] Pool/Datasets werden korrekt angelegt (`zpool status`, `zfs list -t all`).
- [ ] `pacstrap` läuft durch, `/mnt/etc/fstab` enthält nur die EFI-Zeile.
- [ ] `ansible-playbook -i inventory/chroot.ini site.yml --ask-vault-pass`
      läuft ohne Fehler durch (`--check` vorher zum groben Trockenlauf,
      auch wenn ZFS/Boot-Tasks im Check-Mode nicht alles sauber simulieren).
- [ ] Nach `efibootmgr`-Eintrag + Reboot: ZFSBootMenu-Menü erscheint,
      zeigt `arch0` als Boot-Environment.
- [ ] Boot in `arch0` funktioniert, System kommt bis zum Login.
- [ ] `zectl list` zeigt das BE, `safe-update`/`update-dotfiles` sind
      ausführbar und legen bei Bedarf neue BEs an.
- [ ] Hyprland startet, `kb_layout = de` aktiv.
- [ ] `systemctl status vpn-killswitch.timer openvpn-client@normal-1194-udp.service`
      — Kill-Switch-Zustandsmaschine reagiert (`cat /run/vpn-killswitch-state`).

Erst wenn das alles in der VM sauber durchläuft, an echter Hardware
wiederholen — und selbst dann: Boot-Environment-Rollback (`arch0` bleibt im
ZBM-Menü wählbar) ist dein Sicherheitsnetz, falls doch etwas schiefgeht.
