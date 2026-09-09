#!/usr/bin/env bash
# Stufe 0: Partitionierung, ZFS-Pool, pacstrap, Uebergabe an Ansible (Stufe 1).
#
# ACHTUNG: Dieses Skript loescht die Zielplatte komplett. Vorher lesen,
# nicht blind ausfuehren. Gedacht zum Starten aus einer Arch-Live-Umgebung
# mit geladenem zfs-Kernelmodul (siehe README.md, Abschnitt "Warum keine
# reine Alpine-Live-Umgebung?").
#
# Aufruf: sudo ./scripts/00-disk-and-base-install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/lib-vars.sh"

if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausfuehren (Live-Umgebung: meist ohnehin root)." >&2
    exit 1
fi

# archiso's Live-Overlay (cowspace) hat oft eine feste, kleine Groesse
# (z.B. 256M) unabhaengig vom tatsaechlich vorhandenen RAM - live in einer
# 4G-RAM-VM beobachtet, reichte nicht mal fuer die ansible-Installation
# ("Partition / too full"). Auf 75% des RAM vergroessern (min. 1G), falls
# es dieses Overlay gibt - 50% reichte live selbst mit Cache-Aufraeumen
# zwischendurch noch knapp nicht (base-devel-Toolchain + Kernel-Header +
# zwei AUR-Builds fuer den ZFS-Bootstrap kommen einiges zusammen).
cowspace_mount="$(mount | awk '/cowspace/ {print $3; exit}')"
if [[ -n "$cowspace_mount" ]]; then
    total_mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    target_mb=$(( total_mem_kb * 3 / 1024 / 4 ))
    (( target_mb < 1024 )) && target_mb=1024
    echo "--- Live-Overlay ($cowspace_mount) auf ${target_mb}M vergroessern ---"
    mount -o "remount,size=${target_mb}M" "$cowspace_mount"
fi

# ansible wird HIER auf dem Live-System gebraucht (fuer den
# ansible-playbook-Aufruf ganz am Ende dieses Skripts) - unabhaengig davon,
# dass es weiter unten auch fuer das Zielsystem pacstrap-t wird. Auf einer
# frischen Arch-Live-ISO ist es standardmaessig nicht installiert.
if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "--- ansible fehlt auf dem Live-System, installiere nach ---"
    pacman -Sy --noconfirm --needed ansible
fi

# community.general (pacman/nmcli-Module) + ansible.posix werden von den
# Rollen gebraucht, sind aber nicht Teil von ansible-core. Idempotent -
# ansible-galaxy ueberspringt schon installierte Collections von selbst.
echo "--- Ansible-Collections (community.general, ansible.posix) sicherstellen ---"
ansible-galaxy collection install -r "$REPO_DIR/requirements.yml"

# Listet alle Laufwerke auf, die als Installationsziel infrage kommen, und
# laesst interaktiv eins auswaehlen. Schliesst das Medium, von dem gerade
# gebootet wurde (z.B. der USB-Stick mit der Live-ISO), automatisch aus -
# archiso mountet das unter /run/archiso/bootmnt, darueber laesst sich das
# zugrundeliegende Blockgeraet ermitteln.
select_disk() {
    local boot_src="" boot_disk=""
    boot_src="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
    if [[ -n "$boot_src" ]]; then
        boot_disk="/dev/$(lsblk -no PKNAME "$boot_src" 2>/dev/null || true)"
    fi

    local -a names sizes labels
    local line NAME SIZE MODEL TRAN RM
    # -P (Key="Value"-Paare) statt --separator: robust auch bei Leerzeichen
    # in MODEL, und --separator fehlt auf manchen (aelteren) util-linux-
    # Versionen (z.B. auf manchen Live-ISOs beobachtet).
    while IFS= read -r line; do
        NAME="" SIZE="" MODEL="" TRAN="" RM=""
        eval "$line"
        [[ -n "$boot_disk" && "$NAME" == "$boot_disk" ]] && continue
        [[ "$NAME" =~ ^/dev/(loop|sr|zram) ]] && continue
        names+=("$NAME")
        sizes+=("$SIZE")
        local extra="${MODEL:-unbekanntes Modell}"
        [[ -n "$TRAN" ]] && extra="$extra, $TRAN"
        [[ "$RM" == "1" ]] && extra="$extra, WECHSELDATENTRAEGER"
        labels+=("$extra")
    done < <(lsblk -dPp -o NAME,SIZE,MODEL,TRAN,RM)

    if [[ ${#names[@]} -eq 0 ]]; then
        echo "FEHLER: Kein passendes Zielgeraet gefunden (lsblk lieferte nichts Brauchbares)." >&2
        exit 1
    fi

    echo "Verfuegbare Laufwerke (das Boot-Medium ist bereits ausgeschlossen):" >&2
    local i
    for i in "${!names[@]}"; do
        printf '  [%d] %-14s %8s   %s\n' "$((i + 1))" "${names[$i]}" "${sizes[$i]}" "${labels[$i]}" >&2
    done
    echo >&2

    local choice
    while true; do
        read -r -p "Nummer des Ziel-Laufwerks eingeben: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
            DISK_DEVICE="${names[$((choice - 1))]}"
            return
        fi
        echo "Ungueltige Auswahl, bitte Nummer aus der Liste eingeben." >&2
    done
}

select_disk

# Partitions-Suffix: Geraete, deren Name auf eine Ziffer endet (nvme0n1,
# loop0, mmcblk0, ...) brauchen ein "p" vor der Partitionsnummer
# (nvme0n1p1), alle anderen (sda, vda, xvda, ...) nicht (vda1, nicht
# vdap1). Naive "${DISK_DEVICE}p1"-Annahme bricht z.B. in QEMU mit
# virtio-Disks (/dev/vda) - live erst so gefunden.
case "$DISK_DEVICE" in
    *[0-9]) PART_SUFFIX="p" ;;
    *) PART_SUFFIX="" ;;
esac
EFI_PART="${DISK_DEVICE}${PART_SUFFIX}1"
ZFS_PART="${DISK_DEVICE}${PART_SUFFIX}2"

echo "=== laptop-restore: Stufe 0 (Disk + Base-Install) ==="
echo "Ziel-Disk:      $DISK_DEVICE"
echo "EFI-Partition:   $EFI_PART"
echo "ZFS-Partition:   $ZFS_PART"
echo "Pool-Name:       $ZPOOL_NAME"
echo

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "FEHLER: Kein UEFI-Boot erkannt (/sys/firmware/efi/efivars fehlt)." >&2
    echo "ZFSBootMenu braucht UEFI. Live-Medium im UEFI-Modus booten." >&2
    exit 1
fi

# ZFS im Live-System bootstrappen (fuer die zpool/zfs-Befehle unten - das
# Zielsystem bekommt sein eigenes zfs-dkms spaeter separat via roles/packages).
# Bewusst AUR statt archzfs-Repo-Paket: archzfs' vorgebaute/gecachte
# zfs-dkms-Version hinkt dem Mainline-Kernel oft hinterher (live erlebt:
# archzfs-Version 2.3.3 unterstuetzte nur bis Kernel 6.15, AUR hatte zum
# selben Zeitpunkt schon 2.4.4 mit Support fuer den aktuellen 7.2.2-Kernel).
# --skippgpcheck: der Signing-Key fehlt im frischen Live-Keyring, fuer
# dieses Wegwerf-Environment akzeptabel.
if ! command -v zpool >/dev/null 2>&1; then
    echo "--- ZFS fehlt im Live-System, baue zfs-utils+zfs-dkms aus dem AUR ---"

    # linux-headers MUSS exakt zum laufenden Live-Kernel passen (dkms baut
    # gegen die Header, nicht gegen "irgendeinen aktuellen Kernel"). Ein
    # simples "pacman -S linux-headers" zieht nach einem vorherigen
    # "pacman -Sy" (s.o. fuer ansible etc.) die NEUESTE im Repo verfuegbare
    # Version - die kann schon neuer sein als der tatsaechlich gebootete
    # Live-Kernel (auf einem rolling-release-Spiegel jederzeit moeglich,
    # live beobachtet: Kernel 7.2.2 lief, Repo hatte schon 7.2.4). Deshalb
    # exakt passende Version explizit aus dem Arch Linux Archive ziehen.
    running_kver="$(pacman -Q linux | awk '{print $2}')"
    installed_headers_kver="$(pacman -Q linux-headers 2>/dev/null | awk '{print $2}' || true)"
    if [[ "$installed_headers_kver" != "$running_kver" ]]; then
        echo "--- linux-headers ${running_kver} (exakt passend zum laufenden Kernel) installieren ---"
        pacman -R --noconfirm --nodeps linux-headers 2>/dev/null || true
        pacman -U --noconfirm \
            "https://archive.archlinux.org/packages/l/linux-headers/linux-headers-${running_kver}-x86_64.pkg.tar.zst"
    fi

    pacman -Sy --noconfirm --needed base-devel git

    if ! id builder >/dev/null 2>&1; then
        useradd -m -G wheel builder
    fi
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-live-zfs-build

    for pkg in zfs-utils zfs-dkms; do
        builddir="/tmp/aur-build-${pkg}"
        rm -rf "$builddir"
        # || true: makepkg -si ruft am Ende pacmans mkinitcpio-Hook auf, der
        # im Live-Overlay auf /boot/vmlinuz-linux nicht zugreifen kann und
        # deshalb mit Exit != 0 abbricht - das Paket (inkl. dkms-Modulbau)
        # ist zu dem Zeitpunkt aber schon erfolgreich installiert, nur das
        # (hier irrelevante) Live-Boot-Image wird nicht neu gebaut. Ob der
        # eigentliche ZFS-Bootstrap geklappt hat, prueft der Block danach.
        su - builder -c "
            set -e
            git clone https://aur.archlinux.org/${pkg}.git '$builddir'
            cd '$builddir'
            makepkg -si --noconfirm --needed --skippgpcheck
        " || true
        # Build-Artefakte + Paket-Cache sofort wieder freigeben - das
        # Live-Overlay ist trotz Auto-Vergroesserung (s.o.) knapp, live
        # erlebt: "No space left on device" beim dkms-Build nach zwei
        # AUR-Builds inkl. base-devel-Toolchain + Kernel-Headern.
        rm -rf "$builddir"
        pacman -Scc --noconfirm >/dev/null 2>&1 || true
    done

    rm -f /etc/sudoers.d/99-live-zfs-build
    modprobe zfs || true
fi

if ! command -v zpool >/dev/null 2>&1; then
    echo "FEHLER: ZFS-Bootstrap fehlgeschlagen, 'zpool' immer noch nicht verfuegbar." >&2
    exit 1
fi
echo "--- ZFS im Live-System bereit ---"

loadkeys "$CONSOLE_KEYMAP" || true

# Reste eines vorherigen, abgebrochenen Laufs aufraeumen (z.B. falsches
# Vault-Passwort beim letzten Versuch - das Skript endet dann zwar mit
# Fehler, haengt aber /mnt/boot/efi und den ZFS-Pool nicht automatisch
# wieder aus, live beobachtet: "mkfs.vfat: /dev/vdaX contains a mounted
# filesystem" beim naechsten Versuch). Alles per || true, da es beim
# allerersten Lauf nichts zum Aufraeumen gibt.
echo "--- Reste eines vorherigen Laufs aufraeumen (falls vorhanden) ---"
umount -R /mnt 2>/dev/null || true
zpool export "$ZPOOL_NAME" 2>/dev/null || true

echo "--- Partitioniere $DISK_DEVICE ---"
wipefs -af "$DISK_DEVICE"
sgdisk --zap-all "$DISK_DEVICE"
sgdisk -n1:1M:+1G -t1:EF00 -c1:EFI "$DISK_DEVICE"
sgdisk -n2:0:0    -t2:BF00 -c2:ZFS "$DISK_DEVICE"
partprobe "$DISK_DEVICE"
sleep 2

echo "--- EFI-Partition formatieren ---"
mkfs.vfat -F32 -n EFI "$EFI_PART"

echo "--- ZFS-Pool anlegen ---"
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O relatime=on \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O mountpoint=none \
    -O canmount=off \
    -O compression=zstd \
    -R /mnt \
    "$ZPOOL_NAME" "$ZFS_PART"

zfs create -o mountpoint=none "${ZPOOL_NAME}/ROOT"
zfs create -o mountpoint=/ -o canmount=noauto "$ROOT_DATASET"
zpool set bootfs="$ROOT_DATASET" "$ZPOOL_NAME"
zfs create -o mountpoint=/home "$HOME_DATASET"
zfs set "org.zfsbootmenu:commandline=${ZBM_KERNEL_CMDLINE}" "$ROOT_DATASET"

zfs mount "$ROOT_DATASET"
zfs mount -a

mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

echo "--- pacstrap: Minimalsystem (Rest kommt via Ansible/paru) ---"
# zfs-dkms/zfs-utils bewusst NICHT hier: auf dem Referenzsystem sind das
# AUR-Pakete (pacman -Qqm bestaetigt das), nicht aus offiziellen Repos
# installierbar. Werden von roles/packages via paru IM chroot gebaut
# (braucht dafuer nur linux-lts-headers+base-devel, die hier schon
# pacstrap-t werden) - das Live-System braucht sein eigenes, per
# archzfs/eoli3n geladenes zfs.ko nur fuer die zpool/zfs-Befehle oben.
pacstrap -K /mnt \
    base base-devel "$KERNEL_PKG" "$KERNEL_HEADERS_PKG" linux-firmware intel-ucode \
    networkmanager networkmanager-openvpn \
    git ansible python sudo vim efibootmgr dosfstools mtools nftables openvpn

echo "--- fstab (nur EFI-Partition, ZFS braucht keinen fstab-Eintrag) ---"
genfstab -U /mnt | grep -E '/boot/efi|^#' > /mnt/etc/fstab

echo "--- Netzwerk-Auskunft ins chroot kopieren ---"
cp -L /etc/resolv.conf /mnt/etc/resolv.conf

echo "--- /proc, /sys, /dev, efivars nach /mnt bind-mounten ---"
# Ansibles "chroot"-Connection-Plugin macht pro Modul nur ein nacktes
# chroot(2) - anders als arch-chroot bindet es NICHT automatisch /proc,
# /sys, /dev. Ohne /proc+efivars schlagen u.a. systemctl, makepkg (AUR-
# Builds) und efibootmgr im chroot fehl. Werden am Skriptende wieder
# ausgehaengt (auch bei Fehlern, siehe trap unten).
for fs in proc sys dev; do
    mount --rbind "/$fs" "/mnt/$fs"
    mount --make-rslave "/mnt/$fs"
done
if [[ -d /sys/firmware/efi/efivars ]]; then
    mount --rbind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars
fi

cleanup() {
    local exit_status=$?
    echo "--- Raeume Bind-Mounts unter /mnt auf ---"
    umount -R /mnt/dev 2>/dev/null || true
    umount -R /mnt/sys 2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true

    if [[ $exit_status -ne 0 ]]; then
        # Im Fehlerfall so gruendlich wie moeglich aufraeumen, damit der
        # naechste Versuch nicht auf einen noch "aktiven" Pool trifft
        # ("is part of active pool" bei zpool create). zfs unmount -a statt
        # rohem umount, weil das ZFS' eigene Buchfuehrung mitnimmt. Bei
        # Erfolg bewusst NICHT aushaengen - siehe Abschlussmeldung unten,
        # der Nutzer soll vor dem manuellen Reboot noch pruefen koennen.
        echo "--- Fehlerfall: EFI-Partition + ZFS-Pool sauber aushaengen ---"
        umount /mnt/boot/efi 2>/dev/null || true
        zfs unmount -a 2>/dev/null || true
        zpool export "$ZPOOL_NAME" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "--- Ansible-Repo ins Zielsystem spiegeln ---"
# Ansible selbst laeuft vom Live-System aus (nicht von innerhalb eines
# eigenen chroot) - das chroot-Connection-Plugin chrootet pro Modulaufruf
# selbst nach /mnt.
cd "$REPO_DIR"

if [[ ! -f group_vars/all/vault.yml ]]; then
    echo "FEHLER: group_vars/all/vault.yml fehlt (siehe docs/SECRETS.md)." >&2
    exit 1
fi

echo
echo "=== Stufe 0 fertig. Starte Stufe 1 (Ansible) ==="
echo
# --ask-vault-pass nur als Default, falls nicht schon eine eigene
# Vault-Passwort-Option uebergeben wurde (--ask-vault-pass und
# --vault-password-file schliessen sich gegenseitig aus - beides fest zu
# setzen bricht mit "not allowed with argument", live so gefunden).
vault_args=(--ask-vault-pass)
for arg in "$@"; do
    case "$arg" in
        --vault-password-file*|--vault-pass-file*|--ask-vault-pass|--ask-vault-password|-J)
            vault_args=()
            break
            ;;
    esac
done

# disk_device explizit ueberschreiben: group_vars/all/vars.yml enthaelt nur
# einen Default-Vorschlag (echte Hardware), das tatsaechliche Ziel wurde
# oben interaktiv ausgewaehlt.
ansible-playbook -i inventory/chroot.ini site.yml "${vault_args[@]}" \
    -e "disk_device=${DISK_DEVICE}" "$@"
status=$?

echo
if [[ $status -eq 0 ]]; then
    echo "=== Fertig. Vor dem Reboot pruefen: efibootmgr, dann 'umount -R /mnt' (falls noch nicht durch trap erledigt) und neu starten. ==="
else
    echo "=== Ansible-Lauf mit Fehlern beendet (Exit $status). /mnt bleibt gemountet fuer Fehlersuche, Bind-Mounts werden trotzdem entfernt. ==="
fi
exit "$status"
