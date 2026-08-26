#!/usr/bin/env bash
#
# backup-clean.sh - Appliquer les politiques de retention et nettoyer
#
# Usage: backup-clean.sh <type> [OPTIONS]
#
# Codes retour:
#   0 = Succes
#   1 = Erreur generale
#   3 = Lock conflict
#   6 = Annule par utilisateur
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ==============================================
# Variables
# ==============================================

CLEAN_TYPE=""
DRY_RUN=false
FORCE=false
KEEP_LAST=0

# ==============================================
# Usage
# ==============================================

usage() {
    cat << EOF
Usage: $(basename "$0") <type> [OPTIONS]

Appliquer les politiques de retention et nettoyer les anciens backups.

Types:
    timeshift    Nettoyer snapshots Timeshift (via timeshift)
    borg         Nettoyer archives Borg (prune + compact)
    vm           Afficher snapshots VM (nettoyage manuel)
    manual       Nettoyer backups manuels
    all          Nettoyer tous les types

Options:
    --dry-run        Simulation sans suppression
    --force, -f      Pas de confirmation
    --keep-last=N    Garder au minimum N backups (manual)
    -h, --help       Afficher cette aide

Politique de retention par defaut:
    Timeshift: $RETENTION_TIMESHIFT_DAILY daily, $RETENTION_TIMESHIFT_WEEKLY weekly
    Borg:      $RETENTION_BORG_DAILY daily, $RETENTION_BORG_WEEKLY weekly, $RETENTION_BORG_MONTHLY monthly
    VM:        Nettoyage manuel uniquement
    Manual:    Garder les 10 derniers (ou --keep-last=N)

Exemples:
    $(basename "$0") borg --dry-run         # Voir ce qui serait supprime
    $(basename "$0") manual --keep-last=5   # Garder 5 derniers manuels
    $(basename "$0") all --dry-run          # Simulation complete

EOF
    show_module_help "$(basename "$0")"
}

# ==============================================
# Parsing Arguments
# ==============================================

parse_args() {
    # Verifier aide en premier
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                usage
                exit 0
                ;;
        esac
    done

    if [[ $# -lt 1 ]]; then
        log_error "Type requis"
        usage
        exit 1
    fi

    CLEAN_TYPE="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force|-f)
                FORCE=true
                shift
                ;;
            --keep-last=*)
                KEEP_LAST="${1#*=}"
                shift
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
# Confirmation
# ==============================================

confirm_cleanup() {
    local type="$1"
    local count="$2"

    if [[ "$FORCE" == true ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_warn "Mode non-interactif detecte: utiliser --force pour confirmer la suppression"
        return 6
    fi

    echo ""
    log_warn "Cette operation va supprimer des backups $type"
    echo "Elements a supprimer: $count"
    echo ""

    read -r -p "Continuer? (y/N) " -n 1
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Annule par l'utilisateur"
        return 6
    fi

    return 0
}

# ==============================================
# Clean Timeshift
# ==============================================

clean_timeshift() {
    log_backup "timeshift" "CLEAN" "Nettoyage Timeshift"

    if ! command -v timeshift &>/dev/null; then
        log_warn "Timeshift non installe"
        return 0
    fi

    # Timeshift gere sa propre retention via sa configuration
    # On affiche juste le status

    log_info "Timeshift gere automatiquement sa retention"
    log_info "Configuration: /etc/timeshift/timeshift.json"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Affichage des snapshots actuels:"
    fi

    # Afficher snapshots actuels
    local output
    output=$(timeshift --list 2>/dev/null || true)
    local count
    count=$(echo "$output" | grep -c "^>" || echo "0")

    echo "$output" | grep -E "^(Num|>)" | head -15 || true

    echo ""
    log_info "Total: $count snapshot(s)"
    log_info "La retention est appliquee automatiquement selon la config Timeshift"

    return 0
}

# ==============================================
# Clean Borg
# ==============================================

clean_borg() {
    log_backup "borg" "CLEAN" "Nettoyage Borg"

    if ! command -v borg &>/dev/null; then
        log_warn "Borgbackup non installe"
        return 0
    fi

    check_root

    # Verifier mount
    if ! check_borg_mount; then
        log_error "Mount point non disponible"
        return 1
    fi

    # Charger passphrase (systemd-creds -> bw CLI -> legacy, cf. common.sh)
    if ! load_borg_passphrase 2>/dev/null || [[ -z "${BORG_PASSPHRASE:-}" ]]; then
        log_error "Passphrase non configuree"
        return 1
    fi

    # Verifier repo
    if [[ ! -d "$BORG_REPO" ]]; then
        log_error "Repository non trouve: $BORG_REPO"
        return 1
    fi

    local keep_daily="${RETENTION_BORG_DAILY:-7}"
    local keep_weekly="${RETENTION_BORG_WEEKLY:-4}"
    local keep_monthly="${RETENTION_BORG_MONTHLY:-6}"

    log_info "Politique de retention:"
    echo "  - Daily:   $keep_daily"
    echo "  - Weekly:  $keep_weekly"
    echo "  - Monthly: $keep_monthly"
    echo ""

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Simulation prune..."
        echo ""

        borg prune --list --dry-run \
            --keep-daily "$keep_daily" \
            --keep-weekly "$keep_weekly" \
            --keep-monthly "$keep_monthly" \
            "$BORG_REPO" 2>&1 || true

        return 0
    fi

    # Acquerir lock
    if ! lock_backup "borg"; then
        return 3
    fi
    trap 'unlock_backup "borg"' EXIT

    # Compter avant
    local before_count
    before_count=$(borg list --short "$BORG_REPO" 2>/dev/null | wc -l || echo "0")

    log_step "Prune des archives..."

    borg prune --list --show-rc \
        --keep-daily "$keep_daily" \
        --keep-weekly "$keep_weekly" \
        --keep-monthly "$keep_monthly" \
        "$BORG_REPO"

    # Compter apres
    local after_count
    after_count=$(borg list --short "$BORG_REPO" 2>/dev/null | wc -l || echo "0")
    local deleted=$((before_count - after_count))

    log_info "Archives supprimees: $deleted"

    log_step "Compactage repository..."

    borg compact "$BORG_REPO"

    log_ok "Nettoyage Borg termine"

    # Afficher etat final
    echo ""
    log_info "Archives restantes: $after_count"
    borg list --short "$BORG_REPO" 2>/dev/null | tail -5 || true

    return 0
}

# ==============================================
# Clean VM Snapshots
# ==============================================

clean_vm_snapshots() {
    log_backup "vm" "CLEAN" "Nettoyage snapshots VM"

    if ! command -v virsh &>/dev/null; then
        log_warn "Libvirt non installe"
        return 0
    fi

    local vms
    vms=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)

    if [[ -z "$vms" ]]; then
        log_info "Aucune VM definie"
        return 0
    fi

    log_info "Snapshots VM par machine:"
    echo ""

    local total_snaps=0

    while read -r vm; do
        if [[ -n "$vm" ]]; then
            local snaps
            snaps=$(virsh snapshot-list "$vm" --name 2>/dev/null | grep -v '^$' || true)
            local count
            count=$(echo "$snaps" | grep -c . 2>/dev/null || echo "0")

            if [[ $count -gt 0 ]]; then
                echo -e "  ${BOLD}$vm${NC}: $count snapshot(s)"
                echo "$snaps" | head -5 | while read -r snap; do
                    [[ -n "$snap" ]] && echo "    - $snap"
                done
                [[ $count -gt 5 ]] && echo "    ... et $((count - 5)) autres"
                echo ""
                ((total_snaps += count)) || true
            fi
        fi
    done <<< "$vms"

    if [[ $total_snaps -eq 0 ]]; then
        log_info "Aucun snapshot VM"
    else
        log_info "Total: $total_snaps snapshot(s)"
        echo ""
        log_warn "Nettoyage VM snapshots: MANUEL uniquement"
        log_info "Pour supprimer un snapshot:"
        echo "  virsh snapshot-delete <vm-name> <snapshot-name>"
        echo ""
        log_info "Ou via vm-controller:"
        echo "  $VM_SNAPSHOT_SCRIPT <vm-name> delete <snapshot-name>"
    fi

    return 0
}

# ==============================================
# Clean Manual
# ==============================================

clean_manual() {
    log_backup "manual" "CLEAN" "Nettoyage backups manuels"

    local manual_dir="${MANUAL_DEFAULT_DEST:-/backups/manual}"

    if [[ ! -d "$manual_dir" ]]; then
        log_warn "Repertoire manuel non trouve: $manual_dir"
        return 0
    fi

    local backups
    backups=$(ls -1t "$manual_dir" 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        log_info "Aucun backup manuel"
        return 0
    fi

    local keep="${KEEP_LAST:-10}"
    local count
    count=$(echo "$backups" | grep -c . || echo "0")

    log_info "Backups manuels: $count"
    log_info "Politique: Garder les $keep derniers"

    if [[ $count -le $keep ]]; then
        log_info "Rien a supprimer ($count <= $keep)"
        return 0
    fi

    local to_delete=$((count - keep))
    local delete_list
    delete_list=$(echo "$backups" | tail -n "$to_delete")

    echo ""
    log_info "Backups a supprimer ($to_delete):"
    echo "$delete_list" | while read -r backup; do
        if [[ -n "$backup" ]]; then
            local size
            size=$(du -sh "$manual_dir/$backup" 2>/dev/null | awk '{print $1}')
            echo "  - $backup ($size)"
        fi
    done

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        log_info "[DRY-RUN] $to_delete backup(s) seraient supprimes"
        return 0
    fi

    # Confirmation
    if ! confirm_cleanup "manual" "$to_delete"; then
        return 6
    fi

    # Acquerir lock
    if ! lock_backup "manual"; then
        return 3
    fi
    trap 'unlock_backup "manual"' EXIT

    # Suppression
    local deleted=0
    echo "$delete_list" | while read -r backup; do
        if [[ -n "$backup" ]]; then
            log_info "Suppression: $backup"
            if rm -rf "${manual_dir:?}/$backup"; then
                ((deleted++)) || true
            else
                log_error "Echec suppression: $backup"
            fi
        fi
    done

    log_ok "$to_delete backup(s) manuel(s) supprime(s)"

    return 0
}

# ==============================================
# Main
# ==============================================

main() {
    parse_args "$@"

    local result=0

    case "$CLEAN_TYPE" in
        timeshift)
            clean_timeshift
            result=$?
            ;;
        borg)
            clean_borg
            result=$?
            ;;
        vm|vm-snapshot)
            clean_vm_snapshots
            result=$?
            ;;
        manual)
            clean_manual
            result=$?
            ;;
        all)
            clean_timeshift || result=$?
            echo ""
            clean_borg || result=$?
            echo ""
            clean_vm_snapshots || result=$?
            echo ""
            clean_manual || result=$?
            ;;
        *)
            log_error "Type inconnu: $CLEAN_TYPE"
            log_info "Types valides: timeshift, borg, vm, manual, all"
            usage
            result=1
            ;;
    esac

    exit $result
}

# Permettre sourcing sans execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
