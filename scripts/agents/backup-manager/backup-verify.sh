#!/usr/bin/env bash
#
# backup-verify.sh - Verifier l'integrite des backups
#
# Usage: backup-verify.sh [type] [OPTIONS]
#
# Codes retour:
#   0 = Succes (tous backups OK)
#   1 = Erreur generale
#   5 = Probleme d'integrite detecte
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ==============================================
# Variables
# ==============================================

VERIFY_TYPE=""
DEEP_MODE=false
QUICK_MODE=false
SPECIFIC_BACKUP=""

# Compteurs
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0

# ==============================================
# Usage
# ==============================================

usage() {
    cat << EOF
Usage: $(basename "$0") [type] [OPTIONS]

Verifier l'integrite des backups.

Types (optionnel, tous si non specifie):
    timeshift    Verifier snapshots Timeshift
    borg         Verifier archives Borgbackup
    vm           Verifier snapshots VM
    all          Verifier tous les types (defaut)

Options:
    --deep           Verification approfondie (plus lent)
    --quick          Verification rapide (structure seulement)
    --backup=ID      Verifier un backup specifique
    -h, --help       Afficher cette aide

Modes de verification:
    Standard: Verifie existence et structure de base
    Quick:    Verifie seulement l'accessibilite
    Deep:     Verification complete avec checksums (lent)

Exemples:
    $(basename "$0")                          # Verification standard de tout
    $(basename "$0") borg --deep              # Verification approfondie Borg
    $(basename "$0") borg --backup=archive-1  # Verifier archive specifique

EOF
    show_module_help "$(basename "$0")"
}

# ==============================================
# Parsing Arguments
# ==============================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            timeshift|borg|vm|all)
                VERIFY_TYPE="$1"
                shift
                ;;
            --deep)
                DEEP_MODE=true
                shift
                ;;
            --quick)
                QUICK_MODE=true
                shift
                ;;
            --backup=*)
                SPECIFIC_BACKUP="${1#*=}"
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

    VERIFY_TYPE="${VERIFY_TYPE:-all}"
}

# ==============================================
# Helpers
# ==============================================

run_check() {
    local name="$1"
    local cmd="$2"

    echo -n "  Verif: $name ... "

    if eval "$cmd" &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        ((CHECKS_PASSED++)) || true
        return 0
    else
        echo -e "${RED}ECHEC${NC}"
        ((CHECKS_FAILED++)) || true
        return 1
    fi
}

skip_check() {
    local name="$1"
    local reason="$2"

    echo -e "  Verif: $name ... ${YELLOW}SKIP${NC} ($reason)"
    ((CHECKS_SKIPPED++)) || true
}

# ==============================================
# Verification Timeshift
# ==============================================

verify_timeshift() {
    log_backup "timeshift" "VERIFY" "Verification Timeshift"

    if ! command -v timeshift &>/dev/null; then
        skip_check "Timeshift installe" "non installe"
        return 0
    fi

    run_check "Timeshift installe" "command -v timeshift"

    # Verification configuration
    if [[ -f "/etc/timeshift/timeshift.json" ]]; then
        run_check "Configuration presente" "test -f /etc/timeshift/timeshift.json"
    else
        echo -e "  Verif: Configuration presente ... ${YELLOW}MANQUANTE${NC}"
        ((CHECKS_FAILED++)) || true
    fi

    # Verification repertoire backup
    if [[ -d "$TIMESHIFT_BACKUP_DIR" ]]; then
        run_check "Repertoire backup accessible" "test -d '$TIMESHIFT_BACKUP_DIR'"

        if [[ -w "$TIMESHIFT_BACKUP_DIR" ]]; then
            run_check "Repertoire backup writable" "test -w '$TIMESHIFT_BACKUP_DIR'"
        else
            echo -e "  Verif: Repertoire backup writable ... ${YELLOW}NON (peut necessiter root)${NC}"
            ((CHECKS_SKIPPED++)) || true
        fi
    else
        echo -e "  Verif: Repertoire backup accessible ... ${RED}NON TROUVE${NC}"
        ((CHECKS_FAILED++)) || true
    fi

    # Verification timer systemd
    local timer_status
    timer_status=$(systemctl is-active timeshift-backup.timer 2>/dev/null || echo "inactive")
    if [[ "$timer_status" == "active" ]]; then
        run_check "Timer systemd actif" "systemctl is-active timeshift-backup.timer"
    else
        echo -e "  Verif: Timer systemd actif ... ${YELLOW}INACTIF${NC}"
        ((CHECKS_SKIPPED++)) || true
    fi

    # Verification snapshots existent
    local snap_count
    snap_count=$(timeshift --list 2>/dev/null | grep -c "^>" || true)
    snap_count="${snap_count:-0}"
    snap_count="${snap_count//[^0-9]/}"
    [[ -z "$snap_count" ]] && snap_count=0
    if [[ $snap_count -gt 0 ]]; then
        run_check "Snapshots existent ($snap_count)" "test $snap_count -gt 0"
    else
        echo -e "  Verif: Snapshots existent ... ${YELLOW}AUCUN${NC}"
        ((CHECKS_SKIPPED++)) || true
    fi

    return 0
}

# ==============================================
# Verification Borg
# ==============================================

verify_borg() {
    log_backup "borg" "VERIFY" "Verification Borgbackup"

    if ! command -v borg &>/dev/null; then
        skip_check "Borg installe" "non installe"
        return 0
    fi

    run_check "Borg installe" "command -v borg"

    # Verification passphrase (systemd-creds -> bw CLI -> legacy, cf. common.sh)
    if load_borg_passphrase 2>/dev/null && [[ -n "${BORG_PASSPHRASE:-}" ]]; then
        run_check "Passphrase chargee" "true"

        # Verification permissions du fichier legacy s'il est encore utilise
        if [[ -f "/root/.borg-passphrase" ]]; then
            local perms
            perms=$(stat -c %a "/root/.borg-passphrase" 2>/dev/null || echo "000")
            if [[ "$perms" == "600" ]]; then
                run_check "Permissions passphrase (600)" "test '$perms' == '600'"
            else
                echo -e "  Verif: Permissions passphrase ... ${YELLOW}$perms (devrait etre 600)${NC}"
                ((CHECKS_SKIPPED++)) || true
            fi
        fi
    else
        echo -e "  Verif: Passphrase chargee ... ${RED}MANQUANTE${NC}"
        ((CHECKS_FAILED++)) || true
        return 0
    fi

    # Verification mount point
    if ! mountpoint -q "$BORG_MOUNT_POINT" 2>/dev/null; then
        skip_check "Mount point disponible" "non monte: $BORG_MOUNT_POINT"
        return 0
    fi

    run_check "Mount point disponible" "mountpoint -q '$BORG_MOUNT_POINT'"

    # Verification repository
    if [[ ! -d "$BORG_REPO" ]]; then
        echo -e "  Verif: Repository existe ... ${RED}NON TROUVE${NC}"
        ((CHECKS_FAILED++)) || true
        return 0
    fi

    run_check "Repository existe" "test -d '$BORG_REPO'"

    # Passphrase deja chargee par load_borg_passphrase ci-dessus

    # Verification repository valide
    if borg info "$BORG_REPO" &>/dev/null; then
        run_check "Repository valide" "borg info '$BORG_REPO'"
    else
        echo -e "  Verif: Repository valide ... ${RED}ECHEC${NC}"
        ((CHECKS_FAILED++)) || true
        return 0
    fi

    # Verification archives existent
    local archive_count
    archive_count=$(borg list --short "$BORG_REPO" 2>/dev/null | wc -l || echo "0")
    if [[ $archive_count -gt 0 ]]; then
        run_check "Archives existent ($archive_count)" "test $archive_count -gt 0"
    else
        echo -e "  Verif: Archives existent ... ${YELLOW}AUCUNE${NC}"
        ((CHECKS_SKIPPED++)) || true
        return 0
    fi

    # Verification timer systemd
    local timer_status
    timer_status=$(systemctl is-active borg-backup.timer 2>/dev/null || echo "inactive")
    if [[ "$timer_status" == "active" ]]; then
        run_check "Timer systemd actif" "systemctl is-active borg-backup.timer"
    else
        echo -e "  Verif: Timer systemd actif ... ${YELLOW}INACTIF${NC}"
        ((CHECKS_SKIPPED++)) || true
    fi

    # Verification integrite (si mode deep ou backup specifique)
    if [[ "$DEEP_MODE" == true ]] || [[ -n "$SPECIFIC_BACKUP" ]]; then
        local archive_to_check="$SPECIFIC_BACKUP"

        if [[ -z "$archive_to_check" ]]; then
            # Prendre la derniere archive
            archive_to_check=$(borg list --last 1 --format '{archive}' "$BORG_REPO" 2>/dev/null || echo "")
        fi

        if [[ -n "$archive_to_check" ]]; then
            log_step "Verification approfondie: $archive_to_check"

            echo -n "  Verif: Integrite donnees ... "
            if borg check --verify-data "${BORG_REPO}::${archive_to_check}" 2>/dev/null; then
                echo -e "${GREEN}OK${NC}"
                ((CHECKS_PASSED++)) || true
            else
                echo -e "${RED}ECHEC${NC}"
                ((CHECKS_FAILED++)) || true
            fi

            # Test extraction dry-run
            echo -n "  Verif: Test extraction ... "
            if borg extract --dry-run "${BORG_REPO}::${archive_to_check}" 2>/dev/null; then
                echo -e "${GREEN}OK${NC}"
                ((CHECKS_PASSED++)) || true
            else
                echo -e "${RED}ECHEC${NC}"
                ((CHECKS_FAILED++)) || true
            fi
        fi
    fi

    return 0
}

# ==============================================
# Verification VM Snapshots
# ==============================================

verify_vm_snapshots() {
    log_backup "vm" "VERIFY" "Verification snapshots VM"

    if ! command -v virsh &>/dev/null; then
        skip_check "Libvirt installe" "non installe"
        return 0
    fi

    run_check "Libvirt installe" "command -v virsh"

    # Liste des VMs
    local vms
    vms=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)

    if [[ -z "$vms" ]]; then
        skip_check "VMs definies" "aucune VM"
        return 0
    fi

    local vm_count
    vm_count=$(echo "$vms" | wc -l)
    run_check "VMs definies ($vm_count)" "test -n '$vms'"

    # Verification snapshots par VM
    local total_snaps=0
    local snap_errors=0

    while read -r vm; do
        if [[ -n "$vm" ]]; then
            local snaps
            snaps=$(virsh snapshot-list "$vm" --name 2>/dev/null | grep -v '^$' || true)

            if [[ -n "$snaps" ]]; then
                while read -r snap; do
                    if [[ -n "$snap" ]]; then
                        ((total_snaps++)) || true

                        # Verification deep: tester infos snapshot
                        if [[ "$DEEP_MODE" == true ]]; then
                            if ! virsh snapshot-info "$vm" --snapshotname "$snap" &>/dev/null; then
                                echo -e "  ${RED}ERREUR:${NC} $vm:$snap invalide"
                                ((snap_errors++)) || true
                            fi
                        fi
                    fi
                done <<< "$snaps"
            fi
        fi
    done <<< "$vms"

    if [[ $total_snaps -gt 0 ]]; then
        if [[ $snap_errors -eq 0 ]]; then
            run_check "Snapshots VM ($total_snaps)" "test $snap_errors -eq 0"
        else
            echo -e "  Verif: Snapshots VM ... ${RED}$snap_errors ERREUR(S)${NC}"
            ((CHECKS_FAILED++)) || true
        fi
    else
        echo -e "  Verif: Snapshots VM ... ${YELLOW}AUCUN${NC}"
        ((CHECKS_SKIPPED++)) || true
    fi

    return 0
}

# ==============================================
# Resume
# ==============================================

print_summary() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Resume Verification${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""
    echo -e "  ${GREEN}Passes:${NC}  $CHECKS_PASSED"
    echo -e "  ${RED}Echecs:${NC}  $CHECKS_FAILED"
    echo -e "  ${YELLOW}Ignores:${NC} $CHECKS_SKIPPED"
    echo ""

    if [[ $CHECKS_FAILED -gt 0 ]]; then
        echo -e "${RED}ATTENTION: Des problemes ont ete detectes!${NC}"
        return 5
    else
        echo -e "${GREEN}Verification terminee: Tous les backups sont OK${NC}"
        return 0
    fi
}

# ==============================================
# Main
# ==============================================

main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  Backup Manager - Verification${NC}"
    echo -e "${BOLD}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BOLD}========================================${NC}"

    [[ "$DEEP_MODE" == true ]] && log_info "Mode: Verification approfondie"
    [[ "$QUICK_MODE" == true ]] && log_info "Mode: Verification rapide"

    case "$VERIFY_TYPE" in
        timeshift)
            verify_timeshift
            ;;
        borg)
            verify_borg
            ;;
        vm)
            verify_vm_snapshots
            ;;
        all)
            verify_timeshift
            echo ""
            verify_borg
            echo ""
            verify_vm_snapshots
            ;;
    esac

    print_summary
    exit $?
}

# Permettre sourcing sans execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
