#!/usr/bin/env bash
#
# backup-status.sh - Dashboard global des backups
#
# Usage: backup-status.sh [OPTIONS]
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

WATCH_MODE=false
COMPACT_MODE=false

# ==============================================
# Usage
# ==============================================

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Affiche un dashboard global de l'etat des backups.

Options:
    --watch, -w    Mode surveillance (rafraichit toutes les 30s)
    --compact      Mode compact (moins de details)
    -h, --help     Afficher cette aide

Informations affichees:
    - Status de chaque systeme de backup
    - Dernier backup par type
    - Prochains backups planifies (timers systemd)
    - Utilisation espace disque
    - Alertes eventuelles

Exemples:
    $(basename "$0")           # Dashboard standard
    $(basename "$0") --watch   # Mode surveillance continu
    $(basename "$0") --compact # Version compacte

EOF
    show_module_help "$(basename "$0")"
}

# ==============================================
# Parsing Arguments
# ==============================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --watch|-w)
                WATCH_MODE=true
                shift
                ;;
            --compact)
                COMPACT_MODE=true
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
# Helpers
# ==============================================

get_timeshift_status() {
    if ! command -v timeshift &>/dev/null; then
        echo "not_installed"
        return
    fi

    local count
    count=$(timeshift --list 2>/dev/null | grep -c "^>" 2>/dev/null || true)
    count=${count:-0}
    count=$(echo "$count" | tr -d '[:space:]')

    local timer_active
    timer_active=$(systemctl is-active timeshift-backup.timer 2>/dev/null || echo "inactive")

    if [[ "$timer_active" == "active" && $count -gt 0 ]]; then
        echo "ok:$count"
    elif [[ "$timer_active" == "active" ]]; then
        echo "warning:timer_ok_no_snaps"
    else
        echo "error:timer_inactive"
    fi
}

get_borg_status() {
    if ! command -v borg &>/dev/null; then
        echo "not_installed"
        return
    fi

    if ! mountpoint -q "$BORG_MOUNT_POINT" 2>/dev/null; then
        echo "warning:not_mounted"
        return
    fi

    # Charger/générer passphrase automatiquement
    if ! load_borg_passphrase 2>/dev/null; then
        echo "error:passphrase_failed"
        return
    fi

    # Vérifier/initialiser le repo si nécessaire
    if [[ ! -d "$BORG_REPO" ]]; then
        if ! ensure_borg_repo 2>/dev/null; then
            echo "error:repo_init_failed"
            return
        fi
    fi

    local count
    count=$(borg list --short "$BORG_REPO" 2>/dev/null | wc -l || echo "0")
    count=$(echo "$count" | tr -d '[:space:]')
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    local timer_active
    timer_active=$(systemctl is-active borg-backup.timer 2>/dev/null || echo "inactive")

    if [[ "$timer_active" == "active" && $count -gt 0 ]]; then
        echo "ok:$count"
    elif [[ "$timer_active" == "active" ]]; then
        echo "warning:timer_ok_no_archives"
    else
        echo "error:timer_inactive"
    fi
}

get_vm_status() {
    if ! command -v virsh &>/dev/null; then
        echo "not_installed"
        return
    fi

    local vms
    vms=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)

    if [[ -z "$vms" ]]; then
        echo "warning:no_vms"
        return
    fi

    local total_snaps=0
    while read -r vm; do
        if [[ -n "$vm" ]]; then
            local count
            count=$(virsh snapshot-list "$vm" --name 2>/dev/null | grep -c . 2>/dev/null || echo "0")
            # Nettoyer et s'assurer que c'est un entier
            count=$(echo "$count" | tr -d '[:space:]' | head -1)
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
            ((total_snaps += count)) || true
        fi
    done <<< "$vms"

    if [[ $total_snaps -gt 0 ]]; then
        echo "ok:$total_snaps"
    else
        echo "warning:no_snapshots"
    fi
}

get_last_backup() {
    local type="$1"

    case "$type" in
        timeshift)
            local last
            last=$(timeshift --list 2>/dev/null | grep "^>" | head -1 | awk '{print $3, $4}' || echo "")
            echo "${last:-N/A}"
            ;;
        borg)
            # Charger passphrase automatiquement
            load_borg_passphrase 2>/dev/null || true
            local last
            last=$(borg list --last 1 --format '{archive} {time:%Y-%m-%d %H:%M}' "$BORG_REPO" 2>/dev/null | head -1 || echo "")
            echo "${last:-N/A}"
            ;;
    esac
}

get_next_scheduled() {
    local timer="$1"

    local next
    next=$(systemctl list-timers "$timer" --no-pager 2>/dev/null | grep "$timer" | awk '{print $1, $2, $3}' || echo "")

    if [[ -n "$next" ]]; then
        echo "$next"
    else
        echo "N/A"
    fi
}

status_icon() {
    local status="$1"

    case "$status" in
        ok*)          echo -e "${GREEN}[OK]${NC}" ;;
        warning*)     echo -e "${YELLOW}[!]${NC}" ;;
        error*)       echo -e "${RED}[X]${NC}" ;;
        not_installed) echo -e "${BLUE}[-]${NC}" ;;
        *)            echo -e "${BLUE}[?]${NC}" ;;
    esac
}

status_text() {
    local status="$1"

    case "$status" in
        ok:*)                    echo "${status#ok:} backup(s)" ;;
        warning:not_mounted)     echo "Non monte" ;;
        warning:no_snaps)        echo "Timer OK, pas de snapshots" ;;
        warning:no_archives)     echo "Timer OK, pas d'archives" ;;
        warning:no_vms)          echo "Aucune VM" ;;
        warning:no_snapshots)    echo "Aucun snapshot" ;;
        warning:*)               echo "${status#warning:}" ;;
        error:timer_inactive)    echo "Timer inactif" ;;
        error:no_passphrase)     echo "Passphrase manquante" ;;
        error:*)                 echo "${status#error:}" ;;
        not_installed)           echo "Non installe" ;;
        *)                       echo "$status" ;;
    esac
}

# ==============================================
# Dashboard
# ==============================================

print_dashboard() {
    # Clear si watch mode
    [[ "$WATCH_MODE" == true ]] && clear 2>/dev/null || true

    echo ""
    echo -e "${BOLD}+================================================================+${NC}"
    echo -e "${BOLD}|           BACKUP MANAGER - STATUS DASHBOARD                   |${NC}"
    echo -e "${BOLD}|           $(date '+%Y-%m-%d %H:%M:%S')                               |${NC}"
    echo -e "${BOLD}+================================================================+${NC}"
    echo ""

    # Obtenir status
    local ts_status borg_status vm_status
    ts_status=$(get_timeshift_status)
    borg_status=$(get_borg_status)
    vm_status=$(get_vm_status)

    # Section: Etat des systemes
    echo -e "${CYAN}+-- ETAT DES SYSTEMES --------------------------------------+${NC}"
    printf "| %-15s %s %-40s |\n" "Timeshift:" "$(status_icon "$ts_status")" "$(status_text "$ts_status")"
    printf "| %-15s %s %-40s |\n" "Borgbackup:" "$(status_icon "$borg_status")" "$(status_text "$borg_status")"
    printf "| %-15s %s %-40s |\n" "VM Snapshots:" "$(status_icon "$vm_status")" "$(status_text "$vm_status")"
    echo -e "${CYAN}+-----------------------------------------------------------+${NC}"
    echo ""

    if [[ "$COMPACT_MODE" != true ]]; then
        # Section: Derniers backups
        echo -e "${CYAN}+-- DERNIERS BACKUPS ---------------------------------------+${NC}"
        printf "| %-15s %-45s |\n" "Timeshift:" "$(get_last_backup timeshift)"
        printf "| %-15s %-45s |\n" "Borg:" "$(get_last_backup borg)"
        echo -e "${CYAN}+-----------------------------------------------------------+${NC}"
        echo ""

        # Section: Prochains backups
        echo -e "${CYAN}+-- PROCHAINS BACKUPS PLANIFIES ----------------------------+${NC}"
        printf "| %-15s %-45s |\n" "Timeshift:" "$(get_next_scheduled timeshift-backup.timer)"
        printf "| %-15s %-45s |\n" "Borg:" "$(get_next_scheduled borg-backup.timer)"
        echo -e "${CYAN}+-----------------------------------------------------------+${NC}"
        echo ""
    fi

    # Section: Espace disque
    echo -e "${CYAN}+-- ESPACE DISQUE ------------------------------------------+${NC}"
    printf "| %-15s %-45s |\n" "Timeshift:" "$(get_space_usage "$TIMESHIFT_BACKUP_DIR")"
    printf "| %-15s %-45s |\n" "Borg:" "$(get_space_usage "$BORG_MOUNT_POINT")"
    printf "| %-15s %-45s |\n" "Manuel:" "$(get_space_usage "${MANUAL_DEFAULT_DEST:-/backups/manual}")"
    echo -e "${CYAN}+-----------------------------------------------------------+${NC}"
    echo ""

    # Section: Alertes
    local alerts=()

    [[ "$ts_status" == error* ]] && alerts+=("Timeshift: $(status_text "$ts_status")")
    [[ "$borg_status" == error* ]] && alerts+=("Borg: $(status_text "$borg_status")")
    [[ "$borg_status" == *not_mounted* ]] && alerts+=("Borg: Mount point non monte")

    if [[ ${#alerts[@]} -gt 0 ]]; then
        echo -e "${RED}+-- ALERTES ------------------------------------------------+${NC}"
        for alert in "${alerts[@]}"; do
            printf "| ${RED}!${NC} %-57s |\n" "$alert"
        done
        echo -e "${RED}+-----------------------------------------------------------+${NC}"
    else
        echo -e "${GREEN}+-- ALERTES ------------------------------------------------+${NC}"
        printf "| ${GREEN}Aucune alerte${NC} %-45s |\n" ""
        echo -e "${GREEN}+-----------------------------------------------------------+${NC}"
    fi

    echo ""

    if [[ "$WATCH_MODE" == true ]]; then
        echo -e "${BLUE}Mode watch actif - Rafraichissement toutes les 30s - Ctrl+C pour quitter${NC}"
    fi
}

# ==============================================
# Watch Mode
# ==============================================

watch_dashboard() {
    log_info "Mode watch demarre (Ctrl+C pour quitter)"

    trap 'echo ""; log_info "Watch mode termine"; exit 0' INT TERM

    while true; do
        print_dashboard
        sleep 30
    done
}

# ==============================================
# Main
# ==============================================

main() {
    parse_args "$@"

    if [[ "$WATCH_MODE" == true ]]; then
        watch_dashboard
    else
        print_dashboard
    fi
}

# Permettre sourcing sans execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
