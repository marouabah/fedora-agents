#!/usr/bin/env bash
#
# vm-status.sh - Status et monitoring d'une VM KVM
# Usage: vm-status.sh <vm-name> [OPTIONS]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Options
DETAILED=false
WATCH_MODE=false
JSON_OUTPUT=false

usage() {
    cat << EOF
Usage: $(basename "$0") <vm-name> [OPTIONS]

Affiche le status et les informations d'une VM KVM.

Options:
    --detailed      Infos détaillées (CPU, RAM, disk)
    --watch         Mode watch (rafraîchit toutes les 2s)
    --json          Output en JSON
    -h, --help      Afficher cette aide

Exemples:
    $(basename "$0") neutron-clone
    $(basename "$0") neutron-clone --detailed
    $(basename "$0") neutron-clone --watch

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

    # Si pas d'argument, ou si le premier arg est une option, on listera toutes les VMs
    if [[ $# -lt 1 ]] || [[ "$1" == -* ]]; then
        VM_NAME=""
        # Ne pas shift si c'est une option, on la traite dans la boucle
        if [[ $# -lt 1 ]]; then
            return
        fi
    else
        VM_NAME="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --detailed|-d)
                DETAILED=true
                shift
                ;;
            --watch|-w)
                WATCH_MODE=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
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

short_state() {
    # "en cours d'execution" deborde des colonnes -> libelle court
    is_vm_running "$1" && echo "actif" || echo "$(get_vm_state "$1")"
}

get_vm_storage() {
    # Ou vit le disque de la VM et est-il utilisable ?
    # -> "local" | "externe" | "externe-ABSENT" | "ABSENT" | "-"
    local vm="$1"
    local disk
    disk=$($VIRSH domblklist "$vm" 2>/dev/null | awk 'NR>2 && $2 != "-" {print $2; exit}')
    [[ -z "$disk" ]] && { echo "-"; return; }
    if [[ "$disk" == /mnt/ext-backup/* ]]; then
        [[ -e "$disk" ]] && echo "externe" || echo "externe-ABSENT"
    else
        [[ -e "$disk" ]] && echo "local" || echo "ABSENT"
    fi
}

get_uptime() {
    local vm="$1"

    # Essayer de récupérer via virsh
    local start_time=$($VIRSH dominfo "$vm" 2>/dev/null | grep -i "cpu time" | awk '{print $3}')

    if [[ -n "$start_time" ]]; then
        # CPU time est en format X.Xs, pas vraiment l'uptime
        # On va essayer via les stats
        echo "N/A"
    else
        echo "N/A"
    fi
}

get_vcpus() {
    local vm="$1"
    # Support French (CPU :) and English (CPU(s):)
    $VIRSH dominfo "$vm" 2>/dev/null | grep -iE "^cpu[^a-z]" | head -1 | awk -F: '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}'
}

get_memory() {
    local vm="$1"
    # Support French (Mémoire Max :) and English (Max memory :)
    local mem_kb=$($VIRSH dominfo "$vm" 2>/dev/null | grep -iE "(max memory|mémoire max)" | awk '{print $(NF-1)}')
    if [[ -n "$mem_kb" ]]; then
        echo "$((mem_kb / 1024 / 1024))G"
    else
        echo "N/A"
    fi
}

get_disk_info() {
    local vm="$1"

    # Obtenir le disque principal
    local disk=$($VIRSH domblklist "$vm" --details 2>/dev/null | grep -E "file\s+disk" | head -1 | awk '{print $4}')

    if [[ -n "$disk" && -f "$disk" ]]; then
        local size=$(du -h "$disk" 2>/dev/null | awk '{print $1}')
        local virtual=$($SUDO qemu-img info "$disk" 2>/dev/null | grep "virtual size" | awk '{print $3}')
        echo "${size:-N/A} / ${virtual:-N/A}"
    else
        echo "N/A"
    fi
}

get_disk_path() {
    local vm="$1"
    $VIRSH domblklist "$vm" --details 2>/dev/null | grep -E "file\s+disk" | head -1 | awk '{print $4}' || true
}

get_backing_file() {
    local disk="$1"
    $SUDO qemu-img info "$disk" 2>/dev/null | grep "^backing file:" | awk -F': ' '{print $2}' || true
}

get_vm_type() {
    local vm="$1"
    local disk
    disk=$(get_disk_path "$vm")

    if [[ -n "$disk" && -f "$disk" ]]; then
        local backing
        backing=$(get_backing_file "$disk")
        if [[ -n "$backing" ]]; then
            echo "clone COW"
            return
        fi
    fi

    echo "VM standard"
}

# Retourne le nom de la VM parente d'un clone COW (celle dont le disque = backing file)
get_parent_vm() {
    local vm="$1"
    local all_vms="$2"  # liste separee par newlines
    local disk
    disk=$(get_disk_path "$vm")
    [[ -z "$disk" || ! -f "$disk" ]] && return

    local backing
    backing=$(get_backing_file "$disk")
    [[ -z "$backing" ]] && return

    while IFS= read -r candidate; do
        local candidate_disk
        candidate_disk=$(get_disk_path "$candidate")
        if [[ "$candidate_disk" == "$backing" ]]; then
            echo "$candidate"
            return
        fi
    done <<< "$all_vms"
}

get_cpu_usage() {
    local vm="$1"

    # Essayer via virsh domstats
    local cpu_time=$($VIRSH domstats "$vm" --cpu-total 2>/dev/null | grep "cpu.time" | awk -F'=' '{print $2}')

    if [[ -n "$cpu_time" ]]; then
        # Simplification: juste indiquer actif
        echo "actif"
    else
        echo "N/A"
    fi
}

get_memory_usage() {
    local vm="$1"

    # Via domstats
    local mem_actual=$($VIRSH domstats "$vm" --balloon 2>/dev/null | grep "balloon.current" | awk -F'=' '{print $2}')

    if [[ -n "$mem_actual" ]]; then
        echo "$((mem_actual / 1024 / 1024))G"
    else
        echo "N/A"
    fi
}

show_status() {
    local vm="$1"

    # Infos de base
    local state=$(get_vm_state "$vm")
    local ip=$(get_vm_ip "$vm" 2>/dev/null || echo "")
    local vm_type=$(get_vm_type "$vm")
    local storage=$(get_vm_storage "$vm")
    local ssh_status="N/A"

    # Check if VM is running (support French/English locale)
    if is_vm_running "$vm"; then
        if [[ -n "$ip" ]]; then
            if is_ssh_accessible "$vm" 2>/dev/null; then
                ssh_status="Accessible"
            else
                ssh_status="Non accessible"
            fi
        else
            ssh_status="Pas d'IP"
        fi
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        # Output JSON
        cat << EOF
{
  "vm": "$vm",
  "status": "$state",
  "type": "$vm_type",
  "storage": "$storage",
  "ip": "${ip:-null}",
  "ssh": "$ssh_status"
}
EOF
    else
        # Output texte
        echo ""
        echo "========================================"
        echo "  VM: $vm"
        echo "========================================"
        echo ""

        # Status avec couleur (support French/English)
        local status_color="$RED"
        is_vm_running "$vm" && status_color="$GREEN"

        echo -e "Status:  ${status_color}${state}${NC}"
        echo "Type:    ${vm_type}"
        case "$storage" in
            externe-ABSENT) echo -e "Disque:  ${RED}externe NON MONTE (/mnt/ext-backup) - VM indisponible${NC}" ;;
            ABSENT)         echo -e "Disque:  ${RED}INTROUVABLE - VM indisponible${NC}" ;;
            externe)        echo "Disque:  externe (/mnt/ext-backup, monte)" ;;
            *)              echo "Disque:  ${storage}" ;;
        esac
        if [[ "$vm_type" == "clone COW" ]]; then
            local all_vms
            all_vms=$($VIRSH list --all --name 2>/dev/null | grep -v '^$')
            local parent
            parent=$(get_parent_vm "$vm" "$all_vms")
            echo "Parent:  ${parent:-inconnu}"
        fi
        echo "IP:      ${ip:-Non assignée}"

        # SSH avec indicateur
        local ssh_icon="?"
        [[ "$ssh_status" == "Accessible" ]] && ssh_icon="OK"
        [[ "$ssh_status" == "Non accessible" ]] && ssh_icon="X"
        echo "SSH:     $ssh_icon $ssh_status"

        if [[ "$DETAILED" == true ]]; then
            # Infos statiques (disponibles même si VM éteinte)
            # Support French and English locale
            echo ""
            echo "--- Configuration ---"
            local uuid=$($VIRSH dominfo "$vm" 2>/dev/null | grep -i "uuid" | awk -F: '{print $2}' | tr -d ' ')
            local os_type=$($VIRSH dominfo "$vm" 2>/dev/null | grep -iE "(os type|type de se)" | awk -F: '{print $2}' | tr -d ' ')
            local persistent=$($VIRSH dominfo "$vm" 2>/dev/null | grep -iE "(^persistent|^persistant)" | awk -F: '{print $2}' | tr -d ' ')
            local autostart=$($VIRSH dominfo "$vm" 2>/dev/null | grep -iE "(^autostart[^a-z]|démarrage automatique)" | head -1 | awk -F: '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')

            echo "UUID:    ${uuid:-N/A}"
            echo "OS Type: ${os_type:-N/A}"
            echo "vCPUs:   $(get_vcpus "$vm")"
            echo "RAM:     $(get_memory "$vm")"
            echo "Disk:    $(get_disk_info "$vm")"
            echo "Persist: ${persistent:-N/A}"
            echo "Auto:    ${autostart:-N/A}"

            # Infos runtime (seulement si VM en cours d'exécution)
            if is_vm_running "$vm"; then
                echo ""
                echo "--- Runtime ---"
                echo "CPU:     $(get_cpu_usage "$vm")"
                echo "Mem use: $(get_memory_usage "$vm")"
            fi

            # Snapshots (toujours disponible)
            echo ""
            echo "--- Snapshots ---"
            local snap_count=$($VIRSH snapshot-list "$vm" --name 2>/dev/null | grep -v '^$' | wc -l)
            echo "Count:   $snap_count"
            if [[ $snap_count -gt 0 ]]; then
                $VIRSH snapshot-list "$vm" --name 2>/dev/null | grep -v '^$' | sed 's/^/  - /'
            fi
        fi

        echo ""

        if [[ -n "$ip" && "$ssh_status" == "Accessible" ]]; then
            echo "Connexion: ssh ${VM_SSH_USER}@${ip}"
        fi
    fi
}

watch_status() {
    local vm="$1"

    log_info "Mode watch - Ctrl+C pour quitter"
    echo ""

    while true; do
        clear
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Refresh: 2s"
        show_status "$vm"
        sleep 2
    done
}

vm_status() {
    local vm="$1"

    # Vérifier que la VM existe
    if ! check_vm "$vm"; then
        echo ""
        echo "VMs disponibles:"
        list_vms | sed 's/^/  - /'
        return 1
    fi

    if [[ "$WATCH_MODE" == true ]]; then
        watch_status "$vm"
    else
        show_status "$vm"
    fi

    return 0
}

list_all_vms() {
    echo ""
    echo "========================================"
    echo "  Liste des VMs"
    echo "========================================"
    echo ""

    local vms=$($VIRSH list --all --name 2>/dev/null | grep -v '^$')

    if [[ -z "$vms" ]]; then
        echo "Aucune VM trouvée."
        return 0
    fi

    # Construire la carte disque -> vm et les relations parent/enfant
    declare -A disk_to_vm
    declare -A vm_children

    while IFS= read -r vm; do
        local disk
        disk=$(get_disk_path "$vm")
        [[ -n "$disk" ]] && disk_to_vm["$disk"]="$vm"
    done <<< "$vms"

    # Identifier les clones COW et leur parent
    declare -A vm_parent
    while IFS= read -r vm; do
        local disk
        disk=$(get_disk_path "$vm")
        if [[ -n "$disk" && -f "$disk" ]]; then
            local backing
            backing=$(get_backing_file "$disk")
            if [[ -n "$backing" && -n "${disk_to_vm[$backing]+x}" ]]; then
                local parent="${disk_to_vm[$backing]}"
                vm_parent["$vm"]="$parent"
                vm_children["$parent"]+=" $vm"
            fi
        fi
    done <<< "$vms"

    printf "%-28s %-12s %-16s %-16s %s\n" "NOM" "ETAT" "STOCKAGE" "IP" "SSH"
    printf "%-28s %-12s %-16s %-16s %s\n" "---" "----" "--------" "--" "---"

    local printed=""

    # Afficher les templates (VMs qui ont des enfants) avec leurs clones en dessous
    while IFS= read -r vm; do
        [[ -z "${vm_children[$vm]+x}" ]] && continue
        local state=$(short_state "$vm")
        printf "%-28s %-12s %-16s %-16s %s\n" "[template] $vm" "$state" "$(get_vm_storage "$vm")" "-" "-"

        for child in ${vm_children[$vm]}; do
            local cstate=$(short_state "$child")
            local cip=$(get_vm_ip "$child" 2>/dev/null || echo "-")
            local cssh="-"
            if is_vm_running "$child" && [[ -n "$cip" && "$cip" != "-" ]]; then
                if is_ssh_accessible "$child" 2>/dev/null; then
                    cssh="OK"
                else
                    cssh="X"
                fi
            fi
            printf "%-28s %-12s %-16s %-16s %s\n" "  |-- $child" "$cstate" "$(get_vm_storage "$child")" "${cip:--}" "$cssh"
            printed+=" $child"
        done

        printed+=" $vm"
        echo ""
    done <<< "$vms"

    # Afficher les VMs standalone (ni template ni clone COW connu)
    local has_standalone=false
    while IFS= read -r vm; do
        [[ " $printed " == *" $vm "* ]] && continue
        if [[ "$has_standalone" == false ]]; then
            printf "%-28s %-12s %-16s %-16s %s\n" "[standalone]" "" "" "" ""
            has_standalone=true
        fi
        local state=$(short_state "$vm")
        local ip=$(get_vm_ip "$vm" 2>/dev/null || echo "-")
        local ssh="-"
        if is_vm_running "$vm" && [[ -n "$ip" && "$ip" != "-" ]]; then
            if is_ssh_accessible "$vm" 2>/dev/null; then
                ssh="OK"
            else
                ssh="X"
            fi
        fi
        printf "%-28s %-12s %-16s %-16s %s\n" "  $vm" "$state" "$(get_vm_storage "$vm")" "${ip:--}" "$ssh"
    done <<< "$vms"

    echo ""
}

main() {
    parse_args "$@"

    # Si pas de VM spécifiée, lister toutes les VMs
    if [[ -z "$VM_NAME" ]]; then
        list_all_vms
        exit 0
    fi

    local result
    if vm_status "$VM_NAME"; then
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
