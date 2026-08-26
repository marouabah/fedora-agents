#!/usr/bin/env bash
#
# vm-snapshot.sh - Wrapper pour la gestion des snapshots VM
# Utilise le script existant: scripts/kvm/kvm-snapshot.sh
#
# Usage: vm-snapshot.sh <vm-name> <action> [snapshot-name] [OPTIONS]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Exporter la connexion libvirt pour le script KVM existant
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Chemin vers le script KVM existant
KVM_SNAPSHOT_SCRIPT="${KVM_SCRIPTS_DIR}/kvm-snapshot.sh"

# Options
DESCRIPTION=""
QUIESCE=false
LIVE=false
NO_CONFIRM=false

usage() {
    cat << EOF
Usage: $(basename "$0") <vm-name> <action> [snapshot-name] [OPTIONS]

Wrapper pour la gestion des snapshots VM.
Utilise: kvm-snapshot.sh

Actions:
    create <name>     Créer un snapshot
    list              Lister les snapshots
    restore <name>    Restaurer un snapshot
    delete <name>     Supprimer un snapshot
    delete-all        Supprimer tous les snapshots

Options:
    --description="X" Description du snapshot (pour create)
    --quiesce         Snapshot avec guest agent (nécessite qemu-ga)
    --live            Snapshot à chaud avec état mémoire
    -y, --yes         Pas de confirmation interactive
    -h, --help        Afficher cette aide

Exemples:
    $(basename "$0") neutron-clone create "avant-backup-test"
    $(basename "$0") neutron-clone create "pre-update" --description="Avant mise à jour"
    $(basename "$0") neutron-clone list
    $(basename "$0") neutron-clone restore "avant-backup-test" -y
    $(basename "$0") neutron-clone delete "avant-backup-test"

EOF
    show_module_help "$(basename "$0")"
}

check_kvm_script() {
    if [[ ! -x "$KVM_SNAPSHOT_SCRIPT" ]]; then
        log_error "Script kvm-snapshot.sh non trouvé ou non exécutable"
        log_info "Attendu: $KVM_SNAPSHOT_SCRIPT"
        return 1
    fi
    return 0
}

parse_args() {
    # Check for help first
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                usage
                exit 0
                ;;
        esac
    done

    if [[ $# -lt 2 ]]; then
        usage
        exit 1
    fi

    VM_NAME="$1"
    ACTION="$2"
    SNAP_NAME="${3:-}"
    shift 2
    [[ $# -gt 0 && ! "$1" =~ ^-- ]] && shift  # Skip snap_name if provided

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --description=*)
                DESCRIPTION="${1#*=}"
                shift
                ;;
            --quiesce)
                QUIESCE=true
                shift
                ;;
            --live)
                LIVE=true
                shift
                ;;
            -y|--yes)
                NO_CONFIRM=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                # Peut être le nom du snapshot si pas encore capturé
                if [[ -z "$SNAP_NAME" && ! "$1" =~ ^- ]]; then
                    SNAP_NAME="$1"
                    shift
                else
                    log_error "Option inconnue: $1"
                    usage
                    exit 1
                fi
                ;;
        esac
    done
}

# Wrapper non-interactif pour create
do_create() {
    local vm="$1"
    local snap="${2:-snap-$(date +%Y%m%d-%H%M%S)}"

    log_step "Création snapshot: $snap pour VM: $vm"

    local args=("create" "$vm" "$snap")

    if [[ -n "$DESCRIPTION" ]]; then
        args+=("--desc" "$DESCRIPTION")
    fi

    if [[ "$LIVE" == true ]]; then
        args+=("--live")
    fi

    "$KVM_SNAPSHOT_SCRIPT" "${args[@]}"
    return $?
}

# Wrapper non-interactif pour list
do_list() {
    local vm="$1"
    "$KVM_SNAPSHOT_SCRIPT" list "$vm"
    return $?
}

# Wrapper pour restore (avec option -y pour skip confirmation)
do_restore() {
    local vm="$1"
    local snap="$2"

    if [[ -z "$snap" ]]; then
        log_error "Nom du snapshot requis pour restore"
        return 1
    fi

    log_step "Restauration snapshot: $snap"

    if [[ "$NO_CONFIRM" == true ]]; then
        # Skip confirmation en simulant 'y'
        echo "y" | "$KVM_SNAPSHOT_SCRIPT" revert "$vm" "$snap"
    else
        "$KVM_SNAPSHOT_SCRIPT" revert "$vm" "$snap"
    fi

    return $?
}

# Wrapper pour delete
do_delete() {
    local vm="$1"
    local snap="$2"

    if [[ -z "$snap" ]]; then
        log_error "Nom du snapshot requis pour delete"
        return 1
    fi

    log_step "Suppression snapshot: $snap"

    if [[ "$NO_CONFIRM" == true ]]; then
        echo "y" | "$KVM_SNAPSHOT_SCRIPT" delete "$vm" "$snap"
    else
        "$KVM_SNAPSHOT_SCRIPT" delete "$vm" "$snap"
    fi

    return $?
}

# Wrapper pour delete-all
do_delete_all() {
    local vm="$1"

    log_step "Suppression de tous les snapshots"

    if [[ "$NO_CONFIRM" == true ]]; then
        echo "y" | "$KVM_SNAPSHOT_SCRIPT" delete-all "$vm"
    else
        "$KVM_SNAPSHOT_SCRIPT" delete-all "$vm"
    fi

    return $?
}

snapshot_action() {
    local vm="$1"
    local action="$2"

    # Vérifier que la VM existe
    if ! check_vm "$vm"; then
        echo ""
        echo "VMs disponibles:"
        list_vms | sed 's/^/  - /'
        return 1
    fi

    # Vérifier que le script kvm-snapshot.sh existe
    if ! check_kvm_script; then
        return 1
    fi

    case "$action" in
        create)
            do_create "$vm" "$SNAP_NAME"
            ;;
        list|ls)
            do_list "$vm"
            ;;
        restore|revert)
            do_restore "$vm" "$SNAP_NAME"
            ;;
        delete|rm)
            do_delete "$vm" "$SNAP_NAME"
            ;;
        delete-all|rm-all)
            do_delete_all "$vm"
            ;;
        *)
            log_error "Action inconnue: $action"
            usage
            return 1
            ;;
    esac

    return $?
}

main() {
    parse_args "$@"

    local result
    if snapshot_action "$VM_NAME" "$ACTION"; then
        result=0
    else
        result=$?
    fi

    exit $result
}

# Permettre le sourcing sans exécution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
