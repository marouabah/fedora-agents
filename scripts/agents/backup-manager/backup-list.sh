#!/usr/bin/env bash
#
# backup-list.sh - Lister tous les backups disponibles
#
# Usage: backup-list.sh [OPTIONS]
#
# Codes retour:
#   0 = Succes
#   1 = Erreur
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ==============================================
# Variables
# ==============================================

SHOW_ALL=false
DETAILED=false
SORT_BY="date"
TYPE_FILTER=""
LIMIT=20

# ==============================================
# Usage
# ==============================================

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Lister tous les backups disponibles.

Options:
    --all, -a         Afficher tous les types avec details
    --type=TYPE       Filtrer par type (timeshift, borg, vm, manual)
    --detailed, -d    Afficher informations detaillees
    --limit=N         Limiter a N backups par type (defaut: 20)
    --sort=FIELD      Trier par: date, type, size (defaut: date)
    -h, --help        Afficher cette aide

Types disponibles:
    timeshift    Snapshots systeme Timeshift
    borg         Archives Borgbackup
    vm           Snapshots VM libvirt
    manual       Backups manuels rsync

Exemples:
    $(basename "$0")                    # Liste resume
    $(basename "$0") --all --detailed   # Liste complete
    $(basename "$0") --type=borg        # Uniquement Borg
    $(basename "$0") --type=vm          # Uniquement VM

EOF
    show_module_help "$(basename "$0")"
}

# ==============================================
# Parsing Arguments
# ==============================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all|-a)
                SHOW_ALL=true
                DETAILED=true
                shift
                ;;
            --type=*)
                TYPE_FILTER="${1#*=}"
                shift
                ;;
            --detailed|-d)
                DETAILED=true
                shift
                ;;
            --limit=*)
                LIMIT="${1#*=}"
                shift
                ;;
            --sort=*)
                SORT_BY="${1#*=}"
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

# ==============================================
# Fonctions d'affichage
# ==============================================

print_header() {
    echo ""
    echo -e "${BOLD}=======================================${NC}"
    echo -e "${BOLD}  Backup Manager - Liste des backups${NC}"
    echo -e "${BOLD}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BOLD}=======================================${NC}"
    echo ""
}

print_section() {
    local title="$1"
    local icon="$2"
    echo ""
    echo -e "${CYAN}--- ${icon} ${title} ---${NC}"
}

print_separator() {
    echo -e "${BLUE}----------------------------------------${NC}"
}

# ==============================================
# Liste Timeshift
# ==============================================

list_timeshift() {
    print_section "Timeshift Snapshots" "$ICON_TIMESHIFT"

    if ! command -v timeshift &>/dev/null; then
        echo "  Timeshift non installe"
        return 0
    fi

    # Parser la sortie de timeshift --list
    local output
    output=$(timeshift --list 2>/dev/null || true)

    # Compter snapshots (lignes commencant par >)
    local count
    count=$(echo "$output" | grep -c "^>" 2>/dev/null || true)
    count="${count:-0}"
    count="${count//[^0-9]/}"
    [[ -z "$count" ]] && count=0

    if [[ $count -eq 0 ]]; then
        echo "  Aucun snapshot"
    else
        echo ""
        if [[ "$DETAILED" == true ]]; then
            # Afficher header + snapshots
            echo "$output" | grep -E "^(Num|>)" | head -$((LIMIT + 1)) | while read -r line; do
                if [[ "$line" =~ ^Num ]]; then
                    echo -e "  ${BOLD}$line${NC}"
                else
                    echo "  $line"
                fi
            done
        else
            # Format compact
            echo "$output" | grep "^>" | head -"$LIMIT" | while read -r line; do
                local date tag
                date=$(echo "$line" | awk '{print $3, $4}')
                tag=$(echo "$line" | awk '{print $NF}')
                echo -e "  ${ICON_OK} $date - $tag"
            done
        fi
        echo ""
        echo -e "  ${GREEN}Total: $count snapshot(s)${NC}"
    fi

    if [[ "$DETAILED" == true ]]; then
        echo ""
        echo "  Espace: $(get_space_usage "$TIMESHIFT_BACKUP_DIR")"
    fi
}

# ==============================================
# Liste Borg
# ==============================================

list_borg() {
    print_section "Borgbackup Archives" "$ICON_BORG"

    if ! command -v borg &>/dev/null; then
        echo "  Borgbackup non installe"
        return 0
    fi

    # Verifier mount
    if ! mountpoint -q "${BORG_MOUNT_POINT:-/mnt/backup_cold}" 2>/dev/null; then
        echo "  Mount point non disponible: $BORG_MOUNT_POINT"
        return 0
    fi

    # Charger passphrase (systemd-creds -> bw CLI -> legacy, cf. common.sh)
    if ! load_borg_passphrase 2>/dev/null || [[ -z "${BORG_PASSPHRASE:-}" ]]; then
        echo "  Passphrase non configuree"
        return 0
    fi

    # Verifier repo existe
    if [[ ! -d "$BORG_REPO" ]]; then
        echo "  Repository non trouve: $BORG_REPO"
        return 0
    fi

    echo ""

    if [[ "$DETAILED" == true ]]; then
        # Affichage detaille avec tailles
        local output
        output=$(borg list --format '{archive:<40} {time:%Y-%m-%d %H:%M} {NEWLINE}' "$BORG_REPO" 2>/dev/null || true)

        if [[ -z "$output" ]]; then
            echo "  Aucune archive"
        else
            echo -e "  ${BOLD}Archive                                  Date${NC}"
            echo "  ---------------------------------------- ----------------"
            echo "$output" | head -"$LIMIT" | while read -r line; do
                [[ -n "$line" ]] && echo "  $ICON_OK $line"
            done

            local count
            count=$(echo "$output" | grep -c . || echo "0")
            echo ""
            echo -e "  ${GREEN}Total: $count archive(s)${NC}"
        fi

        # Info repo
        echo ""
        echo "  Repository info:"
        borg info "$BORG_REPO" 2>/dev/null | grep -E "^(Original|Compressed|Deduplicated)" | sed 's/^/    /' || true
    else
        # Affichage compact
        local archives
        archives=$(borg list --short "$BORG_REPO" 2>/dev/null || true)

        if [[ -z "$archives" ]]; then
            echo "  Aucune archive"
        else
            echo "$archives" | tail -"$LIMIT" | while read -r archive; do
                [[ -n "$archive" ]] && echo "  $ICON_OK $archive"
            done

            local count
            count=$(echo "$archives" | wc -l)
            echo ""
            echo -e "  ${GREEN}Total: $count archive(s)${NC}"
        fi
    fi

    if [[ "$DETAILED" == true ]]; then
        echo ""
        echo "  Espace: $(get_space_usage "$BORG_MOUNT_POINT")"
    fi
}

# ==============================================
# Liste VM Snapshots
# ==============================================

list_vm_snapshots() {
    print_section "VM Snapshots" "$ICON_VM"

    if ! command -v virsh &>/dev/null; then
        echo "  Libvirt non installe"
        return 0
    fi

    # Liste des VMs
    local vms
    vms=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)

    if [[ -z "$vms" ]]; then
        echo "  Aucune VM definie"
        return 0
    fi

    local total_snaps=0
    local vms_with_snaps=0

    echo ""

    while read -r vm; do
        if [[ -n "$vm" ]]; then
            local snaps
            snaps=$(virsh snapshot-list "$vm" --name 2>/dev/null | grep -v '^$' || true)
            local snap_count
            snap_count=$(echo "$snaps" | grep -c . 2>/dev/null || echo "0")

            if [[ $snap_count -gt 0 ]]; then
                ((vms_with_snaps++)) || true
                local vm_state
                vm_state=$(virsh domstate "$vm" 2>/dev/null || echo "unknown")

                echo -e "  ${BOLD}VM: $vm${NC} [$vm_state] ($snap_count snapshots)"

                if [[ "$DETAILED" == true ]]; then
                    echo "$snaps" | head -"$LIMIT" | while read -r snap; do
                        if [[ -n "$snap" ]]; then
                            local snap_date
                            snap_date=$(virsh snapshot-info "$vm" --snapshotname "$snap" 2>/dev/null | \
                                grep "Creation Time" | cut -d: -f2- | xargs || echo "?")
                            echo "    $ICON_OK $snap ($snap_date)"
                        fi
                    done
                else
                    echo "$snaps" | head -5 | while read -r snap; do
                        [[ -n "$snap" ]] && echo "    - $snap"
                    done
                    [[ $snap_count -gt 5 ]] && echo "    ... et $((snap_count - 5)) autres"
                fi

                ((total_snaps += snap_count)) || true
                echo ""
            fi
        fi
    done <<< "$vms"

    if [[ $total_snaps -eq 0 ]]; then
        echo "  Aucun snapshot VM"
    else
        echo -e "  ${GREEN}Total: $total_snaps snapshot(s) sur $vms_with_snaps VM(s)${NC}"
    fi
}

# ==============================================
# Liste Manuel
# ==============================================

list_manual() {
    print_section "Backups Manuels" "$ICON_MANUAL"

    local manual_dir="${MANUAL_DEFAULT_DEST:-/backups/manual}"

    if [[ ! -d "$manual_dir" ]]; then
        echo "  Repertoire non trouve: $manual_dir"
        return 0
    fi

    local backups
    backups=$(ls -1t "$manual_dir" 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        echo "  Aucun backup"
        return 0
    fi

    echo ""

    local count=0
    while read -r backup; do
        if [[ -n "$backup" && $count -lt $LIMIT ]]; then
            local size mtime
            size=$(du -sh "$manual_dir/$backup" 2>/dev/null | awk '{print $1}')
            mtime=$(stat -c %y "$manual_dir/$backup" 2>/dev/null | cut -d. -f1 || echo "?")

            if [[ "$DETAILED" == true ]]; then
                echo -e "  $ICON_OK ${BOLD}$backup${NC}"
                echo "       Taille: $size"
                echo "       Date:   $mtime"
            else
                echo "  $ICON_OK $backup ($size)"
            fi
            ((count++)) || true
        fi
    done <<< "$backups"

    local total
    total=$(echo "$backups" | grep -c . || echo "0")

    echo ""
    echo -e "  ${GREEN}Total: $total backup(s)${NC}"

    if [[ "$DETAILED" == true ]]; then
        echo ""
        echo "  Espace: $(get_space_usage "$manual_dir")"
    fi
}

# ==============================================
# Resume Espace
# ==============================================

print_space_summary() {
    echo ""
    echo -e "${CYAN}--- Resume Espace Disque ---${NC}"
    echo ""

    printf "  %-20s %s\n" "Timeshift:" "$(get_space_usage "$TIMESHIFT_BACKUP_DIR")"
    printf "  %-20s %s\n" "Borg:" "$(get_space_usage "$BORG_MOUNT_POINT")"
    printf "  %-20s %s\n" "Manuel:" "$(get_space_usage "${MANUAL_DEFAULT_DEST:-/backups/manual}")"
}

# ==============================================
# Main
# ==============================================

main() {
    parse_args "$@"

    print_header

    if [[ -n "$TYPE_FILTER" ]]; then
        # Type specifique
        case "$TYPE_FILTER" in
            timeshift)
                list_timeshift
                ;;
            borg)
                list_borg
                ;;
            vm|vm-snapshot)
                list_vm_snapshots
                ;;
            manual)
                list_manual
                ;;
            *)
                log_error "Type inconnu: $TYPE_FILTER"
                log_info "Types valides: timeshift, borg, vm, manual"
                exit 1
                ;;
        esac
    else
        # Tous les types
        list_timeshift
        list_borg
        list_vm_snapshots
        list_manual
    fi

    # Resume espace si mode all ou detailed
    if [[ "$SHOW_ALL" == true ]] || [[ "$DETAILED" == true ]]; then
        print_space_summary
    fi

    echo ""
}

# Permettre sourcing sans execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
