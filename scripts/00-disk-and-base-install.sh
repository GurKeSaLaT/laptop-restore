#!/usr/bin/env bash
# Stufe 0: Partitionierung, ZFS-Pool, pacstrap, Uebergabe an Ansible (Stufe 1).
#
# ACHTUNG: Dieses Skript loescht die Zielplatte komplett. Vorher lesen,
# nicht blind ausfuehren. Gedacht zum Starten aus einer Arch-Live-Umgebung
# mit geladenem zfs-Kernelmodul (siehe README.md, Abschnitt "Warum keine
# reine Alpine-Live-Umgebung?").
#
# Merkt sich in /root/.laptop-restore-state, ob Partitionierung/ZFS-Pool/
# pacstrap (Stufe 0) schon fertig sind - ein erneuter Aufruf (z.B. nach
# einem fehlgeschlagenen Ansible-Lauf) ueberspringt diese langsamen,
# destruktiven Schritte dann und haengt den vorhandenen Pool nur wieder
# ein. Fuer einen komplett frischen Start trotzdem: --reset.
#
# Aufruf: sudo ./scripts/00-disk-and-base-install.sh [--reset] [-f <vault-pass-datei>] [ansible-playbook-Optionen...]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/lib-vars.sh"

if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausfuehren (Live-Umgebung: meist ohnehin root)." >&2
    exit 1
fi

STATE_FILE="/root/.laptop-restore-state"

# --reset und -f (Kurzform fuer ansible-playbooks "--vault-password-file")
# herausfiltern/uebersetzen, bevor der Rest von "$@" spaeter an
# ansible-playbook durchgereicht wird. "-f" braucht ein Wertargument (der
# Pfad) - dafuer statt "for arg in "$@"" eine while/shift-Schleife ueber
# die Positionsparameter, sonst laesst sich das Konsumieren des zweiten
# Tokens nicht sauber abbilden.
#
# WICHTIG: "-f" bedeutet bei ansible-playbook selbst etwas anderes
# (--forks) - deshalb hier explizit in die lange Form uebersetzen statt
# einfach durchzureichen, sonst wuerde ansible-playbook es falsch
# interpretieren.
reset_requested=0
remaining_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset)
            reset_requested=1
            shift
            ;;
        -f)
            if [[ $# -lt 2 ]]; then
                echo "FEHLER: -f braucht einen Pfad zur Vault-Passwort-Datei." >&2
                exit 1
            fi
            remaining_args+=("--vault-password-file" "$2")
            shift 2
            ;;
        *)
            remaining_args+=("$1")
            shift
            ;;
    esac
done
set -- "${remaining_args[@]}"

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

# Hostid im Live-System auf denselben Wert setzen, den roles/zfsbootmenu
# spaeter fuer das installierte Zielsystem setzt (spl_hostid aus
# ZBM_KERNEL_CMDLINE) - MUSS vor "zpool create"/"zpool import" passieren.
# ZFS stempelt beim Erstellen/Importieren eines Pools den aktuellen Hostid
# als "zuletzt importiert von" hinein. Ohne das hier faellt das Live-System
# auf den Default (0) zurueck, was spaeter vom fest gesetzten Hostid des
# installierten Systems abweicht - beim ersten echten Boot verweigert der
# zfs-mkinitcpio-Hook dann den Import ("pool was previously in use from
# another system ... hostid=0"), ohne "-f" (das der Hook nicht automatisch
# setzt) folgt ein Kernel Panic. Live so beobachtet und reproduziert.
if [[ "$ZBM_KERNEL_CMDLINE" =~ spl_hostid=0x([0-9a-fA-F]+) ]]; then
    zgenhostid -f "${BASH_REMATCH[1]}"
    echo "--- Live-System-Hostid auf ${BASH_REMATCH[1]} gesetzt (konsistent mit dem Zielsystem) ---"
else
    echo "FEHLER: Konnte spl_hostid nicht aus zbm_kernel_cmdline extrahieren." >&2
    exit 1
fi

loadkeys "$CONSOLE_KEYMAP" || true

# --- Resume-Logik: schon abgeschlossene Stufe 0 aus vorherigem Lauf? ---
resume=0
if [[ $reset_requested -eq 1 ]]; then
    echo "--- --reset: vorherigen Fortschritt verwerfen, komplett neu anfangen ---"
    rm -f "$STATE_FILE"
elif [[ -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    if [[ "${STAGE0_DONE:-0}" == "1" && -n "${DISK_DEVICE:-}" ]]; then
        echo "--- Vorherige Stufe 0 gefunden (Ziel-Disk: $DISK_DEVICE) - Partitionierung/pacstrap werden uebersprungen. ---"
        echo "--- Fuer einen kompletten Neustart: $0 --reset ---"
        resume=1
    fi
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

if [[ $resume -eq 0 ]]; then
    select_disk
fi

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

stage0_done=0
cleanup() {
    local exit_status=$?
    echo "--- Raeume Bind-Mounts unter /mnt auf ---"
    umount -R /mnt/dev 2>/dev/null || true
    umount -R /mnt/sys 2>/dev/null || true
    umount -R /mnt/proc 2>/dev/null || true

    if [[ $exit_status -ne 0 && $stage0_done -eq 0 ]]; then
        # Nur aufraeumen, wenn STUFE 0 SELBST fehlgeschlagen ist (Marker
        # wurde noch nicht geschrieben) - damit der naechste Versuch nicht
        # auf einen noch "aktiven" Pool trifft ("is part of active pool"
        # bei zpool create). Ist Stufe 0 dagegen fertig und nur Ansible
        # (Stufe 1) ist gescheitert, bewusst NICHT aushaengen/exportieren -
        # genau das soll der naechste Aufruf ja wiederverwenden koennen.
        echo "--- Stufe 0 fehlgeschlagen: EFI + ZFS-Pool sauber aushaengen ---"
        umount /mnt/boot/efi 2>/dev/null || true
        zfs unmount -a 2>/dev/null || true
        zpool export "$ZPOOL_NAME" 2>/dev/null || true
        rm -f "$STATE_FILE"
    fi
}
trap cleanup EXIT

if [[ $resume -eq 1 ]]; then
    echo "--- Vorhandenen Pool wieder einhaengen ---"
    # "-N": zpool import mountet sonst von sich aus JEDES Dataset mit
    # canmount=on automatisch WAEHREND des Imports - noch bevor die
    # naechste Zeile unten $ROOT_DATASET (bewusst canmount=noauto, genau
    # damit "zpool import" es NICHT automatisch mountet) explizit mountet.
    # $HOME_DATASET hat canmount=on (Default, nie ueberschrieben) und
    # wurde dadurch live so gemountet, WAEHREND /mnt noch ein simples
    # Live-System-Verzeichnis war (Root ja erst danach gemountet) - haengt
    # sich dann als GESCHWISTER- statt KIND-Mount von Root im Kernel-
    # Mount-Baum auf, unsichtbar/unerreichbar von einem chroot(/mnt) aus.
    # Root-Ursache des seit Tagen verfolgten "/home"-Mount-Problems, per
    # /proc/self/mountinfo (Parent-Mount-IDs verglichen) verifiziert.
    # "-N" unterbindet das automatische Mounten komplett - danach
    # bestimmen ausschliesslich die beiden folgenden Zeilen die
    # Mount-Reihenfolge (Root zuerst, Home per "zfs mount -a" danach).
    if ! zpool list -H "$ZPOOL_NAME" >/dev/null 2>&1; then
        zpool import -f -N -R /mnt "$ZPOOL_NAME"
    fi
    if [[ "$(zfs get -H -o value mounted "$ROOT_DATASET" 2>/dev/null)" != "yes" ]]; then
        zfs mount "$ROOT_DATASET"
    fi
    zfs mount -a
    mountpoint -q /mnt/boot/efi || mount "$EFI_PART" /mnt/boot/efi
else
    # Reste eines vorherigen, NICHT erfolgreich abgeschlossenen Laufs
    # aufraeumen (z.B. Skript-Abbruch mitten in der Partitionierung).
    # Alles per || true, da es beim allerersten Lauf nichts zum Aufraeumen
    # gibt.
    echo "--- Reste eines vorherigen, unfertigen Laufs aufraeumen (falls vorhanden) ---"
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
    # CPU-Microcode (intel-ucode/amd-ucode) ebenfalls bewusst NICHT hier fest
    # eingetragen - roles/hardware erkennt den tatsaechlichen CPU-Hersteller
    # per /proc/cpuinfo (via /mnt/proc bind-mount unten real sichtbar) und
    # roles/packages installiert das passende Paket. Macht dieses Skript
    # unabhaengig von der konkreten Zielhardware.
    pacstrap -K /mnt \
        base base-devel "$KERNEL_PKG" "$KERNEL_HEADERS_PKG" linux-firmware \
        networkmanager networkmanager-openvpn \
        git ansible python sudo vim efibootmgr dosfstools mtools nftables openvpn

    echo "--- fstab (nur EFI-Partition, ZFS braucht keinen fstab-Eintrag) ---"
    genfstab -U /mnt | grep -E '/boot/efi|^#' > /mnt/etc/fstab

    echo "--- Netzwerk-Auskunft ins chroot kopieren ---"
    cp -L /etc/resolv.conf /mnt/etc/resolv.conf
fi

echo "--- /proc, /sys, /dev, efivars nach /mnt bind-mounten ---"
# Ansibles "chroot"-Connection-Plugin macht pro Modul nur ein nacktes
# chroot(2) - anders als arch-chroot bindet es NICHT automatisch /proc,
# /sys, /dev. Ohne /proc+efivars schlagen u.a. systemctl, makepkg (AUR-
# Builds) und efibootmgr im chroot fehl. Werden am Skriptende wieder
# ausgehaengt (siehe trap oben) - deshalb bei jedem Aufruf (auch resume)
# neu setzen.
for fs in proc sys dev; do
    mount --rbind "/$fs" "/mnt/$fs"
    mount --make-rslave "/mnt/$fs"
done
if [[ -d /sys/firmware/efi/efivars ]]; then
    mount --rbind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars
fi

# /mnt/home MUSS an dieser Stelle korrekt ALS KIND-Mount von /mnt im
# Kernel-Mount-Baum haengen, nicht nur irgendwie am Pfad /mnt/home
# erreichbar sein - sonst landet der komplette Home-Ordner des
# Zielsystems (SSH-Key, Dotfiles, Configs) unbemerkt auf dem Root-Dataset
# (live so erlebt). Endgueltige Root-Ursache (per /proc/self/mountinfo
# verifiziert): "zfs mount" fuer HOME_DATASET lief zu einem Zeitpunkt, an
# dem /mnt (ROOT_DATASET) noch NICHT dort gemountet war - der Home-Mount
# haengt sich dann an den PFAD /mnt, wie er zu dem Zeitpunkt existierte
# (ein simples Verzeichnis auf dem Live-System selbst), nicht an den
# spaeter dort gemounteten Root-Dataset-Mount. Linux haengt bestehende
# Unter-Mounts NICHT automatisch um, wenn spaeter etwas Neues auf ihren
# Eltern-Pfad gemountet wird - der Home-Mount bleibt als GESCHWISTER-
# statt KIND-Mount des Root-Datasets haengen, unterhalb des jetzt
# verdeckten alten Pfads. Ergebnis: vom Live-System aus ganz normal unter
# /mnt/home erreichbar (deshalb taeuschend unauffaellig), aber von
# INNERHALB eines chroot(/mnt) aus (wie Ansibles "chroot"-Connection-
# Plugin es macht) komplett unsichtbar - "mountpoint"/"findmnt"/simple
# Verzeichnis-Listings zeigen dort nichts. Kann durch mehrfache
# zpool-import/export-Zyklen ueber mehrere Testlaeufe/VM-Neustarts
# entstehen (z.B. Resume-Pfad, bei dem Root bereits als gemountet gilt
# und "zfs mount ROOT_DATASET" uebersprungen wird, waehrend Home aus
# irgendeinem fruehen Zustand heraus schon existierte).
#
# Fix nur bei Bedarf anwenden, nicht unbedingt: ein bereits korrekt
# verschachtelter Home-Mount (der Normalfall - der frische Installationspfad
# oben mountet Root vor Home schon richtig) darf NICHT anlasslos aus- und
# wieder eingehaengt werden - live erlebt, dass genau das selbst einen
# vorher gesunden Mount kaputtmachen kann (das erzwungene Aushaengen
# schlaegt aus einem voellig anderen, harmlosen Grund fehl - z.B. kurz
# nach pacstrap kurzzeitig "busy" -, das anschliessende Pflicht-Neu-Mounten
# bricht dann mit "already mounted" ab, obwohl vorher alles in Ordnung war).
#
# Deshalb per /proc/self/mountinfo (Mount-ID von /mnt vs. Parent-Mount-ID
# von /mnt/home) EXPLIZIT pruefen, ob Home wirklich korrekt unter Root
# haengt, bevor ueberhaupt etwas angefasst wird. "mountpoint" eignet sich
# dafuer NICHT: ZFS vergibt Datasets aus demselben Pool teils dieselbe
# Geraetenummer (st_dev) wie ihr Eltern-Dataset - "mountpoint"s klassischer
# st_dev-Vergleich liefert dafuer live nachweislich falsche Ergebnisse.
_root_mnt_id() { awk '$5=="/mnt"{print $1; exit}' /proc/self/mountinfo; }
_home_parent_id() { awk '$5=="/mnt/home"{print $2; exit}' /proc/self/mountinfo; }

if [[ "$(_home_parent_id)" != "$(_root_mnt_id)" ]]; then
    echo "--- WARNUNG: /mnt/home haengt nicht korrekt unter /mnt im Mount-Baum - repariere ---" >&2
    zfs list -o name,mounted,mountpoint "$ZPOOL_NAME" "$ROOT_DATASET" "$HOME_DATASET" >&2 || true
    grep -E ' /mnt(/| )' /proc/self/mountinfo >&2 || true
    mountpoint -q /mnt || zfs mount "$ROOT_DATASET"
    zfs unmount -f "$HOME_DATASET" 2>/dev/null || true
    zfs mount "$HOME_DATASET"
    if [[ "$(_home_parent_id)" != "$(_root_mnt_id)" ]]; then
        echo "FEHLER: /mnt/home haengt nach dem Neu-Mount immer noch nicht korrekt im Mount-Baum." >&2
        exit 1
    fi
    echo "--- /mnt/home korrekt nachgemountet ---"
fi

# Ab hier gilt Stufe 0 als abgeschlossen - Marker schreiben, damit ein
# fehlgeschlagener Ansible-Lauf (Stufe 1) beim naechsten Aufruf direkt
# hier fortsetzen kann, statt wieder zu partitionieren/pacstrap-en.
cat > "$STATE_FILE" <<EOF
DISK_DEVICE=$DISK_DEVICE
STAGE0_DONE=1
EOF
stage0_done=1

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

# -v als Default, falls keine eigene Verbositaet uebergeben wurde - zeigt
# u.a. volle stdout/stderr abgeschlossener Tasks. WICHTIG: das macht
# einzelne lange Shell-/Command-Tasks (paru-Build, ./setup install, ...)
# trotzdem nicht live mitlesbar - ansible.builtin.command/shell puffern
# die Ausgabe des Kindprozesses grundsaetzlich komplett und zeigen sie erst
# nach dessen Ende, unabhaengig von der Verbositaet. Um bei einem lange
# laufenden Task zu pruefen, ob er haengt oder nur dauert: in einer
# zweiten SSH-Session z.B. "arch-chroot /mnt top" oder
# "arch-chroot /mnt ps aux --sort=-%cpu | head" - laufende CPU-Last heisst
# "arbeitet noch", keine Last ueber laengere Zeit heisst "haengt".
verbosity_args=(-v)
for arg in "$@"; do
    case "$arg" in
        -v|-vv|-vvv|-vvvv|-vvvvv|-vvvvvv|--verbose)
            verbosity_args=()
            break
            ;;
    esac
done

# Ausgabe zusaetzlich in eine Datei spiegeln (per tee, weiterhin live im
# Terminal sichtbar) - damit sich der Lauf aus einer ZWEITEN SSH-Session
# per "tail -f" mitlesen laesst, unabhaengig davon ob/wann die aktuelle
# Session abbricht (das ansible-playbook laeuft selbst als Hintergrund-
# Prozess weiter, live so beobachtet - nur die Sicht darauf ging mit der
# Session verloren). Ueberschreibt bei jedem Aufruf neu (nicht -a), da ein
# neuer Aufruf ohnehin i.d.R. an derselben Stelle fortsetzt (Resume).
ANSIBLE_LOG=/root/laptop-restore-ansible.log
echo "--- Ansible-Ausgabe zusaetzlich nach $ANSIBLE_LOG gespiegelt (2. SSH-Session: tail -f $ANSIBLE_LOG) ---"

# disk_device explizit ueberschreiben: group_vars/all/vars.yml enthaelt nur
# einen Default-Vorschlag (echte Hardware), das tatsaechliche Ziel wurde
# oben interaktiv ausgewaehlt (oder aus dem Marker uebernommen).
#
# set +e/-e um den Aufruf herum: unter set -e wuerde ein fehlschlagender
# ansible-playbook-Lauf das Skript SOFORT an dieser Stelle beenden (der
# Trap greift zwar noch, aber "status=$?" und die Erfolg/Fehler-Meldung
# darunter wurden dadurch nie erreicht - ein bestehender Bug, hier
# mitgefixt). PIPESTATUS[0] statt $? direkt, weil $? nach einer Pipe sonst
# den Exitcode von "tee" liefern wuerde, nicht von ansible-playbook.
set +e
ansible-playbook -i inventory/chroot.ini site.yml "${vault_args[@]}" "${verbosity_args[@]}" \
    -e "disk_device=${DISK_DEVICE}" "$@" 2>&1 | tee "$ANSIBLE_LOG"
status=${PIPESTATUS[0]}
set -e

echo
if [[ $status -eq 0 ]]; then
    echo "=== Fertig. Vor dem Reboot pruefen: efibootmgr, dann 'umount -R /mnt' und neu starten. ==="
    rm -f "$STATE_FILE"
else
    echo "=== Ansible-Lauf mit Fehlern beendet (Exit $status). /mnt bleibt gemountet/importiert -"
    echo "    einfach nochmal aufrufen, Stufe 0 (Partitionierung/pacstrap) wird dann uebersprungen."
    echo "    Fuer einen kompletten Neustart stattdessen: $0 --reset ==="
fi
exit "$status"
