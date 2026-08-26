#!/usr/bin/env bash
#
# kvm-clone.sh - Clonage rapide de VMs KVM/Libvirt
# Usage: kvm-clone.sh <source-vm> <new-vm-name> [options]
#

set -euo pipefail

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Configuration
DEFAULT_NETWORK="default"

# Déterminer si sudo est nécessaire
SUDO=""
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
fi

# Commande virsh avec sudo si nécessaire
VIRSH="virsh"
QEMU_IMG="qemu-img"

# Répertoire des images KVM
KVM_IMAGES_DIR="${KVM_IMAGES_DIR:-/var/lib/libvirt/images}"

setup_sudo() {
    # Si on n'est pas root, on doit utiliser sudo pour libvirt
    if [[ $EUID -ne 0 ]]; then
        # Vérifier si on peut accéder à libvirt sans sudo (groupe libvirt)
        if ! virsh -c qemu:///system list &>/dev/null 2>&1; then
            VIRSH="sudo virsh"
            QEMU_IMG="sudo qemu-img"
            log_info "Utilisation de sudo pour les commandes libvirt"
        fi
    fi
}

# Variables globales
SOURCE_VM=""
NEW_VM=""
VM_IP=""
AUTO_START=false
START_NOW=false
LINKED_CLONE=false
SRC_DISK=""
DST_DISK=""
CLONE_DURATION=0

usage() {
    cat << EOF
Usage: $0 <source-vm> <new-vm-name> [OPTIONS]

Clone une VM KVM existante vers une nouvelle VM.

Arguments:
    source-vm       Nom de la VM source (template)
    new-vm-name     Nom de la nouvelle VM

Options:
    -s, --start         Démarrer la VM après clonage
    -a, --autostart     Configurer autostart au boot
    -l, --linked        Clone lié (plus rapide, dépendant du source)
    -n, --network NET   Réseau à utiliser (défaut: $DEFAULT_NETWORK)
    -h, --help          Afficher cette aide

Exemples:
    $0 fedora-template preprod-app
    $0 fedora-template preprod-db --start
    $0 ubuntu-base test-vm --linked --start

Notes:
    - La VM source sera arrêtée si elle est en cours d'exécution
    - Les clones liés sont plus rapides mais dépendent de l'image source
    - Le nouveau clone aura une nouvelle adresse MAC (nouveau DHCP)
EOF
}

check_dependencies() {
    local deps=(virsh qemu-img uuidgen)
    local missing=()

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dépendances manquantes: ${missing[*]}"
        log_info "Installez avec: sudo dnf install libvirt-client qemu-img util-linux"
        exit 1
    fi
}

check_libvirt() {
    # Fedora moderne utilise des daemons modulaires (virtqemud) au lieu de libvirtd
    if $SUDO systemctl is-active --quiet libvirtd || \
       $SUDO systemctl is-active --quiet virtqemud.socket; then
        return 0
    fi

    log_error "Service libvirt non actif (ni libvirtd ni virtqemud)"
    log_info "Démarrez avec: sudo systemctl start virtqemud.socket"
    exit 1
}

check_source_vm() {
    log_step "Vérification de la VM source: $SOURCE_VM"
    _lyra_progress 1 3 "Validation" 10 0 0

    if ! $VIRSH dominfo "$SOURCE_VM" &>/dev/null; then
        log_error "VM source '$SOURCE_VM' non trouvée"
        echo ""
        echo "VMs disponibles:"
        $VIRSH list --all --name | grep -v '^$' | sed 's/^/  - /'
        exit 1
    fi

    log_info "VM source trouvée"
}

check_target_name() {
    log_step "Vérification du nom cible: $NEW_VM"

    if $VIRSH dominfo "$NEW_VM" &>/dev/null; then
        log_error "Une VM nommée '$NEW_VM' existe déjà"
        exit 1
    fi

    log_info "Nom disponible"
}

stop_source_if_running() {
    local state=$($VIRSH domstate "$SOURCE_VM" 2>/dev/null)

    if [[ "$state" == "running" ]]; then
        log_warn "La VM source est en cours d'exécution"
        log_step "Arrêt de la VM source..."

        $VIRSH shutdown "$SOURCE_VM" &>/dev/null || true

        # Attendre l'arrêt (max 60s)
        local timeout=60
        local elapsed=0
        while [[ $($VIRSH domstate "$SOURCE_VM" 2>/dev/null) == "running" ]]; do
            sleep 2
            ((elapsed+=2))
            if [[ $elapsed -ge $timeout ]]; then
                log_warn "Timeout - forçage de l'arrêt..."
                $VIRSH destroy "$SOURCE_VM" &>/dev/null || true
                sleep 2
                break
            fi
            echo -n "."
        done
        echo ""

        log_info "VM source arrêtée"
    fi
}

get_source_disk() {
    # Obtenir le chemin du disque principal
    # Format: Type(file) Peripherique(disk) Cible(vda) Source(/path/to/disk)
    $VIRSH domblklist "$SOURCE_VM" --details 2>/dev/null | awk '/file.*disk/{print $4}' | head -1
}

_lyra_progress() {
    local step=$1 total=$2 name=$3 pct=$4
    local gb_done=${5:-0} gb_total=${6:-0}
    if [ -n "${LYRA_PROGRESS_FILE:-}" ]; then
        LC_NUMERIC=C printf '{"step":%d,"total":%d,"name":"%s","pct":%d,"percentage":%d,"gb_done":%.1f,"gb_total":%.1f}\n' \
            "$step" "$total" "$name" "$pct" "$pct" "$gb_done" "$gb_total" > "$LYRA_PROGRESS_FILE"
    fi
}

clone_disk() {
    local src_disk="$1"
    local dst_disk="$2"

    if [[ "$LINKED_CLONE" == true ]]; then
        log_step "Creation clone lie (qemu-img create)..."
        # Instantane, pas de progression
        $QEMU_IMG create -f qcow2 \
            -b "$src_disk" \
            -F qcow2 \
            "$dst_disk"
        log_info "Clone lie cree: $dst_disk"
    else
        log_step "Copie du disque (qemu-img convert)..."
        # qemu-img convert avec progression sur stderr (format: "(XX.XX%)")
        # On parse et on emet un format structure pour le MCP handler.
        # On utilise un fifo + sous-shell explicite pour eviter les problemes
        # de pipefail avec set -euo pipefail.
        local tmp_rc
        tmp_rc=$(mktemp /tmp/qemu-rc-XXXXXX)
        trap "rm -f $tmp_rc" RETURN

        # Lancer qemu-img en arriere-plan, rediriger stderr vers stdout
        # pour le parsing de progression, capturer son code de retour
        (
            $QEMU_IMG convert -p -O qcow2 "$src_disk" "$dst_disk" 2>&1
            echo "$?" > "$tmp_rc"
        ) | while IFS= read -r line; do
            if [[ "$line" =~ \(([0-9]+\.[0-9]+)%\) ]]; then
                local pct="${BASH_REMATCH[1]}"
                local pct_int="${pct%%.*}"
                _lyra_progress 2 3 "Clonage VM" "$pct_int" 0 0
                echo "CLONE_PROGRESS:${pct}" >&2
            fi
        done

        # Lire le code de retour de qemu-img
        local qemu_exit=0
        [[ -f "$tmp_rc" ]] && qemu_exit=$(cat "$tmp_rc")
        if [[ "$qemu_exit" -ne 0 ]]; then
            log_error "qemu-img convert a echoue (code $qemu_exit)"
            return "$qemu_exit"
        fi
        log_info "Disque copie: $dst_disk"
    fi
}

register_vm() {
    local src_vm="$1"
    local dst_vm="$2"
    local dst_disk="$3"
    local src_disk="$4"

    log_step "Enregistrement de la VM ($dst_vm)..."

    local new_uuid
    new_uuid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

    local new_mac
    new_mac=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))

    local tmpxml
    tmpxml=$(mktemp /tmp/vm-define-XXXXXX.xml)
    # Nettoyage garanti a la sortie de la fonction
    trap "rm -f $tmpxml" RETURN

    $VIRSH dumpxml "$src_vm" \
        | sed "s|<name>${src_vm}</name>|<name>${dst_vm}</name>|g" \
        | sed "s|<uuid>[^<]*</uuid>|<uuid>${new_uuid}</uuid>|" \
        | sed "s|${src_disk}|${dst_disk}|g" \
        | sed "s|mac address='[^']*'|mac address='${new_mac}'|" \
        > "$tmpxml"

    $VIRSH define "$tmpxml"
    log_info "VM enregistree: $dst_vm (UUID: $new_uuid, MAC: $new_mac)"
}

determine_disks() {
    SRC_DISK=$(get_source_disk)
    if [[ -z "$SRC_DISK" ]]; then
        log_error "Impossible de trouver le disque source de $SOURCE_VM"
        exit 1
    fi

    local src_basename
    src_basename=$(basename "$SRC_DISK")
    local src_ext="${src_basename##*.}"

    DST_DISK="${KVM_IMAGES_DIR}/${NEW_VM}.${src_ext}"

    if [[ -f "$DST_DISK" ]]; then
        log_error "Disque destination existe deja: $DST_DISK"
        exit 1
    fi
}

clone_vm() {
    log_step "Clonage en cours..."

    _lyra_progress 2 3 "Clonage VM" 0 0 0

    local start_time
    start_time=$(date +%s)

    determine_disks

    log_info "Disque source: $SRC_DISK"
    log_info "Nouveau disque: $DST_DISK"

    if [[ "$LINKED_CLONE" == true ]]; then
        # Clone lie (backing file)
        log_warn "CLONE LIE: '$NEW_VM' depend du disque source '$SRC_DISK'"
        log_warn "Ne supprimez PAS la VM source '$SOURCE_VM' tant que ce clone existe."

        clone_disk "$SRC_DISK" "$DST_DISK"

        # Enregistrer la relation source->clone dans le fichier de tracking
        local tracking_file="${KVM_IMAGES_DIR}/.linked-clones"
        echo "$(date -Iseconds) SOURCE=$SOURCE_VM DISK=$SRC_DISK CLONE=$NEW_VM CLONE_DISK=$DST_DISK" \
            >> "$tracking_file" 2>/dev/null || \
            log_warn "Impossible d'ecrire dans $tracking_file (non bloquant)"
    else
        # Clone complet via qemu-img direct (hors pool libvirt -- pas de conflit parallele)
        log_info "Creation d'un clone complet (qemu-img direct, hors pool libvirt)..."
        clone_disk "$SRC_DISK" "$DST_DISK"
    fi

    # Enregistrer la VM dans libvirt via virsh define (hors virt-clone)
    register_vm "$SOURCE_VM" "$NEW_VM" "$DST_DISK" "$SRC_DISK"

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    CLONE_DURATION="$duration"

    log_info "Clonage termine en ${duration}s"
}

configure_network() {
    log_step "Configuration réseau..."

    # S'assurer que la VM utilise le bon réseau
    local current_net=$($VIRSH domiflist "$NEW_VM" 2>/dev/null | grep -E "network|bridge" | head -1 | awk '{print $3}')

    if [[ "$current_net" != "$DEFAULT_NETWORK" ]]; then
        log_warn "Réseau actuel: $current_net"
        # Note: la modification de réseau nécessite une édition XML plus complexe
        # Pour l'instant, on garde le réseau du template
    fi

    log_info "Réseau: $current_net"
}

fix_nm_post_clone() {
    # Injecte un profil NM generique DHCP sans MAC binding + corrige grub BLS
    # Doit etre appelé sur une VM ARRETEE (guestfish)
    local script_dir
    script_dir="$(dirname "${BASH_SOURCE[0]}")"

    local fix_nm="${script_dir}/fix-nm-connection-vm.sh"
    local fix_grub="${script_dir}/_fix-grub-vm.sh"

    log_step "Corrections post-clone (NM + grub BLS)..."

    if [[ -x "$fix_nm" ]]; then
        if $SUDO "$fix_nm" "$NEW_VM"; then
            log_info "Profils NM corriges (interface-name supprime, DHCP generique injecte)"
        else
            log_warn "NM fix echoue (non bloquant)"
        fi
    else
        log_warn "fix-nm-connection-vm.sh introuvable: $fix_nm"
    fi

    if [[ -x "$fix_grub" ]]; then
        if $SUDO "$fix_grub" "$NEW_VM"; then
            log_info "BLS grub corrige (rd.lvm.lv et params host supprimes)"
        else
            log_warn "Grub BLS fix echoue (non bloquant)"
        fi
    else
        log_warn "_fix-grub-vm.sh introuvable: $fix_grub"
    fi
}

post_clone_setup() {
    log_step "Configuration post-clonage..."
    _lyra_progress 3 3 "Post-configuration" 100 0 0

    # Autostart si demandé
    if [[ "$AUTO_START" == true ]]; then
        $VIRSH autostart "$NEW_VM"
        log_info "Autostart activé"
    fi

    # Démarrer si demandé
    if [[ "$START_NOW" == true ]]; then
        # NM fix impossible après démarrage: avertir seulement
        log_warn "NM fix: sera applicable uniquement quand la VM sera arrêtée"
        log_warn "Après arrêt, lancez: sudo ./scripts/kvm/fix-nm-connection-vm.sh $NEW_VM"

        log_info "Démarrage de la VM..."
        $VIRSH start "$NEW_VM"

        # Attendre un peu et afficher l'IP
        sleep 5
        show_vm_ip

        # Configurer le hostname neutron-<nom>
        if [[ -n "$VM_IP" ]]; then
            set_hostname
        fi
    else
        # VM encore arrêtée: appliquer le NM fix maintenant
        fix_nm_post_clone
    fi
}

show_vm_ip() {
    log_step "Recherche de l'adresse IP..."

    # Attendre que la VM obtienne une IP (max 60s, 6 méthodes de fallback)
    local timeout=60
    local elapsed=0
    local ip=""

    while [[ -z "$ip" && $elapsed -lt $timeout ]]; do
        # Méthode 1: virsh domifaddr (nécessite qemu-guest-agent)
        ip=$($VIRSH domifaddr "$NEW_VM" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)

        # Méthode 2: leases dnsmasq
        if [[ -z "$ip" ]]; then
            local mac
            mac=$($VIRSH domiflist "$NEW_VM" 2>/dev/null | awk '/network|bridge/{print $5}' | head -1 || true)
            if [[ -n "$mac" ]]; then
                if [[ -f /var/lib/libvirt/dnsmasq/virbr0.status ]]; then
                    ip=$(grep -A2 "$mac" /var/lib/libvirt/dnsmasq/virbr0.status 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
                fi

                # Méthode 3: virsh net-dhcp-leases
                if [[ -z "$ip" ]]; then
                    ip=$($VIRSH net-dhcp-leases default 2>/dev/null | grep -i "$mac" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
                fi

                # Méthode 4: table ARP
                if [[ -z "$ip" ]]; then
                    ip=$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1 || true)
                    if [[ -z "$ip" ]]; then
                        ip=$(arp -an 2>/dev/null | grep -i "$mac" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
                    fi
                fi
            fi
        fi

        if [[ -z "$ip" ]]; then
            sleep 2
            ((elapsed+=2))
            echo -n "."
        fi
    done
    echo ""

    # Méthode 5: ping sweep pour peupler la table ARP (si toujours rien)
    if [[ -z "$ip" ]]; then
        log_info "Ping sweep du réseau 192.168.122.0/24..."
        for i in {2..254}; do
            ping -c1 -W1 "192.168.122.$i" &>/dev/null &
        done
        wait 2>/dev/null
        sleep 1
        local mac
        mac=$($VIRSH domiflist "$NEW_VM" 2>/dev/null | awk '/network|bridge/{print $5}' | head -1 || true)
        if [[ -n "$mac" ]]; then
            ip=$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1 || true)
        fi
    fi

    # Méthode 6: nmap si disponible
    if [[ -z "$ip" ]] && command -v nmap &>/dev/null; then
        log_info "Scan nmap du réseau..."
        local mac
        mac=$($VIRSH domiflist "$NEW_VM" 2>/dev/null | awk '/network|bridge/{print $5}' | head -1 || true)
        if [[ -n "$mac" ]]; then
            ip=$(nmap -sn 192.168.122.0/24 2>/dev/null | grep -B2 "$mac" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
        fi
    fi

    if [[ -n "$ip" ]]; then
        log_info "Adresse IP: $ip"
        VM_IP="$ip"
        echo ""
        echo "Connexion SSH:"
        echo "  ssh user@$ip"
    else
        log_warn "IP non détectée (la VM peut mettre plus de temps à booter)"
        log_warn "Si qemu-guest-agent n'est pas installé dans le template, les méthodes DHCP/ARP sont utilisées."
        echo "Vérifiez plus tard avec: $VIRSH domifaddr $NEW_VM"
        echo "Ou consultez: $VIRSH net-dhcp-leases default"
    fi
}

set_hostname() {
    # Change le hostname de la VM clonée en neutron-<nom>
    # Note: Ne fait pas échouer le script si SSH n'est pas disponible
    local new_hostname="neutron-${NEW_VM}"
    log_step "Configuration du hostname: $new_hostname"

    # Attendre que SSH soit disponible (max 30s)
    local timeout=30
    local elapsed=0
    local ssh_ok=false

    while [[ "$ssh_ok" == false && $elapsed -lt $timeout ]]; do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 -o BatchMode=yes "${VM_SSH_USER:-${SUDO_USER:-$USER}}@$VM_IP" "echo OK" &>/dev/null; then
            ssh_ok=true
        else
            sleep 3
            ((elapsed+=3))
            echo -n "."
        fi
    done
    echo ""

    if [[ "$ssh_ok" == true ]]; then
        # Changer le hostname via SSH (ignorer erreur sudo)
        if ssh -o StrictHostKeyChecking=accept-new "${VM_SSH_USER:-${SUDO_USER:-$USER}}@$VM_IP" "sudo hostnamectl set-hostname '$new_hostname'" 2>/dev/null; then
            log_info "Hostname configuré: $new_hostname"
        else
            log_warn "Impossible de configurer le hostname (sudo requis)"
        fi
    else
        log_warn "SSH non disponible - hostname non modifié"
    fi
    # Toujours retourner succes (le clone est fait meme si hostname echoue)
    return 0
}

show_summary() {
    echo ""
    echo "============================================"
    echo -e "${GREEN}  Clone créé avec succès!${NC}"
    echo "============================================"
    echo ""
    echo "VM Source:  $SOURCE_VM"
    echo "Nouveau:    $NEW_VM"
    echo "Type:       $(if [[ "$LINKED_CLONE" == true ]]; then echo "Lié"; else echo "Complet"; fi)"
    echo ""
    if [[ "$LINKED_CLONE" == true ]]; then
        echo -e "${YELLOW}ATTENTION (clone lié):${NC}"
        echo "  - Ce clone dépend du disque source de '$SOURCE_VM'"
        echo "  - Ne supprimez PAS '$SOURCE_VM' tant que '$NEW_VM' existe"
        echo "  - Relation enregistrée dans ${KVM_IMAGES_DIR}/.linked-clones"
        echo ""
    fi
    echo "Commandes utiles:"
    echo "  virsh start $NEW_VM      # Démarrer"
    echo "  virsh console $NEW_VM    # Console"
    echo "  virsh domifaddr $NEW_VM  # Voir IP"
    echo "  virsh destroy $NEW_VM    # Forcer arrêt"
    echo "  virsh undefine $NEW_VM --remove-all-storage  # Supprimer"
    echo ""
}

parse_args() {
    if [[ $# -lt 2 ]]; then
        usage
        exit 1
    fi

    SOURCE_VM="$1"
    NEW_VM="$2"
    shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--start)
                START_NOW=true
                shift
                ;;
            -a|--autostart)
                AUTO_START=true
                shift
                ;;
            -l|--linked)
                LINKED_CLONE=true
                shift
                ;;
            -n|--network)
                DEFAULT_NETWORK="$2"
                shift 2
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
    echo "  KVM Clone - Clonage Rapide de VMs"
    echo "============================================"
    echo ""

    check_dependencies
    check_libvirt
    setup_sudo
    check_source_vm
    check_target_name
    stop_source_if_running
    clone_vm
    configure_network
    post_clone_setup
    show_summary
}

main "$@"
