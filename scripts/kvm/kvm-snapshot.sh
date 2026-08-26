#!/usr/bin/env bash
#
# kvm-snapshot.sh - Gestion des snapshots de VMs KVM/Libvirt
# Usage: kvm-snapshot.sh <command> <vm-name> [options]
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

usage() {
    cat << EOF
Usage: $0 <COMMAND> <vm-name> [OPTIONS]

Gestion des snapshots pour VMs KVM/Libvirt.

Commands:
    create <vm> [name]      Créer un snapshot
    list <vm>               Lister les snapshots
    info <vm> <snap>        Détails d'un snapshot
    revert <vm> <snap>      Restaurer un snapshot
    delete <vm> <snap>      Supprimer un snapshot
    delete-all <vm>         Supprimer tous les snapshots

Options:
    -d, --desc TEXT     Description du snapshot (pour create)
    -l, --live          Snapshot à chaud (VM en cours d'exécution)
    -h, --help          Afficher cette aide

Exemples:
    $0 create preprod-app "before-update"
    $0 create preprod-app --desc "Avant mise à jour nginx"
    $0 list preprod-app
    $0 revert preprod-app before-update
    $0 delete preprod-app before-update

Notes:
    - Les snapshots internes nécessitent que la VM utilise qcow2
    - Les snapshots à chaud (--live) gardent l'état mémoire
    - Utilisez des noms descriptifs pour les snapshots
EOF
}

check_dependencies() {
    if ! command -v virsh &>/dev/null; then
        log_error "virsh non trouvé. Installez libvirt-client"
        exit 1
    fi
}

check_vm_exists() {
    local vm="$1"
    if ! virsh dominfo "$vm" &>/dev/null; then
        log_error "VM '$vm' non trouvée"
        echo ""
        echo "VMs disponibles:"
        virsh list --all --name | grep -v '^$' | sed 's/^/  - /'
        exit 1
    fi
}

get_vm_state() {
    local vm="$1"
    virsh domstate "$vm" 2>/dev/null
}

# ============================================
# Commande: create
# ============================================

cmd_create() {
    local vm="$1"
    local snap_name="${2:-snap-$(date +%Y%m%d-%H%M%S)}"
    local description="${SNAP_DESC:-Snapshot créé le $(date '+%Y-%m-%d %H:%M:%S')}"
    local live_flag=""

    check_vm_exists "$vm"

    log_step "Création du snapshot: $snap_name"
    log_info "VM: $vm"
    log_info "Description: $description"

    local state=$(get_vm_state "$vm")

    if [[ "$state" == "running" ]]; then
        if [[ "$LIVE_SNAPSHOT" == true ]]; then
            log_info "Snapshot à chaud (avec état mémoire)"
            live_flag="--live"
        else
            log_warn "VM en cours d'exécution - snapshot disque uniquement"
            log_info "Utilisez --live pour inclure l'état mémoire"
            live_flag="--disk-only"
        fi
    fi

    local start_time=$(date +%s)

    virsh snapshot-create-as "$vm" \
        --name "$snap_name" \
        --description "$description" \
        $live_flag \
        --atomic

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "Snapshot créé en ${duration}s"
    echo ""
    echo "Restaurer avec: $0 revert $vm $snap_name"
}

# ============================================
# Commande: list
# ============================================

cmd_list() {
    local vm="$1"

    check_vm_exists "$vm"

    echo ""
    echo "Snapshots pour VM: $vm"
    echo "============================================"

    local count=$(virsh snapshot-list "$vm" --name 2>/dev/null | grep -v '^$' | wc -l)

    if [[ $count -eq 0 ]]; then
        echo "Aucun snapshot"
        return 0
    fi

    # Afficher avec détails
    virsh snapshot-list "$vm" --tree 2>/dev/null || virsh snapshot-list "$vm"

    echo ""
    echo "Total: $count snapshot(s)"
    echo ""
    echo "Détails: $0 info $vm <snapshot-name>"
}

# ============================================
# Commande: info
# ============================================

cmd_info() {
    local vm="$1"
    local snap="$2"

    check_vm_exists "$vm"

    if ! virsh snapshot-info "$vm" --snapshotname "$snap" &>/dev/null; then
        log_error "Snapshot '$snap' non trouvé pour VM '$vm'"
        echo ""
        cmd_list "$vm"
        exit 1
    fi

    echo ""
    echo "Détails du snapshot: $snap"
    echo "============================================"
    virsh snapshot-info "$vm" --snapshotname "$snap"

    echo ""
    echo "Configuration XML:"
    echo "--------------------------------------------"
    virsh snapshot-dumpxml "$vm" --snapshotname "$snap" | head -30
    echo "..."
}

# ============================================
# Commande: revert
# ============================================

cmd_revert() {
    local vm="$1"
    local snap="$2"

    check_vm_exists "$vm"

    if ! virsh snapshot-info "$vm" --snapshotname "$snap" &>/dev/null; then
        log_error "Snapshot '$snap' non trouvé"
        cmd_list "$vm"
        exit 1
    fi

    log_step "Restauration du snapshot: $snap"
    log_warn "Cette action va restaurer la VM à l'état du snapshot"

    read -p "Continuer? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Annulé"
        exit 0
    fi

    local state=$(get_vm_state "$vm")
    local was_running=false

    if [[ "$state" == "running" ]]; then
        was_running=true
        log_info "Arrêt de la VM..."
        virsh destroy "$vm" &>/dev/null || true
        sleep 2
    fi

    log_info "Restauration en cours..."
    virsh snapshot-revert "$vm" --snapshotname "$snap"

    log_info "Snapshot restauré: $snap"

    # Optionnel: redémarrer si elle était running
    if [[ "$was_running" == true ]]; then
        read -p "Redémarrer la VM? (Y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            virsh start "$vm"
            log_info "VM redémarrée"
        fi
    fi
}

# ============================================
# Commande: delete
# ============================================

cmd_delete() {
    local vm="$1"
    local snap="$2"

    check_vm_exists "$vm"

    if ! virsh snapshot-info "$vm" --snapshotname "$snap" &>/dev/null; then
        log_error "Snapshot '$snap' non trouvé"
        exit 1
    fi

    log_step "Suppression du snapshot: $snap"

    read -p "Confirmer la suppression? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Annulé"
        exit 0
    fi

    virsh snapshot-delete "$vm" --snapshotname "$snap"
    log_info "Snapshot supprimé"
}

# ============================================
# Commande: delete-all
# ============================================

cmd_delete_all() {
    local vm="$1"

    check_vm_exists "$vm"

    local snapshots=$(virsh snapshot-list "$vm" --name 2>/dev/null | grep -v '^$')

    if [[ -z "$snapshots" ]]; then
        log_info "Aucun snapshot à supprimer"
        return 0
    fi

    echo "Snapshots à supprimer:"
    echo "$snapshots" | sed 's/^/  - /'
    echo ""

    log_warn "Cette action va supprimer TOUS les snapshots de $vm"

    read -p "Confirmer la suppression de tous les snapshots? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Annulé"
        exit 0
    fi

    local count=0
    while IFS= read -r snap; do
        if [[ -n "$snap" ]]; then
            log_info "Suppression: $snap"
            virsh snapshot-delete "$vm" --snapshotname "$snap" || true
            ((count++))
        fi
    done <<< "$snapshots"

    log_info "$count snapshot(s) supprimé(s)"
}

# ============================================
# Main
# ============================================

SNAP_DESC=""
LIVE_SNAPSHOT=false

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local cmd="$1"
    shift

    # Parser les options globales
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--desc)
                SNAP_DESC="$2"
                shift 2
                ;;
            -l|--live)
                LIVE_SNAPSHOT=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    set -- "${positional[@]}"

    case "$cmd" in
        create)
            [[ $# -lt 1 ]] && { log_error "VM requise"; usage; exit 1; }
            cmd_create "$1" "${2:-}"
            ;;
        list|ls)
            [[ $# -lt 1 ]] && { log_error "VM requise"; usage; exit 1; }
            cmd_list "$1"
            ;;
        info|show)
            [[ $# -lt 2 ]] && { log_error "VM et snapshot requis"; usage; exit 1; }
            cmd_info "$1" "$2"
            ;;
        revert|restore)
            [[ $# -lt 2 ]] && { log_error "VM et snapshot requis"; usage; exit 1; }
            cmd_revert "$1" "$2"
            ;;
        delete|rm)
            [[ $# -lt 2 ]] && { log_error "VM et snapshot requis"; usage; exit 1; }
            cmd_delete "$1" "$2"
            ;;
        delete-all|rm-all)
            [[ $# -lt 1 ]] && { log_error "VM requise"; usage; exit 1; }
            cmd_delete_all "$1"
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            log_error "Commande inconnue: $cmd"
            usage
            exit 1
            ;;
    esac
}

main() {
    check_dependencies
    parse_args "$@"
}

main "$@"
