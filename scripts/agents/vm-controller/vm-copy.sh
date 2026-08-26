#!/usr/bin/env bash
#
# vm-copy.sh - Transfert de fichiers vers/depuis une VM KVM
# Usage: vm-copy.sh <vm-name> <source> <dest> [OPTIONS]
#
# Retour:
#   0 = OK
#   1 = Erreur
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Options
SSH_USER="${VM_SSH_USER:-${SUDO_USER:-$USER}}"
TO_VM=true  # Défaut: hôte -> VM
CHECKSUM=false
PRESERVE=false
RECURSIVE=false

usage() {
    cat << EOF
Usage: $(basename "$0") <vm-name> <source> <dest> [OPTIONS]

Transfère des fichiers entre l'hôte et une VM KVM via SCP.

Options:
    --to-vm         Copie hôte -> VM (défaut)
    --from-vm       Copie VM -> hôte
    --checksum      Vérifie intégrité avec md5sum
    --preserve      Préserve permissions/timestamps
    -r, --recursive Copie récursive (pour dossiers)
    -h, --help      Afficher cette aide

Exemples:
    # Copier un fichier vers la VM
    $(basename "$0") neutron-clone ./script.sh /tmp/

    # Récupérer un fichier depuis la VM
    $(basename "$0") neutron-clone /var/log/app.log ./logs/ --from-vm

    # Copier un dossier avec vérification
    $(basename "$0") neutron-clone ./config/ /etc/app/ --to-vm -r --checksum

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

    if [[ $# -lt 3 ]]; then
        usage
        exit 1
    fi

    VM_NAME="$1"
    SOURCE="$2"
    DEST="$3"
    shift 3

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to-vm)
                TO_VM=true
                shift
                ;;
            --from-vm)
                TO_VM=false
                shift
                ;;
            --checksum)
                CHECKSUM=true
                shift
                ;;
            --preserve)
                PRESERVE=true
                shift
                ;;
            -r|--recursive)
                RECURSIVE=true
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

get_md5() {
    local file="$1"
    local is_remote="${2:-false}"
    local vm="${3:-}"

    if [[ "$is_remote" == true ]]; then
        local ip=$(get_vm_ip "$vm")
        ssh -o "BatchMode=yes" -o "StrictHostKeyChecking=no" -o "LogLevel=ERROR" \
            -p "$VM_SSH_PORT" "${SSH_USER}@${ip}" "md5sum '$file' 2>/dev/null" | awk '{print $1}'
    else
        md5sum "$file" 2>/dev/null | awk '{print $1}'
    fi
}

copy_to_vm() {
    local vm="$1"
    local src="$2"
    local dst="$3"

    local ip=$(get_vm_ip "$vm")

    if [[ -z "$ip" ]]; then
        log_error "Impossible d'obtenir l'IP de '$vm'"
        return 1
    fi

    # Vérifier que le source existe
    if [[ ! -e "$src" ]]; then
        log_error "Source non trouvée: $src"
        return 1
    fi

    log_step "Copie: $src -> $vm:$dst"
    log_info "IP: $ip"

    # Options SCP
    local scp_opts=(
        -o "BatchMode=yes"
        -o "StrictHostKeyChecking=no"
        -o "UserKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
        -P "$VM_SSH_PORT"
    )

    [[ "$PRESERVE" == true ]] && scp_opts+=("-p")
    [[ "$RECURSIVE" == true ]] && scp_opts+=("-r")

    # Copier
    if scp "${scp_opts[@]}" "$src" "${SSH_USER}@${ip}:${dst}"; then
        log_ok "Copie terminée"
    else
        log_error "Échec de la copie"
        return 1
    fi

    # Vérification checksum
    if [[ "$CHECKSUM" == true ]]; then
        log_step "Vérification checksum..."

        local src_file="$src"
        local dst_file="$dst"

        # Si c'est un dossier, on ne peut pas vérifier simplement
        if [[ -d "$src" ]]; then
            log_warn "Checksum non supporté pour les dossiers"
            return 0
        fi

        # Si dest est un dossier, construire le chemin complet
        if [[ "$dst" == */ ]]; then
            dst_file="${dst}$(basename "$src")"
        fi

        local src_md5=$(get_md5 "$src_file" false)
        local dst_md5=$(get_md5 "$dst_file" true "$vm")

        if [[ "$src_md5" == "$dst_md5" ]]; then
            log_ok "Checksum OK: $src_md5"
        else
            log_error "Checksum mismatch!"
            log_error "  Source: $src_md5"
            log_error "  Dest:   $dst_md5"
            return 1
        fi
    fi

    return 0
}

copy_from_vm() {
    local vm="$1"
    local src="$2"
    local dst="$3"

    local ip=$(get_vm_ip "$vm")

    if [[ -z "$ip" ]]; then
        log_error "Impossible d'obtenir l'IP de '$vm'"
        return 1
    fi

    log_step "Copie: $vm:$src -> $dst"
    log_info "IP: $ip"

    # Options SCP
    local scp_opts=(
        -o "BatchMode=yes"
        -o "StrictHostKeyChecking=no"
        -o "UserKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
        -P "$VM_SSH_PORT"
    )

    [[ "$PRESERVE" == true ]] && scp_opts+=("-p")
    [[ "$RECURSIVE" == true ]] && scp_opts+=("-r")

    # Créer le dossier destination si nécessaire
    if [[ "$dst" == */ ]] && [[ ! -d "$dst" ]]; then
        mkdir -p "$dst"
    fi

    # Copier
    if scp "${scp_opts[@]}" "${SSH_USER}@${ip}:${src}" "$dst"; then
        log_ok "Copie terminée"
    else
        log_error "Échec de la copie"
        return 1
    fi

    # Vérification checksum
    if [[ "$CHECKSUM" == true ]]; then
        log_step "Vérification checksum..."

        local dst_file="$dst"

        # Si dest est un dossier, construire le chemin complet
        if [[ -d "$dst" ]]; then
            dst_file="${dst}/$(basename "$src")"
        fi

        # Si c'est un dossier
        if [[ -d "$dst_file" ]]; then
            log_warn "Checksum non supporté pour les dossiers"
            return 0
        fi

        local src_md5=$(get_md5 "$src" true "$vm")
        local dst_md5=$(get_md5 "$dst_file" false)

        if [[ "$src_md5" == "$dst_md5" ]]; then
            log_ok "Checksum OK: $src_md5"
        else
            log_error "Checksum mismatch!"
            log_error "  Source: $src_md5"
            log_error "  Dest:   $dst_md5"
            return 1
        fi
    fi

    return 0
}

copy_file() {
    local vm="$1"

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

    if [[ "$TO_VM" == true ]]; then
        copy_to_vm "$vm" "$SOURCE" "$DEST"
    else
        copy_from_vm "$vm" "$SOURCE" "$DEST"
    fi

    return $?
}

main() {
    parse_args "$@"

    local result
    if copy_file "$VM_NAME"; then
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
