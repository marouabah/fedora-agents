#!/usr/bin/env bash
#
# kvm-clone-system.sh - Clone le système hôte vers une VM KVM
# Usage: kvm-clone-system.sh [options]
#
# Crée un template VM bootable à partir du système actuel
# avec Hyprland et toutes les configurations.
#

set -euo pipefail

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; echo "[$(date +%H:%M:%S)] [INFO] $1" >> "${SCRIPT_LOG:-/tmp/kvm-clone-system-debug.log}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; echo "[$(date +%H:%M:%S)] [WARN] $1" >> "${SCRIPT_LOG:-/tmp/kvm-clone-system-debug.log}"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; echo "[$(date +%H:%M:%S)] [ERROR] $1" >> "${SCRIPT_LOG:-/tmp/kvm-clone-system-debug.log}"; }
log_step() { echo -e "${CYAN}[====]${NC} $1"; echo "[$(date +%H:%M:%S)] [STEP] $1" >> "${SCRIPT_LOG:-/tmp/kvm-clone-system-debug.log}"; }

# Configuration par défaut
VM_NAME="neutron-clone"
DISK_SIZE="60G"
MEMORY=8192
VCPUS=4
IMAGES_DIR="/var/lib/libvirt/images"
NETWORK="default"
NEW_HOSTNAME=""
NEW_USERNAME=""
LIGHT=true   # mode leger PAR DEFAUT : interface sans donnees lourdes ni secrets

# Fichiers temporaires
MOUNT_DIR=""
NBD_DEVICE=""
CLEANUP_DONE=false

# Log fichier pour debug n8n — fallback si le fichier existant appartient a
# un autre utilisateur (un residu root bloquait tout le script via set -e)
SCRIPT_LOG="/tmp/kvm-clone-system-debug.log"
if ! echo "=== kvm-clone-system.sh started at $(date) ===" > "$SCRIPT_LOG" 2>/dev/null; then
    SCRIPT_LOG="$(mktemp /tmp/kvm-clone-system-debug.XXXX.log)"
    echo "=== kvm-clone-system.sh started at $(date) ===" > "$SCRIPT_LOG"
fi

# Wrapper pour logger aussi dans le fichier
log_to_file() { echo "[$(date +%H:%M:%S)] $1" >> "$SCRIPT_LOG"; }

# Tracking MCP (optionnel — actif si TRACKING_ID est defini dans l'env)
# shellcheck source=../utils/tracking.sh
_TRACKING_HELPER="$(dirname "${BASH_SOURCE[0]}")/../utils/tracking.sh"
[[ -f "$_TRACKING_HELPER" ]] && source "$_TRACKING_HELPER" || true

usage() {
    cat << 'EOF'
Usage: sudo ./kvm-clone-system.sh [OPTIONS]

Clone le système hôte actuel vers une VM KVM bootable.
Idéal pour créer un duplicata avec interface graphique (Hyprland).

Options:
    -n, --name NAME         Nom de la VM (défaut: neutron-clone)
    -d, --disk SIZE         Taille du disque (défaut: 60G)
    -m, --memory MB         Mémoire en MB (défaut: 8192)
    -c, --cpus N            Nombre de vCPUs (défaut: 4)
    --full                  Clone COMPLET (par défaut: mode léger — interface
                            et configs sans ~/dev, modèles IA, secrets)
    --hostname NAME         Changer le hostname dans la VM
    --username NAME         Changer le username (recrée le home)
    --dry-run               Afficher ce qui serait fait sans exécuter
    -y, --yes               Ne pas demander de confirmation (mode non-interactif)
    -h, --help              Afficher cette aide

Exemples:
    sudo ./kvm-clone-system.sh
    sudo ./kvm-clone-system.sh -n dev-workstation -d 80G
    sudo ./kvm-clone-system.sh --hostname devbox --username dev

Ce qui est copié:
    - Système complet (/, /boot, /home)
    - Hyprland et toutes les configs
    - Python, pyenv, poetry, environnements
    - Dotfiles et projets ~/dev

Ce qui est exclu:
    - Caches (navigateur, DNF, pip, npm)
    - Logs, fichiers temporaires
    - node_modules, __pycache__, .venv
    - Téléchargements, Trash

Temps estimé: 15-30 minutes selon la taille du système
EOF
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en root (sudo)"
        exit 1
    fi
}

check_dependencies() {
    local deps=(qemu-img qemu-nbd rsync parted mkfs.vfat mkfs.xfs grub2-install virt-install)
    local missing=()

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dépendances manquantes: ${missing[*]}"
        log_info "Installez avec:"
        log_info "  sudo dnf install qemu-img qemu-tools rsync parted dosfstools xfsprogs grub2-efi-x64 virt-install"
        exit 1
    fi
}

check_libvirt() {
    if ! systemctl is-active --quiet libvirtd && \
       ! systemctl is-active --quiet virtqemud.socket; then
        log_error "Service libvirt non actif"
        log_info "Démarrez avec: sudo systemctl start virtqemud.socket"
        exit 1
    fi
}

check_existing_vm() {
    local base_name="$VM_NAME"
    local original_name="$VM_NAME"
    local disk_path="$IMAGES_DIR/${VM_NAME}.qcow2"

    # Vérifier si la VM existe OU si l'image disque existe (cas d'un run précédent échoué)
    local vm_exists=false
    local disk_exists=false

    virsh dominfo "$VM_NAME" &>/dev/null 2>&1 && vm_exists=true
    [[ -f "$disk_path" ]] && disk_exists=true

    # Si ni la VM ni le disque n'existent, on garde le nom tel quel
    if [[ "$vm_exists" == false && "$disk_exists" == false ]]; then
        return 0
    fi

    # La VM ou le disque existe, chercher un suffixe disponible
    if [[ "$vm_exists" == true ]]; then
        log_warn "VM '$VM_NAME' existe déjà, recherche d'un nom disponible..."
    else
        log_warn "Image disque '$disk_path' existe (run précédent échoué?), recherche d'un nom disponible..."
    fi

    # Retirer un éventuel suffixe existant (-01, -02, etc.) pour avoir le nom de base
    base_name=$(echo "$VM_NAME" | sed 's/-[0-9]\{2\}$//')

    # Chercher le prochain suffixe disponible (vérifier VM ET disque)
    for i in $(seq -w 1 99); do
        local candidate="${base_name}-${i}"
        local candidate_disk="$IMAGES_DIR/${candidate}.qcow2"

        # Le candidat est valide seulement si ni la VM ni le disque n'existent
        if ! virsh dominfo "$candidate" &>/dev/null 2>&1 && [[ ! -f "$candidate_disk" ]]; then
            VM_NAME="$candidate"
            log_info "Nouveau nom de VM: $VM_NAME"
            return 0
        fi
    done

    # Si on arrive ici, tous les suffixes sont pris (improbable)
    log_error "Impossible de trouver un nom disponible (${base_name}-01 à ${base_name}-99 tous pris)"
    exit 1
}

cleanup() {
    if [[ "$CLEANUP_DONE" == true ]]; then
        return
    fi
    CLEANUP_DONE=true

    log_step "Nettoyage..."

    # Démonter les systèmes de fichiers
    if [[ -n "${MOUNT_DIR:-}" && -d "$MOUNT_DIR" ]]; then
        umount -R "$MOUNT_DIR" 2>/dev/null || true
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi

    # Déconnecter NBD
    if [[ -n "${NBD_DEVICE:-}" ]]; then
        qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null || true
    fi

    # Décharger le module si plus utilisé
    if ! lsblk | grep -q nbd; then
        rmmod nbd 2>/dev/null || true
    fi

    # Log rsync : /tmp est un tmpfs (RAM) — un log de clone pese ~150 Mo,
    # le laisser trainer consomme de la memoire jusqu'au reboot
    rm -f "/tmp/rsync-clone-${VM_NAME}.log" 2>/dev/null || true

    # Supprimer le qcow2 si le clone a echoue (evite les residus qui saturent le disque)
    if [[ "${CLONE_SUCCESS:-false}" != "true" ]]; then
        local failed_image="$IMAGES_DIR/${VM_NAME}.qcow2"
        if [[ -f "$failed_image" ]]; then
            log_warn "Suppression image echouee: $failed_image"
            rm -f "$failed_image" 2>/dev/null || true
        fi
        tracking_error "Clone echoue — image supprimee, disque libere"
    fi
}

trap cleanup EXIT INT TERM

create_exclude_file() {
    local exclude_file="$1"

    cat > "$exclude_file" << 'EXCLUDES'
# Systèmes de fichiers virtuels
/dev/*
/proc/*
/sys/*
/run/*
/tmp/*
/var/tmp/*

# Points de montage (seront recréés vides)
/mnt/*
/media/*
/lost+found

# Caches système
/var/cache/dnf/*
/var/cache/PackageKit/*
/var/cache/man/*
/var/cache/fontconfig/*
/var/cache/ldconfig/*

# Logs (garder structure, vider contenu)
/var/log/*.log
/var/log/**/*.log
/var/log/journal/*
/var/log/audit/*
/var/log/btmp
/var/log/wtmp
/var/log/lastlog

# Caches utilisateur
/home/*/.cache/*
/home/*/.local/share/Trash/*
/home/*/Téléchargements/*
/home/*/Downloads/*

# Caches navigateurs
/home/*/.mozilla/firefox/*/cache*
/home/*/.mozilla/firefox/*/storage/*
/home/*/.config/google-chrome/*/Cache/*
/home/*/.config/chromium/*/Cache/*
/home/*/.config/BraveSoftware/*
/etc/NetworkManager/system-connections/*/Cache/*

# Caches développement
/home/*/.npm/_cacache/*
/home/*/.cache/pip/*
/home/*/.cache/pypoetry/*
/home/*/.local/share/virtualenvs/*
/home/*/.cargo/registry/cache/*
/home/*/.rustup/tmp/*

# Fichiers projet à exclure
**/node_modules
**/__pycache__
**/.venv
**/*.pyc
**/.pytest_cache
**/.mypy_cache
**/.tox
**/dist
**/build
**/*.egg-info
**/.git/objects/pack/*.pack
**/.git/objects/pack/*.idx

# Historiques shell (sensibles)
/home/*/.bash_history
/home/*/.zsh_history
/home/*/.local/share/fish/fish_history
/root/.bash_history

# Fichiers sensibles (optionnel - décommenter si voulu)
# /home/*/.ssh/id_*
# /home/*/.gnupg/*

# Swap et hibernation
/swapfile
/swap.img
*.swap

# KVM images (éviter récursion!)
/var/lib/libvirt/images/*

# Exports de VMs (archives volumineuses non necessaires dans le clone)
/home/*/vm-exports/*
/home/*/vm-exports/
/root/vm-exports/*

# IDENTITE MACHINE — TOUJOURS exclue (base, pas seulement light) :
# la VM test-vm01 a vole l'identite tailscale de l'hote au boot (meme cle
# de noeud -> elle a pris la route 100.x de l'hote sur le tailnet)
/var/lib/tailscale/*
/etc/ssh/ssh_host_*
/var/lib/dbus/machine-id

# Timeshift et backups
/timeshift/*
/backups/*

# ABRT crash reports (peuvent causer des broken pipe)
/var/spool/abrt/*

# Fichiers volumineux temporaires
*.iso
*.img
*.vmdk
*.vdi

# Partition EFI (FAT32 - sera copiée séparément sans xattrs)
/boot/efi/*
EXCLUDES

    if [[ "$LIGHT" == true ]]; then
        cat >> "$exclude_file" << 'LIGHT_EXCLUDES'

# ===== MODE LEGER (defaut) : VM "transportable" =====
# Donnees lourdes — l'interface reste, pas les projets ni les modeles
/home/*/dev/*
/home/*/.ollama/*
/home/*/.claude/projects/*
/home/*/.claude/backups/*
/home/*/.claude/downloads/*
/home/*/.claude/file-history/*
/home/*/.claude/chrome/*
/home/*/.claude/image-cache/*
/home/*/.claude/paste-cache/*
/home/*/Musique/*
/home/*/Videos/*
/home/*/vms/*
/home/*/.local/share/Steam/*
/home/*/.gradle/*
/home/*/.buildozer_cache/*
/home/*/.local/share/containers/*
/var/lib/containers/*
/var/lib/docker/*
/var/lib/containerd/*
# Modeles IA installes en systeme (ollama service) — inutilisables sans GPU
/usr/share/ollama/*

# SECRETS — une VM transportable ne doit RIEN contenir d'exploitable
/home/*/.lyra-control.env
/home/*/.config/lyra-control/*
/home/*/.claude/.credentials.json
/home/*/.ssh/id_*
/home/*/.ssh/*.pem
/home/*/.gnupg/*
/home/*/.local/share/keyrings/*
/home/*/.config/Bitwarden*
/home/*/.aws/*
/home/*/.docker/config.json
/home/*/.netrc
# Profils navigateurs = cookies + sessions actives (exploitables)
/home/*/.config/google-chrome/*
/home/*/.config/google-chrome-*/*
/home/*/.config/chromium/*
/home/*/.config/BraveSoftware/*
/etc/NetworkManager/system-connections/*
LIGHT_EXCLUDES
        log_info "Mode LEGER actif (defaut) : ~/dev, modeles IA et secrets exclus (--full pour tout cloner)"
    fi

    log_info "Fichier d'exclusions créé: $exclude_file"
}

setup_nbd() {
    tracking_progress 2 "NBD — preparation device"
    tracking_extra "phase" "NBD — preparation device"
    log_step "Configuration du module NBD..."

    # Charger le module nbd
    if ! lsmod | grep -q "^nbd"; then
        modprobe nbd max_part=16
    fi

    # Trouver un device nbd libre
    for i in {0..15}; do
        if [[ ! -e "/sys/block/nbd$i/pid" ]] || [[ ! -s "/sys/block/nbd$i/pid" ]]; then
            NBD_DEVICE="/dev/nbd$i"
            break
        fi
    done

    if [[ -z "$NBD_DEVICE" ]]; then
        log_error "Aucun device NBD disponible"
        exit 1
    fi

    log_info "Device NBD: $NBD_DEVICE"
}

create_disk_image() {
    tracking_progress 4 "Creation image disque ${DISK_SIZE}"
    log_step "Création de l'image disque ($DISK_SIZE)..."

    local disk_path="$IMAGES_DIR/${VM_NAME}.qcow2"

    if [[ -f "$disk_path" ]]; then
        log_error "L'image existe déjà: $disk_path"
        exit 1
    fi

    qemu-img create -f qcow2 "$disk_path" "$DISK_SIZE"
    log_info "Image créée: $disk_path"

    # Connecter via NBD
    qemu-nbd --connect="$NBD_DEVICE" "$disk_path"
    sleep 2

    log_info "Image connectée à $NBD_DEVICE"
}

partition_disk() {
    tracking_progress 5 "Partitionnement GPT + UEFI"
    log_step "Partitionnement du disque (GPT + UEFI)..."

    # Créer table GPT
    parted -s "$NBD_DEVICE" mklabel gpt

    # Partition EFI (512MB)
    parted -s "$NBD_DEVICE" mkpart primary fat32 1MiB 513MiB
    parted -s "$NBD_DEVICE" set 1 esp on

    # Partition boot (2GB — l'hote a 884M dans /boot : 1G saturait pendant
    # grub2-install "keylayouts.mod: Aucun espace disponible", 2 runs echoues)
    parted -s "$NBD_DEVICE" mkpart primary xfs 513MiB 2561MiB

    # Partition root (reste)
    parted -s "$NBD_DEVICE" mkpart primary xfs 2561MiB 100%

    # Recharger la table de partitions
    partprobe "$NBD_DEVICE"
    sleep 2

    log_info "Partitions créées:"
    parted -s "$NBD_DEVICE" print
}

format_partitions() {
    tracking_progress 7 "Formatage partitions (FAT32 + XFS)"
    log_step "Formatage des partitions..."

    # EFI (FAT32)
    mkfs.vfat -F 32 -n EFI "${NBD_DEVICE}p1"

    # Boot (XFS)
    mkfs.xfs -f -L boot "${NBD_DEVICE}p2"

    # Root (XFS)
    mkfs.xfs -f -L root "${NBD_DEVICE}p3"

    log_info "Formatage terminé"
}

mount_partitions() {
    tracking_progress 9 "Montage des partitions"
    log_step "Montage des partitions..."

    MOUNT_DIR=$(mktemp -d /tmp/vm-clone.XXXXXX)

    # Monter root
    mount "${NBD_DEVICE}p3" "$MOUNT_DIR"

    # Créer et monter boot
    mkdir -p "$MOUNT_DIR/boot"
    mount "${NBD_DEVICE}p2" "$MOUNT_DIR/boot"

    # Créer et monter EFI
    mkdir -p "$MOUNT_DIR/boot/efi"
    mount "${NBD_DEVICE}p1" "$MOUNT_DIR/boot/efi"

    log_info "Partitions montées sous $MOUNT_DIR"
}

_rsync_monitor() {
    local mount_dir="$1"
    local src_gb="$2"
    local last_pct=-5

    while sleep 15; do
        # df sur la partition destination : O(1), instantane
        local used_gb
        used_gb=$(LANG=C df -BG "$mount_dir" 2>/dev/null | tail -1 | awk '{gsub("G",""); print $3}')
        [[ -z "$used_gb" || "$used_gb" == "0" ]] && continue

        local pct=$(( used_gb * 100 / src_gb ))
        [[ $pct -gt 100 ]] && pct=100

        if (( pct >= last_pct + 3 )); then
            last_pct=$pct
            # rsync occupe la plage 10%-80% de la progression totale
            local track_val=$(( 10 + pct * 70 / 100 ))
            local bar=""
            local filled=$(( pct / 5 ))
            for (( i=0; i<filled; i++ )); do bar+="#"; done
            for (( i=filled; i<20; i++ )); do bar+="-"; done
            tracking_progress "$track_val" "rsync [${bar}] ${pct}% — ${used_gb}/${src_gb} GB"
            tracking_extra "phase" "rsync ${pct}% — ${used_gb}/${src_gb} GB"
        fi
    done
}

sync_system() {
    tracking_progress 10 "Rsync systeme en cours — etape la plus longue (15-30 min)"
    tracking_extra "phase" "rsync 0% — preparation"
    log_step "Synchronisation du système (peut prendre 10-20 min)..."

    local exclude_file
    exclude_file=$(mktemp)
    local rsync_log="/tmp/rsync-clone-${VM_NAME}.log"
    create_exclude_file "$exclude_file"

    # Taille source pour le moniteur de progression
    local src_gb
    src_gb=$(LANG=C df -BG / | tail -1 | awk '{gsub("G",""); print $3}')
    log_info "Taille source approximative: ${src_gb}G"
    log_info "Log détaillé: $rsync_log"

    # Lancer le moniteur de progression en arriere-plan
    _rsync_monitor "$MOUNT_DIR" "$src_gb" &
    local monitor_pid=$!

    # --one-file-system : reste sur le filesystem racine, evite de traverser
    # /boot (sda4), /mnt/*, /backups/* et tout autre point de montage
    # /boot est copie separement par le script apres le rsync principal
    local rsync_exit=0
    rsync -aAXH \
        --one-file-system \
        --info=stats1 \
        --exclude-from="$exclude_file" \
        --exclude="$MOUNT_DIR" \
        --exclude="$exclude_file" \
        --log-file="$rsync_log" \
        / "$MOUNT_DIR/" 2>&1 || rsync_exit=$?

    # Arreter le moniteur
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true

    rm -f "$exclude_file"

    # Afficher un résumé des stats rsync
    if [[ -f "$rsync_log" ]]; then
        log_info "Résumé rsync:"
        grep -E "(sent .* bytes|total size|Number of files|speedup)" "$rsync_log" | tail -3 | while read -r line; do
            echo "  $line"
        done || true
    fi

    if [[ $rsync_exit -eq 0 ]]; then
        log_info "Rsync terminé sans erreur"
    elif [[ $rsync_exit -eq 23 || $rsync_exit -eq 24 ]]; then
        log_warn "Rsync terminé avec avertissements (code $rsync_exit)"
        log_warn "Certains fichiers n'ont pas pu être copiés (fichiers actifs/verrouillés)"
    else
        log_error "Rsync a échoué avec le code $rsync_exit"
        log_error "Voir $rsync_log pour les détails"
        exit 1
    fi

    # Copier /boot separement (--one-file-system l'a exclu du rsync principal car sda4)
    if [[ -d /boot ]]; then
        log_info "Copie de /boot (partition separee sda4)..."
        rsync -aXH --exclude="efi/*" /boot/ "$MOUNT_DIR/boot/" 2>&1 || {
            log_warn "Quelques fichiers boot n'ont pas pu être copiés (normal)"
        }
    fi

    # Copier /boot/efi séparément (FAT32 ne supporte pas xattrs)
    if [[ -d /boot/efi ]]; then
        log_info "Copie de /boot/efi (sans xattrs - FAT32)..."
        rsync -a /boot/efi/ "$MOUNT_DIR/boot/efi/" 2>&1 || {
            log_warn "Quelques fichiers EFI n'ont pas pu être copiés (normal)"
        }
    fi

    # Copier /home separement s'il vit sur un autre filesystem (ex: bind
    # mount NVMe sur ce systeme) — --one-file-system l'exclut du rsync
    # principal et le clone demarrait SANS AUCUN home (regression 2026-08-14).
    local root_dev home_dev
    root_dev=$(stat -c %d / 2>/dev/null || echo 0)
    for home_dir in /home/*/; do
        [[ -d "$home_dir" ]] || continue
        home_dev=$(stat -c %d "$home_dir" 2>/dev/null || echo 0)
        [[ "$home_dev" != "$root_dev" ]] || continue
        log_info "Copie de /home (filesystem distinct detecte: ${home_dir})..."
        tracking_progress 70 "Copie du home (peut prendre plusieurs minutes)"
        local home_exclude
        home_exclude=$(mktemp)
        create_exclude_file "$home_exclude"
        # Re-ancrer les patterns /home/... a la racine du transfert (/home) et
        # garder les patterns non ancres (**/node_modules, *.iso...)
        {
            sed -n 's|^/home/|/|p' "$home_exclude"
            grep -E '^(\*\*|[^/#])' "$home_exclude" || true
        } > "${home_exclude}.home"
        rsync -aAXH --info=stats1 \
            --exclude-from="${home_exclude}.home" \
            --log-file="$rsync_log" \
            /home/ "$MOUNT_DIR/home/" 2>&1 || \
            log_warn "Copie du home terminee avec avertissements"
        rm -f "$home_exclude" "${home_exclude}.home"
        break  # tout /home est copie en une passe
    done

    mkdir -p "$MOUNT_DIR"/{dev,proc,sys,run,tmp,mnt,media}
    mkdir -p "$MOUNT_DIR/var/log"
    mkdir -p "$MOUNT_DIR/var/cache/dnf"
    chmod 1777 "$MOUNT_DIR/tmp"

    tracking_progress 80 "Rsync termine — ${src_gb} GB copies"
    tracking_extra "phase" "rsync 100% — termine"
    log_info "Synchronisation terminée"
}

configure_fstab() {
    tracking_progress 82 "Configuration fstab + UUIDs"
    log_step "Configuration de /etc/fstab..."

    # Obtenir les UUIDs
    local uuid_root=$(blkid -s UUID -o value "${NBD_DEVICE}p3")
    local uuid_boot=$(blkid -s UUID -o value "${NBD_DEVICE}p2")
    local uuid_efi=$(blkid -s UUID -o value "${NBD_DEVICE}p1")

    # Créer le nouveau fstab
    cat > "$MOUNT_DIR/etc/fstab" << EOF
# /etc/fstab - VM Clone
# Généré par kvm-clone-system.sh

# Root partition
UUID=$uuid_root    /           xfs     defaults        0 1

# Boot partition
UUID=$uuid_boot    /boot       xfs     defaults        0 2

# EFI partition
UUID=$uuid_efi     /boot/efi   vfat    umask=0077,shortname=winnt 0 2

# Swap (zram auto-configuré par systemd)
# Pas de partition swap, utilise zram-generator

# tmpfs
tmpfs              /tmp        tmpfs   defaults,noatime,mode=1777 0 0
EOF

    log_info "fstab configuré avec les nouveaux UUIDs"
    cat "$MOUNT_DIR/etc/fstab"
}

configure_hostname() {
    tracking_progress 85 "Configuration hostname"
    local target_hostname="$NEW_HOSTNAME"

    # Si pas de hostname spécifié, générer automatiquement "electron-XX"
    if [[ -z "$target_hostname" ]]; then
        # Extraire le numéro de la VM (ex: preprod-09 -> 09)
        local vm_number=$(echo "$VM_NAME" | grep -oE '[0-9]+$')
        if [[ -n "$vm_number" ]]; then
            target_hostname="electron-${vm_number}"
        else
            # Fallback: utiliser le nom de la VM
            target_hostname="electron-vm"
        fi
    fi

    log_step "Configuration du hostname: $target_hostname..."
    echo "$target_hostname" > "$MOUNT_DIR/etc/hostname"

    # Mettre à jour /etc/hosts
    local old_hostname=$(hostname)
    sed -i "s/$old_hostname/$target_hostname/g" "$MOUNT_DIR/etc/hosts"

    # S'assurer que localhost est bien configuré
    if ! grep -q "127.0.0.1.*$target_hostname" "$MOUNT_DIR/etc/hosts"; then
        sed -i "s/127.0.0.1.*/127.0.0.1   localhost $target_hostname/" "$MOUNT_DIR/etc/hosts"
    fi

    log_info "Hostname configuré: $target_hostname"

    # Adaptation Hyprland pour la VM : les moniteurs physiques (DP-1...) et le
    # GPU NVIDIA n'existent pas ici — sans ce garde-fou l'utilisateur arrive
    # sur un affichage casse. Le catch-all Virtual-1 prend le relais.
    local user_homes
    user_homes=$(ls -d "$MOUNT_DIR"/home/*/ 2>/dev/null || true)
    for uh in $user_homes; do
        local hypr_conf="$uh/.config/hypr/hyprland.conf"
        if [[ -f "$hypr_conf" ]] && ! grep -q "kvm-clone-system: adaptation VM" "$hypr_conf"; then
            cat >> "$hypr_conf" << 'HYPRVM'

# --- kvm-clone-system: adaptation VM (ajoute au clonage) ---
monitor = Virtual-1, 1920x1080@60, 0x0, 1
monitor = , preferred, auto, 1
HYPRVM
            log_info "Override Hyprland VM injecte: $hypr_conf"
        fi
    done
}

adapt_for_vm() {
    tracking_progress 87 "Adaptation VM — desactivation NVIDIA, Mesa EGL"
    log_step "Adaptation du système pour VM (GPU virtio, Mesa EGL)..."

    # 1. Désactiver NVIDIA EGL pour utiliser Mesa
    local nvidia_egl="$MOUNT_DIR/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
    if [[ -f "$nvidia_egl" ]]; then
        mv "$nvidia_egl" "${nvidia_egl}.disabled"
        log_info "NVIDIA EGL désactivé (10_nvidia.json.disabled)"
    fi

    # 2. Blacklister les modules NVIDIA (inutiles dans VM)
    cat > "$MOUNT_DIR/etc/modprobe.d/blacklist-nvidia-vm.conf" << 'EOF'
# Blacklist NVIDIA modules in VM (no physical GPU)
# Generated by kvm-clone-system.sh
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF
    log_info "Modules NVIDIA blacklistés"

    # 3. Créer une config Hyprland adaptée pour VM
    local hypr_config="$MOUNT_DIR/home/*/config/hypr/hyprland.conf"
    for config in $MOUNT_DIR/home/*/.config/hypr/hyprland.conf; do
        if [[ -f "$config" ]]; then
            log_info "Adaptation config Hyprland: $config"

            # Backup
            cp "$config" "${config}.host-backup"

            # Commenter les variables NVIDIA et les remplacer par Mesa
            sed -i '
                # Commenter les lignes NVIDIA
                s/^env = LIBVA_DRIVER_NAME,nvidia/#env = LIBVA_DRIVER_NAME,nvidia  # VM: disabled/
                s/^env = GBM_BACKEND,nvidia-drm/#env = GBM_BACKEND,nvidia-drm  # VM: disabled/
                s/^env = __GLX_VENDOR_LIBRARY_NAME,nvidia/env = __GLX_VENDOR_LIBRARY_NAME,mesa  # VM: Mesa/
                s/^env = NVD_BACKEND,direct/#env = NVD_BACKEND,direct  # VM: disabled/
                s/^env = VK_ICD_FILENAMES,.*/#env = VK_ICD_FILENAMES  # VM: disabled/
                s|^env = __EGL_VENDOR_LIBRARY_FILENAMES,.*/10_nvidia.json|env = __EGL_VENDOR_LIBRARY_FILENAMES,/usr/share/glvnd/egl_vendor.d/50_mesa.json  # VM: Mesa|
                s/^env = WLR_NO_HARDWARE_CURSORS,1/#env = WLR_NO_HARDWARE_CURSORS,1  # VM: disabled/
            ' "$config"
        fi
    done

    # 4. Ajouter les utilisateurs aux groupes video/render
    for user_home in "$MOUNT_DIR"/home/*; do
        if [[ -d "$user_home" ]]; then
            local username=$(basename "$user_home")
            # Vérifier que c'est un vrai utilisateur (existe dans passwd)
            if grep -q "^${username}:" "$MOUNT_DIR/etc/passwd"; then
                # Ajouter aux groupes video et render dans le fichier group
                for group in video render; do
                    if grep -q "^${group}:" "$MOUNT_DIR/etc/group"; then
                        # Vérifier si l'utilisateur n'est pas déjà dans le groupe
                        if ! grep "^${group}:" "$MOUNT_DIR/etc/group" | grep -q "$username"; then
                            sed -i "/^${group}:/ s/$/,${username}/" "$MOUNT_DIR/etc/group"
                            # Nettoyer les virgules doubles ou trailing
                            sed -i "/^${group}:/ s/:,/:/; s/,,/,/g; s/,$//" "$MOUNT_DIR/etc/group"
                            log_info "Utilisateur $username ajouté au groupe $group"
                        fi
                    fi
                done
            fi
        fi
    done

    log_info "Système adapté pour VM avec GPU virtio"
}

setup_bootloader() {
    tracking_progress 91 "Configuration GRUB + regeneration initramfs (chroot)"
    log_step "Configuration du bootloader GRUB..."

    # Monter les systèmes virtuels pour chroot
    mount --bind /dev "$MOUNT_DIR/dev"
    mount --bind /dev/pts "$MOUNT_DIR/dev/pts"
    mount -t proc proc "$MOUNT_DIR/proc"
    mount -t sysfs sysfs "$MOUNT_DIR/sys"
    mount --bind /sys/firmware/efi/efivars "$MOUNT_DIR/sys/firmware/efi/efivars" 2>/dev/null || true
    mount -t tmpfs tmpfs "$MOUNT_DIR/run"

    # Gérer resolv.conf (souvent un symlink sur Fedora moderne)
    local resolv_backup=""
    if [[ -L "$MOUNT_DIR/etc/resolv.conf" ]]; then
        # Sauvegarder le target du symlink
        resolv_backup=$(readlink "$MOUNT_DIR/etc/resolv.conf")
        rm -f "$MOUNT_DIR/etc/resolv.conf"
    fi
    # Créer un fichier resolv.conf temporaire pour le chroot
    cat /etc/resolv.conf > "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || \
        echo "nameserver 8.8.8.8" > "$MOUNT_DIR/etc/resolv.conf"

    # Copier les modules GRUB EFI s'ils manquent dans le clone
    if [[ -d /usr/lib/grub/x86_64-efi ]] && [[ ! -f "$MOUNT_DIR/usr/lib/grub/x86_64-efi/kernel.img" ]]; then
        log_info "Copie des modules GRUB EFI vers le clone..."
        mkdir -p "$MOUNT_DIR/usr/lib/grub"
        cp -a /usr/lib/grub/x86_64-efi "$MOUNT_DIR/usr/lib/grub/"
    fi

    # Script à exécuter dans le chroot
    cat > "$MOUNT_DIR/tmp/setup-grub.sh" << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

echo "==> Vérification des modules GRUB EFI..."

# Installer grub2-efi-x64-modules si manquant
if [[ ! -d /usr/lib/grub/x86_64-efi ]] || [[ ! -f /usr/lib/grub/x86_64-efi/modinfo.sh ]]; then
    echo "==> Installation des modules GRUB EFI..."
    dnf install -y grub2-efi-x64-modules shim-x64 2>/dev/null || {
        echo "WARN: Impossible d'installer les modules GRUB, utilisation de la config existante"
    }
fi

# Réinstaller GRUB pour UEFI (si modules disponibles)
if [[ -f /usr/lib/grub/x86_64-efi/modinfo.sh ]]; then
    echo "==> Installation de GRUB EFI..."
    # --force car Secure Boot n'est pas supporté par grub2-install (VM sans Secure Boot)
    grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fedora --recheck --force
else
    echo "==> Modules GRUB non disponibles, copie des fichiers EFI existants..."
    # S'assurer que les fichiers EFI de base existent
    mkdir -p /boot/efi/EFI/fedora
    # Les fichiers ont été copiés par rsync, on vérifie juste qu'ils sont là
    if [[ -f /boot/efi/EFI/fedora/shimx64.efi ]]; then
        echo "    Fichiers EFI existants trouvés"
    fi
fi

# Corriger les entrees BLS copiees depuis le host : supprimer rd.lvm.lv
# (le host utilise LVM mais la VM a un layout de partitions directes)
echo "==> Correction des entrees BLS (suppression rd.lvm.lv du host)..."
ROOT_UUID=$(grep " / " /etc/fstab | grep -v "^#" | awk '{print $1}' | sed 's/UUID=//')
for conf in /boot/loader/entries/*.conf; do
    [[ -f "$conf" ]] || continue
    CHANGED=false
    # Supprimer rd.lvm.lv=<vg>/<lv>
    if grep -q "rd\.lvm\.lv=" "$conf"; then
        sed -i 's/rd\.lvm\.lv=[^ ]*//g; s/  */ /g' "$conf"
        CHANGED=true
    fi
    # Remplacer root=/dev/mapper/<vg>-<lv> par root=UUID= correct
    if [[ -n "$ROOT_UUID" ]] && grep -q "root=/dev/mapper/" "$conf"; then
        sed -i "s|root=/dev/mapper/[a-zA-Z0-9_-]*|root=UUID=$ROOT_UUID|g" "$conf"
        CHANGED=true
    fi
    [[ "$CHANGED" == true ]] && echo "    Corrige: $(basename "$conf")"
done

# Nettoyer GRUB_CMDLINE_LINUX dans /etc/default/grub :
# supprimer les params specifiques au host (LVM, NVIDIA, crashkernel)
# pour eviter que grub2-mkconfig les reinjecte dans le grubenv
echo "==> Nettoyage /etc/default/grub (suppression params host)..."
# PAS d'espace requis devant les params : rd.lvm.lv est souvent le PREMIER
# de GRUB_CMDLINE_LINUX="rd.lvm.lv=..." -> l'ancien pattern " rd.lvm" le
# ratait et grub2-mkconfig le reinjectait dans les entrees BLS (4e run KO)
sed -i \
    -e 's/rd\.lvm\.lv=[^ "]*//g' \
    -e 's/rd\.driver\.blacklist=[^ "]*//g' \
    -e 's/modprobe\.blacklist=[^ "]*//g' \
    -e 's/nvidia[^ "]*//g' \
    -e 's/crashkernel=[^ "]*//g' \
    -e 's/  */ /g' -e 's/=" /="/g' -e 's/ "$/"/' \
    /etc/default/grub
echo "==> GRUB_CMDLINE_LINUX apres nettoyage: $(grep GRUB_CMDLINE_LINUX /etc/default/grub | head -1)"

# Desactiver os-prober : evite d'ajouter dans grub.cfg les entrees du host
# (os-prober detecterait les LVMs du host via /dev bind-monte)
sed -i '/^GRUB_DISABLE_OS_PROBER/d' /etc/default/grub
echo "GRUB_DISABLE_OS_PROBER=true" >> /etc/default/grub
echo "==> os-prober desactive (GRUB_DISABLE_OS_PROBER=true)"

# Regénérer la configuration GRUB (met à jour les UUIDs)
echo "==> Génération de grub.cfg..."
grub2-mkconfig -o /boot/grub2/grub.cfg

# grubenv : sur certaines versions BLS, les options viennent de $kernelopts
# (grubenv) et non des fichiers .conf — purger toute reference LVM du host
if grub2-editenv /boot/grub2/grubenv list 2>/dev/null | grep -qE "rd\.lvm\.lv|/dev/mapper/"; then
    echo "==> Purge kernelopts (grubenv) des references LVM du host..."
    grub2-editenv /boot/grub2/grubenv set kernelopts="root=UUID=$ROOT_UUID ro rhgb quiet"
fi

# Initramfs : TOUJOURS regenerer en generique (--no-hostonly).
# L'initramfs hostonly copie de l'hote embarque rd.lvm.lv=<vg>/root dans son
# cmdline.d interne -> "Warning: /dev/<vg>/root does not exist" + emergency
# mode meme avec root=UUID correct (3e run echoue ici). /boot fait 2G: ca passe.
KERNEL_VERSION=$(ls /lib/modules/ | sort -V | tail -1)
if [[ -n "$KERNEL_VERSION" ]]; then
    echo "==> Regeneration initramfs generique pour $KERNEL_VERSION (2-4 min)..."
    dracut --force --no-hostonly "/boot/initramfs-${KERNEL_VERSION}.img" "${KERNEL_VERSION}" || \
        echo "WARN: dracut echoue — initramfs hote conserve (bootera probablement en emergency)"
else
    echo "WARN: Aucun kernel trouve dans /lib/modules/"
fi

# S'assurer que les services essentiels sont actifs
echo "==> Activation des services..."
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable sddm 2>/dev/null || true  # Pour Hyprland

echo "==> Configuration boot terminée"
CHROOT_SCRIPT

    chmod +x "$MOUNT_DIR/tmp/setup-grub.sh"

    # Exécuter dans le chroot
    chroot "$MOUNT_DIR" /tmp/setup-grub.sh

    rm -f "$MOUNT_DIR/tmp/setup-grub.sh"

    # Restaurer le symlink resolv.conf si nécessaire
    if [[ -n "$resolv_backup" ]]; then
        rm -f "$MOUNT_DIR/etc/resolv.conf"
        ln -s "$resolv_backup" "$MOUNT_DIR/etc/resolv.conf"
        log_info "Symlink resolv.conf restauré: $resolv_backup"
    fi

    # Démonter les systèmes virtuels
    umount "$MOUNT_DIR/sys/firmware/efi/efivars" 2>/dev/null || true
    umount "$MOUNT_DIR/run"
    umount "$MOUNT_DIR/sys"
    umount "$MOUNT_DIR/proc"
    umount "$MOUNT_DIR/dev/pts"
    umount "$MOUNT_DIR/dev"

    log_info "Bootloader configuré"
}

create_vm() {
    tracking_progress 96 "Creation VM libvirt + enregistrement"
    log_step "Création de la VM..."

    local disk_path="$IMAGES_DIR/${VM_NAME}.qcow2"

    # Démonter proprement avant création VM
    umount -R "$MOUNT_DIR" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null || true
    sleep 2

    # Créer la VM avec virt-install (Secure Boot désactivé pour compatibilité)
    virt-install \
        --name "$VM_NAME" \
        --memory "$MEMORY" \
        --vcpus "$VCPUS" \
        --disk "path=$disk_path,format=qcow2" \
        --os-variant "fedora-unknown" \
        --network network="$NETWORK" \
        --graphics spice,listen=0.0.0.0 \
        --video virtio \
        --channel spicevmc \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no \
        --noautoconsole \
        --import

    log_info "VM créée: $VM_NAME"
    log_info "Secure Boot désactivé pour éviter les erreurs de signature"
}

show_summary() {
    local disk_path="$IMAGES_DIR/${VM_NAME}.qcow2"
    local disk_size_actual=$(du -h "$disk_path" 2>/dev/null | cut -f1)

    echo ""
    echo "============================================"
    echo -e "${GREEN}  Clone Système Créé!${NC}"
    echo "============================================"
    echo ""
    echo "VM:           $VM_NAME"
    echo "Disque:       $disk_path"
    echo "Taille:       $disk_size_actual (alloué) / $DISK_SIZE (max)"
    echo "Mémoire:      ${MEMORY}MB"
    echo "vCPUs:        $VCPUS"
    echo ""
    echo "Credentials:  Identiques au système source"
    echo "              (votre user actuel + mot de passe)"
    echo ""
    echo "Commandes:"
    echo "  virt-viewer $VM_NAME          # Ouvrir l'interface graphique"
    echo "  virsh start $VM_NAME          # Démarrer"
    echo "  virsh shutdown $VM_NAME       # Arrêter"
    echo "  virsh console $VM_NAME        # Console texte"
    echo ""
    echo "La VM devrait booter directement sur Hyprland."
    echo "Utilisez virt-viewer pour l'interface graphique SPICE."
    echo ""

    # Sortie JSON pour parsing automatique (MCP/n8n)
    echo "###JSON_OUTPUT###"
    echo "{\"vm_name\":\"${VM_NAME}\",\"disk_path\":\"${disk_path}\",\"disk_size\":\"${DISK_SIZE}\",\"memory\":${MEMORY},\"cpus\":${VCPUS}}"
}

# Variables pour parsing
DRY_RUN=false
SKIP_CONFIRM=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                VM_NAME="$2"
                shift 2
                ;;
            -d|--disk)
                DISK_SIZE="$2"
                shift 2
                ;;
            -m|--memory)
                MEMORY="$2"
                shift 2
                ;;
            -c|--cpus)
                VCPUS="$2"
                shift 2
                ;;
            --full)
                LIGHT=false
                shift
                ;;
            --hostname)
                NEW_HOSTNAME="$2"
                shift 2
                ;;
            --username)
                NEW_USERNAME="$2"
                log_warn "Changement de username non implémenté pour l'instant"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --tracking-id)
                # Session tracking existante (creee par Lyra) : le script y
                # reporte sa progression au lieu d'en creer une nouvelle.
                # sudo env_reset supprime les variables -> flag CLI obligatoire.
                if [[ "$2" =~ ^[0-9a-f-]{4,64}$ ]]; then
                    TRACKING_ID="$2"
                    export TRACKING_ID
                else
                    log_warn "tracking-id invalide, ignore: $2"
                fi
                shift 2
                ;;
            -y|--yes)
                SKIP_CONFIRM=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Option inconnue: $1"
                usage
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    echo "============================================"
    echo "  Clone Système vers VM KVM"
    echo "============================================"
    echo ""
    echo "VM:           $VM_NAME"
    echo "Disque:       $DISK_SIZE"
    echo "Mémoire:      ${MEMORY}MB"
    echo "vCPUs:        $VCPUS"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Mode dry-run - Aucune action effectuée"
        exit 0
    fi

    # Creer une session de tracking dediee si aucune n'est fournie via env
    if [[ -z "${TRACKING_ID:-}" ]]; then
        tracking_init "Clone VM: ${VM_NAME} (${DISK_SIZE})" "machine" 100 " %"
        log_info "Tracking session: ${TRACKING_ID:-non disponible}"
    fi
    tracking_extra "operation" "vm_clone_system"
    tracking_extra "target" "$VM_NAME"
    tracking_progress 1 "Demarrage clone — verification pre-requis"

    local start_time=$(date +%s)

    check_root
    check_dependencies
    check_libvirt
    check_existing_vm

    log_warn "Cette opération va cloner votre système complet."
    log_warn "Assurez-vous d'avoir assez d'espace disque."
    echo ""
    if [[ "$SKIP_CONFIRM" != true ]]; then
        read -p "Continuer? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Annulé"
            exit 0
        fi
    else
        log_info "Mode non-interactif (--yes), confirmation automatique"
    fi

    setup_nbd
    create_disk_image
    partition_disk
    format_partitions
    mount_partitions
    sync_system
    configure_fstab
    configure_hostname
    adapt_for_vm
    setup_bootloader
    create_vm

    local end_time=$(date +%s)
    local duration=$(( (end_time - start_time) / 60 ))

    show_summary
    CLONE_SUCCESS=true
    tracking_done "Clone termine en ${duration} min — VM: ${VM_NAME}"
    log_info "Durée totale: ${duration} minutes"
}

main "$@"
