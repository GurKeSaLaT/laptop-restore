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
    local name size model tran rm
    while IFS=$'\t' read -r name size model tran rm; do
        [[ -n "$boot_disk" && "$name" == "$boot_disk" ]] && continue
        [[ "$name" =~ ^/dev/(loop|sr|zram) ]] && continue
        names+=("$name")
        sizes+=("$size")
        local extra="${model:-unbekanntes Modell}"
        [[ -n "$tran" ]] && extra="$extra, $tran"
        [[ "$rm" == "1" ]] && extra="$extra, WECHSELDATENTRAEGER"
        labels+=("$extra")
    done < <(lsblk -dpno NAME,SIZE,MODEL,TRAN,RM --separator $'\t')

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

echo "=== laptop-restore: Stufe 0 (Disk + Base-Install) ==="
echo "Ziel-Disk:      $DISK_DEVICE"
echo "EFI-Partition:   ${DISK_DEVICE}p1"
echo "ZFS-Partition:   ${DISK_DEVICE}p2"
echo "Pool-Name:       $ZPOOL_NAME"
echo
echo "!!! Alle Daten auf $DISK_DEVICE werden UNWIDERRUFLICH geloescht !!!"
echo
read -r -p "Zum Fortfahren exakt 'YES' eingeben: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Abgebrochen."
    exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "FEHLER: Kein UEFI-Boot erkannt (/sys/firmware/efi/efivars fehlt)." >&2
    echo "ZFSBootMenu braucht UEFI. Live-Medium im UEFI-Modus booten." >&2
    exit 1
fi

if ! command -v zpool >/dev/null 2>&1; then
    echo "FEHLER: 'zpool' nicht gefunden. ZFS-Kernelmodul/Tools fehlen im Live-System." >&2
    echo "Siehe README.md fuer die empfohlene archzfs-Bootstrap-Methode." >&2
    exit 1
fi

loadkeys "$CONSOLE_KEYMAP" || true

echo "--- Partitioniere $DISK_DEVICE ---"
wipefs -af "$DISK_DEVICE"
sgdisk --zap-all "$DISK_DEVICE"
sgdisk -n1:1M:+1G -t1:EF00 -c1:EFI "$DISK_DEVICE"
sgdisk -n2:0:0    -t2:BF00 -c2:ZFS "$DISK_DEVICE"
partprobe "$DISK_DEVICE"
sleep 2

EFI_PART="${DISK_DEVICE}p1"
ZFS_PART="${DISK_DEVICE}p2"

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
    echo "--- Raeume Bind-Mounts unter /mnt auf ---"
    umount -R /mnt/dev 2>/dev/null || true
    umount -R /mnt/sys 2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true
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
# disk_device explizit ueberschreiben: group_vars/all/vars.yml enthaelt nur
# einen Default-Vorschlag (echte Hardware), das tatsaechliche Ziel wurde
# oben interaktiv ausgewaehlt.
ansible-playbook -i inventory/chroot.ini site.yml --ask-vault-pass \
    -e "disk_device=${DISK_DEVICE}" "$@"
status=$?

echo
if [[ $status -eq 0 ]]; then
    echo "=== Fertig. Vor dem Reboot pruefen: efibootmgr, dann 'umount -R /mnt' (falls noch nicht durch trap erledigt) und neu starten. ==="
else
    echo "=== Ansible-Lauf mit Fehlern beendet (Exit $status). /mnt bleibt gemountet fuer Fehlersuche, Bind-Mounts werden trotzdem entfernt. ==="
fi
exit "$status"
