#!/usr/bin/env bash
#
# vm-start.sh - Wrapper pour démarrer une VM KVM
# Usage: vm-start.sh <vm-name> [OPTIONS]
#
# Retour:
#   0 = OK
#   1 = Erreur démarrage
#   2 = Timeout
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Options
WAIT_IP=false
WAIT_SSH=false
TIMEOUT="${VM_TIMEOUT:-300}"

usage() {
    cat << EOF
Usage: $(basename "$0") <vm-name> [OPTIONS]

Démarre une VM KVM et attend optionnellement qu'elle soit prête.

Options:
    --wait-ip       Attend que l'IP soit assignée
    --wait-ssh      Attend que SSH soit accessible
    --timeout=N     Timeout en secondes (défaut: $TIMEOUT)
    -h, --help      Afficher cette aide

Retour:
    0 = Succès
    1 = Erreur de démarrage
    2 = Timeout

Exemples:
    $(basename "$0") neutron-clone
    $(basename "$0") neutron-clone --wait-ssh
    $(basename "$0") neutron-clone --wait-ip --timeout=120

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
            --wait-ip)
                WAIT_IP=true
                shift
                ;;
            --wait-ssh)
                WAIT_SSH=true
                WAIT_IP=true  # SSH implique IP
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

start_vm() {
    local vm="$1"

    # Vérifier que la VM existe
    if ! check_vm "$vm"; then
        echo ""
        echo "VMs disponibles:"
        list_vms | sed 's/^/  - /'
        return 1
    fi

    # Vérifier si déjà running
    if is_vm_running "$vm"; then
        log_info "VM '$vm' déjà en cours d'exécution"
        local ip=$(get_vm_ip "$vm")
        if [[ -n "$ip" ]]; then
            log_info "IP: $ip"
            echo "$ip"
        fi
        return 0
    fi

    log_step "Démarrage de la VM: $vm"

    # Pré-vérification : disque accessible ? (les VMs migrées sur le disque
    # externe /mnt/ext-backup échouent avec un simple "code 1" sinon)
    local disk
    disk=$($VIRSH domblklist "$vm" 2>/dev/null | awk 'NR>2 && $2 != "-" {print $2; exit}')
    if [[ -n "$disk" && ! -e "$disk" ]]; then
        log_error "Disque introuvable: $disk"
        if [[ "$disk" == /mnt/ext-backup/* ]]; then
            log_error "Le disque externe de backup n'est pas monté (/mnt/ext-backup). Branche-le puis réessaie."
        fi
        return 1
    fi

    # Démarrer la VM
    local virsh_err
    if ! virsh_err=$($VIRSH start "$vm" 2>&1 >/dev/null); then
        log_error "Échec du démarrage de '$vm'"
        [[ -n "$virsh_err" ]] && log_error "$(echo "$virsh_err" | head -2)"
        return 1
    fi

    log_ok "VM '$vm' démarrée"

    # Attendre IP si demandé
    if [[ "$WAIT_IP" == true ]]; then
        log_step "[$vm] Attente de l'attribution IP..."
        local ip=$(wait_ip "$vm" "$TIMEOUT")
        local ret=$?

        if [[ $ret -ne 0 ]]; then
            log_error "[$vm] Timeout en attendant l'IP"
            return 2
        fi

        log_ok "[$vm] IP obtenue: $ip"

        # Attendre SSH si demandé
        if [[ "$WAIT_SSH" == true ]]; then
            log_step "[$vm] Attente de SSH..."
            if ! wait_ssh "$vm" "$TIMEOUT"; then
                log_error "[$vm] Timeout en attendant SSH"
                return 2
            fi
            log_ok "[$vm] SSH accessible"
        fi

        # Output final: l'IP
        echo "$ip"
    fi

    return 0
}

main() {
    parse_args "$@"

    local result
    if start_vm "$VM_NAME"; then
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
