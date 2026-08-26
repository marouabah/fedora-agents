#!/usr/bin/env bash
#
# test-restore.sh - Test de validation des backups
# Vérifie l'intégrité et teste la restauration des backups
#

set -euo pipefail

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_ok() { echo -e "${GREEN}[  OK  ]${NC} $1"; }
log_fail() { echo -e "${RED}[ FAIL ]${NC} $1"; }
log_section() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

# Configuration
BORG_REPO="/mnt/backup_cold/borg"
BORG_PASSPHRASE_FILE="/root/.borg-passphrase"
TEST_RESTORE_DIR="/tmp/backup-test-restore"
REPORT_FILE="/var/log/backup-test-report.log"

# Compteurs
TESTS_PASSED=0
TESTS_FAILED=0

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en root"
        exit 1
    fi
}

cleanup() {
    log_info "Nettoyage des fichiers temporaires..."
    rm -rf "$TEST_RESTORE_DIR"
}

trap cleanup EXIT

run_test() {
    local name="$1"
    local cmd="$2"

    if eval "$cmd" &>/dev/null; then
        log_ok "$name"
        ((TESTS_PASSED++))
        return 0
    else
        log_fail "$name"
        ((TESTS_FAILED++))
        return 1
    fi
}

# ============================================
# Tests Timeshift
# ============================================

test_timeshift() {
    log_section "Tests Timeshift"

    # Test 1: Timeshift installé
    run_test "Timeshift installé" "command -v timeshift"

    # Test 2: Configuration existe
    run_test "Configuration Timeshift" "test -f /etc/timeshift/timeshift.json"

    # Test 3: Timer actif
    run_test "Timer systemd actif" "systemctl is-active timeshift-backup.timer"

    # Test 4: Timer enabled
    run_test "Timer systemd enabled" "systemctl is-enabled timeshift-backup.timer"

    # Test 5: Au moins un snapshot existe
    local snapshot_count=$(timeshift --list 2>/dev/null | grep -c "^>" || echo "0")
    if [[ "$snapshot_count" -gt 0 ]]; then
        log_ok "Snapshots existants ($snapshot_count)"
        ((TESTS_PASSED++))
    else
        log_warn "Aucun snapshot Timeshift (normal si première installation)"
        # Ne pas compter comme échec
    fi

    # Test 6: Répertoire backup accessible
    run_test "Répertoire /backups/fast accessible" "test -d /backups/fast && test -w /backups/fast"
}

# ============================================
# Tests Borgbackup
# ============================================

test_borgbackup() {
    log_section "Tests Borgbackup"

    # Test 1: Borg installé
    run_test "Borgbackup installé" "command -v borg"

    # Test 2: Passphrase file existe
    run_test "Fichier passphrase" "test -f $BORG_PASSPHRASE_FILE"

    # Test 3: Permissions passphrase (600)
    if [[ -f "$BORG_PASSPHRASE_FILE" ]]; then
        local perms=$(stat -c %a "$BORG_PASSPHRASE_FILE")
        if [[ "$perms" == "600" ]]; then
            log_ok "Permissions passphrase (600)"
            ((TESTS_PASSED++))
        else
            log_fail "Permissions passphrase (actuelles: $perms, attendues: 600)"
            ((TESTS_FAILED++))
        fi
    fi

    # Test 4: Timer actif
    run_test "Timer systemd Borg actif" "systemctl is-active borg-backup.timer"

    # Test 5: Timer enabled
    run_test "Timer systemd Borg enabled" "systemctl is-enabled borg-backup.timer"

    # Vérifications nécessitant le mount
    if ! mountpoint -q /mnt/backup_cold 2>/dev/null; then
        log_warn "Mount point /mnt/backup_cold non disponible - tests repo skippés"
        return 0
    fi

    # Charger passphrase
    export BORG_PASSPHRASE=$(cat "$BORG_PASSPHRASE_FILE" 2>/dev/null || echo "")

    # Test 6: Repository existe et valide
    run_test "Repository Borg valide" "borg info $BORG_REPO"

    # Test 7: Au moins un backup existe
    local backup_count=$(borg list "$BORG_REPO" 2>/dev/null | wc -l || echo "0")
    if [[ "$backup_count" -gt 0 ]]; then
        log_ok "Backups existants ($backup_count)"
        ((TESTS_PASSED++))
    else
        log_warn "Aucun backup Borg (normal si première installation)"
    fi
}

# ============================================
# Test restauration Borg (dry-run)
# ============================================

test_borg_restore() {
    log_section "Test Restauration Borg"

    if ! mountpoint -q /mnt/backup_cold 2>/dev/null; then
        log_warn "Mount point non disponible - test restauration skippé"
        return 0
    fi

    export BORG_PASSPHRASE=$(cat "$BORG_PASSPHRASE_FILE" 2>/dev/null || echo "")

    # Obtenir le dernier backup
    local last_archive=$(borg list --last 1 --format '{archive}' "$BORG_REPO" 2>/dev/null || echo "")

    if [[ -z "$last_archive" ]]; then
        log_warn "Aucun backup disponible pour test"
        return 0
    fi

    log_info "Test restauration de: $last_archive"

    # Créer répertoire temporaire
    mkdir -p "$TEST_RESTORE_DIR"

    # Test 1: Vérifier intégrité
    log_info "Vérification intégrité (peut prendre du temps)..."
    if borg check --verify-data "$BORG_REPO::$last_archive" 2>/dev/null; then
        log_ok "Intégrité du backup vérifiée"
        ((TESTS_PASSED++))
    else
        log_fail "Problème d'intégrité détecté!"
        ((TESTS_FAILED++))
    fi

    # Test 2: Extraction partielle (test)
    log_info "Test extraction fichier..."
    if borg extract --dry-run "$BORG_REPO::$last_archive" etc/hostname 2>/dev/null; then
        log_ok "Extraction dry-run réussie"
        ((TESTS_PASSED++))
    else
        log_warn "Extraction dry-run échouée (fichier peut ne pas exister)"
    fi

    # Test 3: Lister le contenu
    local file_count=$(borg list "$BORG_REPO::$last_archive" 2>/dev/null | head -100 | wc -l)
    if [[ "$file_count" -gt 0 ]]; then
        log_ok "Archive lisible ($file_count+ fichiers)"
        ((TESTS_PASSED++))
    else
        log_fail "Impossible de lister l'archive"
        ((TESTS_FAILED++))
    fi
}

# ============================================
# Test services systemd
# ============================================

test_systemd_services() {
    log_section "Tests Services Systemd"

    # Timeshift
    run_test "Service timeshift-backup.service" "systemctl cat timeshift-backup.service"
    run_test "Timer timeshift-backup.timer" "systemctl cat timeshift-backup.timer"

    # Borg
    run_test "Service borg-backup.service" "systemctl cat borg-backup.service"
    run_test "Timer borg-backup.timer" "systemctl cat borg-backup.timer"

    # Afficher prochaines exécutions
    echo ""
    log_info "Prochaines exécutions planifiées:"
    systemctl list-timers timeshift-backup.timer borg-backup.timer --no-pager 2>/dev/null || true
}

# ============================================
# Génération rapport
# ============================================

generate_report() {
    log_section "Rapport de Test"

    local total=$((TESTS_PASSED + TESTS_FAILED))
    local date_str=$(date '+%Y-%m-%d %H:%M:%S')

    # Résumé console
    echo ""
    echo "============================================"
    echo "  RÉSULTAT: $TESTS_PASSED/$total tests passés"
    echo "============================================"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}Tous les tests sont passés!${NC}"
    else
        echo -e "${RED}$TESTS_FAILED test(s) échoué(s)${NC}"
        echo "Vérifiez les erreurs ci-dessus."
    fi

    # Sauvegarder rapport
    cat > "$REPORT_FILE" << EOF
==============================================
Rapport Test Backup - $date_str
==============================================

Résultat: $TESTS_PASSED/$total tests passés
Tests échoués: $TESTS_FAILED

Hostname: $(hostname)
Date: $date_str

Prochaines exécutions:
$(systemctl list-timers timeshift-backup.timer borg-backup.timer --no-pager 2>/dev/null || echo "N/A")

==============================================
EOF

    log_info "Rapport sauvegardé: $REPORT_FILE"
}

# ============================================
# Mode interactif de restauration
# ============================================

interactive_restore() {
    log_section "Restauration Interactive"

    echo "ATTENTION: Cette section est pour une vraie restauration."
    echo ""

    PS3="Choisir type de restauration: "
    options=("Timeshift - Restaurer système" "Borg - Lister backups" "Borg - Extraire fichiers" "Quitter")

    select opt in "${options[@]}"; do
        case $opt in
            "Timeshift - Restaurer système")
                echo ""
                log_warn "Lancement de Timeshift GUI/CLI..."
                echo "Commande: sudo timeshift --restore"
                read -p "Continuer? (y/N) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    timeshift --restore
                fi
                ;;
            "Borg - Lister backups")
                export BORG_PASSPHRASE=$(cat "$BORG_PASSPHRASE_FILE")
                echo ""
                borg list "$BORG_REPO"
                ;;
            "Borg - Extraire fichiers")
                export BORG_PASSPHRASE=$(cat "$BORG_PASSPHRASE_FILE")
                echo ""
                borg list "$BORG_REPO"
                echo ""
                read -p "Archive à restaurer: " archive
                read -p "Chemin à extraire (ex: home/user/Documents): " path
                read -p "Destination: " dest
                mkdir -p "$dest"
                cd "$dest"
                borg extract "$BORG_REPO::$archive" "$path"
                log_info "Extraction terminée dans: $dest"
                ;;
            "Quitter")
                break
                ;;
            *)
                echo "Option invalide"
                ;;
        esac
    done
}

usage() {
    cat << EOF
Usage: $0 [COMMAND]

Commands:
    test        Exécuter tous les tests (défaut)
    timeshift   Tester uniquement Timeshift
    borg        Tester uniquement Borgbackup
    restore     Mode restauration interactive
    report      Générer rapport uniquement

Options:
    -h, --help  Afficher cette aide

Exemples:
    sudo $0             # Tous les tests
    sudo $0 timeshift   # Tests Timeshift uniquement
    sudo $0 restore     # Mode restauration
EOF
}

main() {
    local cmd="${1:-test}"

    echo "============================================"
    echo "  Test Validation Backups"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================"

    case "$cmd" in
        -h|--help)
            usage
            exit 0
            ;;
        test)
            check_root
            test_timeshift
            test_borgbackup
            test_borg_restore
            test_systemd_services
            generate_report
            ;;
        timeshift)
            check_root
            test_timeshift
            generate_report
            ;;
        borg)
            check_root
            test_borgbackup
            test_borg_restore
            generate_report
            ;;
        restore)
            check_root
            interactive_restore
            ;;
        report)
            generate_report
            ;;
        *)
            log_error "Commande inconnue: $cmd"
            usage
            exit 1
            ;;
    esac

    # Exit code basé sur les tests
    [[ $TESTS_FAILED -eq 0 ]]
}

main "$@"
