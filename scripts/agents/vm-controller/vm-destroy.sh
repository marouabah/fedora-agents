#!/usr/bin/env bash
#
# vm-destroy.sh - Supprime complètement une VM KVM (définition + stockage)
# Usage: vm-destroy.sh <vm-name> [OPTIONS]
#
# Retour:
#   0 = OK
#   1 = Erreur
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Options
FORCE=false
KEEP_STORAGE=false
YES=false

usage() {
    cat << EOF
Usage: $(basename "$0") <vm-name> [OPTIONS]

Supprime complètement une VM KVM (définition et stockage).

Options:
    --force         Ne pas demander de confirmation
    --keep-storage  Garder les fichiers disque (ne supprimer que la définition)
    --yes, -y       Confirmer automatiquement (pour scripts non-interactifs)
    -h, --help      Afficher cette aide

Attention:
    Cette opération est IRRÉVERSIBLE. La VM et tous ses disques seront supprimés.

Exemples:
    $(basename "$0") preprod --yes
    $(basename "$0") test-vm --keep-storage
    $(basename "$0") old-vm --force --yes

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
            --keep-storage)
                KEEP_STORAGE=true
                shift
                ;;
            --yes|-y)
                YES=true
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

confirm_destroy() {
    local vm="$1"

    if [[ "$YES" == true ]] || [[ "$FORCE" == true ]]; then
        return 0
    fi

    # Contexte non-interactif (MCP/daemon Lyra) : la confirmation humaine a
    # DEJA eu lieu cote Lyra (vm_destroy est dans DANGEROUS_TOOLS, jamais
    # auto-confirme). Sans ce garde, read echoue -> "Echec de la suppression".
    if [[ ! -t 0 ]]; then
        log_warn "Suppression DEFINITIVE de '$vm' (confirmation deja donnee en amont)"
        return 0
    fi

    echo ""
    log_warn "Vous allez SUPPRIMER DÉFINITIVEMENT la VM '$vm'"
    if [[ "$KEEP_STORAGE" != true ]]; then
        log_warn "Cela inclut TOUS les disques associés!"
    fi
    echo ""
    read -p "Êtes-vous sûr? (tapez 'yes' pour confirmer): " -r
    echo

    if [[ "$REPLY" != "yes" ]]; then
        log_info "Opération annulée"
        exit 0
    fi
}

destroy_vm() {
    local vm="$1"

    # Vérifier que la VM existe
    if ! check_vm "$vm"; then
        echo ""
        echo "VMs disponibles:"
        list_vms | sed 's/^/  - /'
        return 1
    fi

    # Demander confirmation
    confirm_destroy "$vm"

    # Arrêter la VM si elle tourne
    if is_vm_running "$vm"; then
        log_step "Arrêt de la VM: $vm"
        if ! $VIRSH destroy "$vm" &>/dev/null; then
            log_warn "Impossible d'arrêter la VM, tentative de suppression quand même..."
        else
            log_ok "VM arrêtée"
        fi
    fi

    # Vérifier si d'autres VMs utilisent le disque de cette VM comme backing file
    if [[ "$KEEP_STORAGE" != true ]]; then
        local disk_path
        disk_path=$($VIRSH domblklist "$vm" --details 2>/dev/null | awk '/file.*disk/{print $4}' | head -1 || true)
        if [[ -n "$disk_path" ]]; then
            local dependent_vms=()
            while IFS= read -r candidate_vm; do
                [[ -z "$candidate_vm" ]] && continue
                local candidate_disk
                candidate_disk=$($VIRSH domblklist "$candidate_vm" --details 2>/dev/null | awk '/file.*disk/{print $4}' | head -1 || true)
                if [[ -n "$candidate_disk" ]] && [[ -f "$candidate_disk" ]]; then
                    local backing
                    backing=$(qemu-img info --backing-chain "$candidate_disk" 2>/dev/null | grep "backing file:" | head -1 | awk '{print $NF}' || true)
                    if [[ "$backing" == "$disk_path" ]]; then
                        dependent_vms+=("$candidate_vm")
                    fi
                fi
            done < <($VIRSH list --all --name 2>/dev/null | grep -v "^$" | grep -v "^$vm$")

            if [[ ${#dependent_vms[@]} -gt 0 ]]; then
                log_error "Suppression bloquée: le disque '$disk_path' est utilisé comme backing file par:"
                for dep in "${dependent_vms[@]}"; do
                    log_error "  - $dep"
                done
                log_warn "Supprimez d'abord les clones liés, ou utilisez --keep-storage pour conserver le disque."
                return 1
            fi
        fi
    fi

    # Supprimer la VM
    log_step "Suppression de la VM: $vm"

    local undefine_opts=""
    if [[ "$KEEP_STORAGE" != true ]]; then
        undefine_opts="--remove-all-storage"
    fi

    # --snapshots-metadata : virsh refuse de supprimer un domaine ayant des
    # snapshots ("impossible de supprimer un domaine inactif avec N snapshots")
    undefine_opts="$undefine_opts --snapshots-metadata"

    # Essayer avec --nvram d'abord (pour les VMs UEFI)
    if $VIRSH undefine "$vm" $undefine_opts --nvram &>/dev/null; then
        log_ok "VM '$vm' supprimée avec succès"
        if [[ "$KEEP_STORAGE" != true ]]; then
            log_info "Stockage supprimé"
        fi
        return 0
    fi

    # Réessayer sans --nvram (pour les VMs BIOS legacy) — en capturant
    # l'erreur virsh pour la remonter (elle etait avalee par &>/dev/null)
    local virsh_err
    if virsh_err=$($VIRSH undefine "$vm" $undefine_opts 2>&1 >/dev/null); then
        log_ok "VM '$vm' supprimée avec succès"
        if [[ "$KEEP_STORAGE" != true ]]; then
            log_info "Stockage supprimé"
        fi
        return 0
    fi

    log_error "Échec de la suppression de la VM"
    [[ -n "${virsh_err:-}" ]] && log_error "$(echo "$virsh_err" | grep -m1 'error:' || echo "$virsh_err" | head -1)"
    return 1
}

main() {
    parse_args "$@"

    if destroy_vm "$VM_NAME"; then
        exit 0
    else
        exit 1
    fi
}

# Permettre le sourcing sans exécution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
