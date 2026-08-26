#!/usr/bin/env bash
#
# vm-stop.sh - Wrapper pour arrêter une VM KVM
# Usage: vm-stop.sh <vm-name> [OPTIONS]
#
# Retour:
#   0 = OK
#   1 = Erreur
#   2 = Timeout
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Options
FORCE=false
WAIT=false
TIMEOUT=60

usage() {
    cat << EOF
Usage: $(basename "$0") <vm-name> [OPTIONS]

Arrête une VM KVM proprement ou de force.

Options:
    --force         Destroy au lieu de shutdown (arrêt brutal)
    --wait          Attend l'arrêt complet
    --timeout=N     Timeout pour shutdown (défaut: $TIMEOUT)
    -h, --help      Afficher cette aide

Comportement:
    - Essaie un shutdown propre d'abord
    - Si timeout, propose force destroy
    - Vérifie que la VM est bien arrêtée

Exemples:
    $(basename "$0") neutron-clone
    $(basename "$0") neutron-clone --wait
    $(basename "$0") neutron-clone --force

EOF
    show_module_help "$(basename "$0")"
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

    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    VM_NAME="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                FORCE=true
                shift
                ;;
            --wait|-w)
                WAIT=true
                shift
                ;;
            --timeout=*)
                TIMEOUT="${1#*=}"
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

wait_for_shutdown() {
    local vm="$1"
    local timeout="$2"
    local elapsed=0

    while is_vm_running "$vm"; do
        sleep 2
        ((elapsed+=2))
        echo -n "."
        if [[ $elapsed -ge $timeout ]]; then
            echo ""
            return 1
        fi
    done
    echo ""
    return 0
}

stop_vm() {
    local vm="$1"

    # Vérifier que la VM existe
    if ! check_vm "$vm"; then
        echo ""
        echo "VMs disponibles:"
        list_vms | sed 's/^/  - /'
        return 1
    fi

    # Vérifier si déjà arrêtée
    if ! is_vm_running "$vm"; then
        log_info "VM '$vm' déjà arrêtée"
        return 0
    fi

    if [[ "$FORCE" == true ]]; then
        # Arrêt brutal
        log_step "Arrêt forcé de la VM: $vm"
        if $VIRSH destroy "$vm" &>/dev/null; then
            log_ok "VM arrêtée (force)"
            return 0
        else
            log_error "Échec de l'arrêt forcé"
            return 1
        fi
    fi

    # Shutdown propre
    log_step "Arrêt propre de la VM: $vm"

    if ! $VIRSH shutdown "$vm" &>/dev/null; then
        log_warn "Commande shutdown échouée, tentative destroy..."
        if $VIRSH destroy "$vm" &>/dev/null; then
            log_ok "VM arrêtée (destroy)"
            return 0
        else
            log_error "Échec de l'arrêt"
            return 1
        fi
    fi

    if [[ "$WAIT" == true ]]; then
        log_info "Attente de l'arrêt (timeout: ${TIMEOUT}s)..."
        if wait_for_shutdown "$vm" "$TIMEOUT"; then
            log_ok "VM arrêtée proprement"
            return 0
        else
            log_warn "Timeout - la VM ne s'est pas arrêtée"
            echo ""
            local do_force=false
            if [[ "${FORCE:-false}" == "true" ]] || [[ ! -t 0 ]]; then
                do_force=true
            else
                read -rp "Forcer l'arrêt? (y/N) " -n 1
                echo
                [[ $REPLY =~ ^[Yy]$ ]] && do_force=true
            fi
            if [[ "$do_force" == true ]]; then
                if $VIRSH destroy "$vm" &>/dev/null; then
                    log_ok "VM arrêtée (force après timeout)"
                    return 0
                fi
            fi
            return 2
        fi
    else
        log_ok "Commande shutdown envoyée"
        log_info "Utilisez --wait pour attendre l'arrêt complet"
    fi

    return 0
}

main() {
    parse_args "$@"

    local result
    if stop_vm "$VM_NAME"; then
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
