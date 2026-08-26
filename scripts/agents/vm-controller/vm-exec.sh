#!/usr/bin/env bash
#
# vm-exec.sh - Exécuter des commandes dans une VM KVM via SSH
# Usage: vm-exec.sh <vm-name> <command> [OPTIONS]
#
# Retour: Exit code de la commande exécutée
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Options
SSH_USER="${VM_SSH_USER:-${SUDO_USER:-$USER}}"
TIMEOUT="${VM_TIMEOUT:-300}"
USE_SUDO=false
CAPTURE_OUTPUT=false

usage() {
    cat << EOF
Usage: $(basename "$0") <vm-name> <command> [OPTIONS]

Exécute une commande dans une VM KVM via SSH.

Options:
    --user=USER     User SSH (défaut: $SSH_USER)
    --timeout=N     Timeout commande (défaut: $TIMEOUT)
    --sudo          Exécute avec sudo (demande le mot de passe interactivement)
    --capture       Mode silencieux, capture output uniquement
    -h, --help      Afficher cette aide

Notes:
    - Avec --sudo, un TTY est alloué pour permettre la saisie du mot de passe
    - Sans --sudo, la connexion est en mode batch (non-interactif)

Exemples:
    $(basename "$0") neutron-clone "uname -a"
    $(basename "$0") neutron-clone "dnf install -y borgbackup" --sudo
    $(basename "$0") neutron-clone "cat /etc/fedora-release" --capture

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

    if [[ $# -lt 2 ]]; then
        usage
        exit 1
    fi

    VM_NAME="$1"
    COMMAND="$2"
    shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user=*)
                SSH_USER="${1#*=}"
                shift
                ;;
            --timeout=*)
                TIMEOUT="${1#*=}"
                shift
                ;;
            --sudo)
                USE_SUDO=true
                shift
                ;;
            --capture)
                CAPTURE_OUTPUT=true
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

exec_via_ssh() {
    local vm="$1"
    local cmd="$2"

    # Obtenir l'IP
    local ip=$(get_vm_ip "$vm")

    if [[ -z "$ip" ]]; then
        log_error "Impossible d'obtenir l'IP de '$vm'"
        log_info "Vérifiez que la VM est démarrée"
        return 1
    fi

    # Préparer la commande
    local full_cmd="$cmd"
    if [[ "$USE_SUDO" == true ]]; then
        full_cmd="sudo $cmd"
    fi

    if [[ "$CAPTURE_OUTPUT" == false ]]; then
        log_step "Exécution sur $vm ($ip)"
        log_info "Commande: $cmd"
        [[ "$USE_SUDO" == true ]] && log_info "Mode: sudo (mot de passe requis)"
    fi

    # Options SSH de base
    local ssh_opts=(
        -o "ConnectTimeout=10"
        -o "StrictHostKeyChecking=no"
        -o "UserKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
        -p "$VM_SSH_PORT"
    )

    # Si sudo: allouer un TTY pour permettre la saisie du mot de passe
    # Sinon: mode batch (non-interactif)
    if [[ "$USE_SUDO" == true ]]; then
        ssh_opts+=("-t")  # Allouer un pseudo-terminal
    else
        ssh_opts+=(-o "BatchMode=yes")
    fi

    # Exécuter
    local result
    if [[ "$CAPTURE_OUTPUT" == true ]]; then
        # Mode capture: output uniquement
        ssh "${ssh_opts[@]}" "${SSH_USER}@${ip}" "$full_cmd"
        result=$?
    else
        # Mode normal: avec logs
        echo "------- OUTPUT -------"
        ssh "${ssh_opts[@]}" "${SSH_USER}@${ip}" "$full_cmd"
        result=$?
        echo "----------------------"

        if [[ $result -eq 0 ]]; then
            log_ok "Commande terminée (exit code: 0)"
        else
            log_warn "Commande terminée (exit code: $result)"
        fi
    fi

    return $result
}

exec_command() {
    local vm="$1"
    local cmd="$2"

    # Vérifier que la VM existe
    if ! check_vm "$vm"; then
        echo ""
        echo "VMs disponibles:"
        list_vms | sed 's/^/  - /'
        return 1
    fi

    # Vérifier que la VM est running
    if ! is_vm_running "$vm"; then
        log_error "VM '$vm' n'est pas en cours d'exécution"
        log_info "Démarrez avec: vm-start.sh $vm"
        return 1
    fi

    # Exécuter via SSH
    exec_via_ssh "$vm" "$cmd"
    return $?
}

main() {
    parse_args "$@"

    local result
    if exec_command "$VM_NAME" "$COMMAND"; then
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
