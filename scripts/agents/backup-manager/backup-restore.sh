#!/usr/bin/env bash
#
# backup-restore.sh - Restaurer des backups
#
# Usage: backup-restore.sh <type> <identifier> [OPTIONS]
#
# ATTENTION: Operations potentiellement destructives!
#
# Codes retour:
#   0 = Succes
#   1 = Erreur generale
#   5 = Echec verification
#   6 = Annule par utilisateur
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ==============================================
# Variables
# ==============================================

RESTORE_TYPE=""
IDENTIFIER=""
DRY_RUN=false
FORCE=false
PARTIAL_PATH=""
TARGET_DIR=""
SKIP_PRE_SNAPSHOT=false

# ==============================================
# Usage
# ==============================================

usage() {
    cat << EOF
Usage: $(basename "$0") <type> <identifier> [OPTIONS]

Restaurer un backup.

ATTENTION: Operation potentiellement destructive!

Types et identifiants:
    timeshift <snapshot-tag>     Restaurer snapshot Timeshift
    borg <archive> [--partial]   Restaurer archive Borg
    vm-snapshot <vm:snapshot>    Restaurer snapshot VM (format: vm-name:snap-name)
    manual <backup-path>         Restaurer backup manuel

Options:
    --dry-run              Simulation sans execution
    --force, -f            Pas de confirmation (DANGEREUX!)
    --partial=PATH         Restaurer uniquement ce chemin (borg)
    --target=DIR           Destination alternative (borg, manual)
    --skip-pre-snapshot    Ne pas creer snapshot avant restauration
    -h, --help             Afficher cette aide

Securite:
    - Par defaut, un snapshot est cree AVANT la restauration
    - Confirmation TOUJOURS requise sauf avec --force
    - Utilisez --dry-run pour tester d'abord

Exemples:
    $(basename "$0") timeshift "2024-01-15_03-00-01"
    $(basename "$0") borg backup-20240115 --target=/tmp/restore
    $(basename "$0") borg backup-20240115 --partial=home/user/Documents
    $(basename "$0") vm-snapshot preprod:before-update
    $(basename "$0") manual /backups/manual/project-20240115 --target=/home/user/project

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

    if [[ $# -lt 2 ]]; then
        log_error "Type et identifiant requis"
        usage
        exit 1
    fi

    RESTORE_TYPE="$1"
    IDENTIFIER="$2"
    shift 2

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
            --partial=*)
                PARTIAL_PATH="${1#*=}"
                shift
                ;;
            --target=*)
                TARGET_DIR="${1#*=}"
                shift
                ;;
            --skip-pre-snapshot)
                SKIP_PRE_SNAPSHOT=true
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

confirm_restore() {
    local type="$1"
    local identifier="$2"

    if [[ "$FORCE" == true ]]; then
        log_warn "Mode --force: pas de confirmation"
        return 0
    fi

    echo ""
    echo -e "${RED}================================================${NC}"
    echo -e "${RED}  ATTENTION: OPERATION DE RESTAURATION${NC}"
    echo -e "${RED}================================================${NC}"
    echo ""
    echo "Type:   $type"
    echo "Backup: $identifier"
    [[ -n "$TARGET_DIR" ]] && echo "Destination: $TARGET_DIR"
    [[ -n "$PARTIAL_PATH" ]] && echo "Chemin partiel: $PARTIAL_PATH"
    echo ""

    if [[ "${AUTO_PRE_RESTORE_SNAPSHOT:-true}" == "true" && "$SKIP_PRE_SNAPSHOT" != "true" ]]; then
        echo -e "${YELLOW}Un snapshot de securite sera cree avant la restauration.${NC}"
        echo ""
    fi

    echo -e "${RED}Cette operation peut ECRASER des donnees existantes!${NC}"
    echo ""

    if [[ ! -t 0 ]]; then
        log_warn "Mode non-interactif detecte: utiliser --force pour confirmer la restauration"
        return 6
    fi

    read -r -p "Etes-vous SUR de vouloir continuer? (tapez 'yes' pour confirmer): "

    if [[ "$REPLY" != "yes" ]]; then
        log_info "Restauration annulee par l'utilisateur"
        return 6
    fi

    return 0
}

# ==============================================
# Pre-restore Snapshot
# ==============================================

create_pre_restore_snapshot() {
    local type="$1"

    if [[ "${AUTO_PRE_RESTORE_SNAPSHOT:-true}" != "true" ]] || [[ "$SKIP_PRE_SNAPSHOT" == "true" ]]; then
        log_debug "Snapshot pre-restore desactive"
        return 0
    fi

    log_step "Creation snapshot de securite avant restauration..."

    case "$type" in
        timeshift|borg|manual)
            # Creer snapshot Timeshift si disponible
            if command -v timeshift &>/dev/null; then
                local comment="Pre-restore safety snapshot ($(date '+%Y-%m-%d %H:%M'))"
                if timeshift --create --comments "$comment" 2>/dev/null; then
                    log_ok "Snapshot Timeshift de securite cree"
                else
                    log_warn "Impossible de creer snapshot de securite (non bloquant)"
                fi
            else
                log_debug "Timeshift non disponible pour snapshot de securite"
            fi
            ;;
        vm-snapshot)
            # Pour VM, le snapshot est gere par virsh
            log_debug "Snapshot VM pre-restore gere separement"
            ;;
    esac
}

# ==============================================
# Restore Timeshift
# ==============================================

restore_timeshift() {
    log_backup "timeshift" "RESTORE" "Restauration: $IDENTIFIER"

    check_root
    if ! check_dependencies timeshift; then
        return 1
    fi

    # Verification backup existe
    _lyra_progress 1 3 "Pre-verification" 5 0 0
    if ! validate_backup "timeshift" "$IDENTIFIER"; then
        log_error "Snapshot non trouve: $IDENTIFIER"
        log_info "Snapshots disponibles:"
        timeshift --list 2>/dev/null | grep "^>" | head -10 || echo "  (aucun)"
        return 1
    fi

    # Confirmation
    if ! confirm_restore "timeshift" "$IDENTIFIER"; then
        return 6
    fi

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] timeshift --restore --snapshot \"$IDENTIFIER\" --yes"
        return 0
    fi

    # Snapshot de securite
    create_pre_restore_snapshot "timeshift"

    _lyra_progress 2 3 "Restauration" 50 0 0
    log_step "Demarrage restauration Timeshift..."
    log_warn "Le systeme peut necessiter un redemarrage apres la restauration"

    if timeshift --restore --snapshot "$IDENTIFIER" --yes; then
        _lyra_progress 3 3 "Post-verification" 90 0 0
        log_ok "Restauration Timeshift terminee"
        log_warn "Un redemarrage est recommande"
        _lyra_progress 3 3 "Post-verification" 100 0 0
        return 0
    else
        log_error "Echec restauration Timeshift"
        return 1
    fi
}

# ==============================================
# Restore Borg
# ==============================================

restore_borg() {
    log_backup "borg" "RESTORE" "Restauration: $IDENTIFIER"

    check_root
    if ! check_dependencies borg; then
        return 1
    fi

    # Verifier mount
    if ! check_borg_mount; then
        return 1
    fi

    # Charger passphrase (systemd-creds -> bw CLI -> legacy, cf. common.sh)
    if ! load_borg_passphrase 2>/dev/null || [[ -z "${BORG_PASSPHRASE:-}" ]]; then
        log_error "Passphrase Borg introuvable (voir load_borg_passphrase, common.sh)"
        return 1
    fi

    # Vérifier que le repo Borg est accessible avant toute opération
    if ! borg info "${BORG_REPO}" &>/dev/null; then
        log_error "Repo Borg inaccessible: ${BORG_REPO}"
        log_error "Verifier que le disque est monte et que la passphrase est correcte"
        return 1
    fi

    # Verification backup existe
    _lyra_progress 1 3 "Pre-verification" 5 0 0
    if ! validate_backup "borg" "$IDENTIFIER"; then
        log_error "Archive non trouvee: $IDENTIFIER"
        log_info "Archives disponibles:"
        borg list --short "$BORG_REPO" 2>/dev/null | tail -10 || echo "  (aucune)"
        return 1
    fi

    local dest="${TARGET_DIR:-/}"

    # Confirmation
    if ! confirm_restore "borg" "$IDENTIFIER"; then
        return 6
    fi

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Simulation extraction depuis ${BORG_REPO}::${IDENTIFIER}"
        local extract_args=""
        [[ -n "$PARTIAL_PATH" ]] && extract_args="$PARTIAL_PATH"

        borg extract --dry-run --list "${BORG_REPO}::${IDENTIFIER}" $extract_args 2>&1 | head -20
        log_info "[DRY-RUN] ... (tronque a 20 lignes)"
        return 0
    fi

    # Snapshot de securite
    create_pre_restore_snapshot "borg"

    _lyra_progress 2 3 "Restauration" 50 0 0
    log_step "Demarrage restauration Borg..."

    # Creer destination si necessaire
    mkdir -p "$dest" 2>/dev/null || true

    log_info "Extraction vers: $dest"
    [[ -n "$PARTIAL_PATH" ]] && log_info "Chemin partiel: $PARTIAL_PATH"

    local borg_rc=0
    (
        pushd "$dest" > /dev/null || { echo "[ERROR] Impossible d'acceder a: $dest" >&2; exit 1; }
        if [[ -n "$PARTIAL_PATH" ]]; then
            borg extract --verbose "${BORG_REPO}::${IDENTIFIER}" "$PARTIAL_PATH"
        else
            borg extract --verbose "${BORG_REPO}::${IDENTIFIER}"
        fi
        popd > /dev/null
    ) || borg_rc=$?

    if [[ $borg_rc -eq 0 ]]; then
        _lyra_progress 3 3 "Post-verification" 90 0 0
        log_ok "Restauration Borg terminee"
        log_info "Fichiers restaures dans: $dest"
        _lyra_progress 3 3 "Post-verification" 100 0 0
        return 0
    else
        log_error "Echec restauration Borg"
        return 1
    fi
}

# ==============================================
# Restore VM Snapshot
# ==============================================

restore_vm_snapshot() {
    # Parser format vm:snapshot
    local vm_name="${IDENTIFIER%%:*}"
    local snap_name="${IDENTIFIER##*:}"

    if [[ "$vm_name" == "$snap_name" ]] || [[ -z "$snap_name" ]]; then
        log_error "Format invalide. Utilisez: vm-name:snapshot-name"
        log_info "Exemple: preprod:before-update"
        return 1
    fi

    log_backup "vm" "RESTORE" "VM: $vm_name, Snapshot: $snap_name"

    if ! check_dependencies virsh; then
        return 1
    fi

    # Verification backup existe
    if ! validate_backup "vm" "$IDENTIFIER"; then
        log_error "Snapshot VM non trouve: $snap_name pour VM: $vm_name"
        log_info "Snapshots disponibles pour $vm_name:"
        virsh snapshot-list "$vm_name" --name 2>/dev/null | head -10 || echo "  (aucun)"
        return 1
    fi

    # Confirmation
    if ! confirm_restore "vm-snapshot" "$IDENTIFIER"; then
        return 6
    fi

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] virsh snapshot-revert \"$vm_name\" --snapshotname \"$snap_name\""
        return 0
    fi

    _lyra_progress 2 3 "Restauration" 50 0 0
    log_step "Restauration snapshot VM..."

    # Utiliser vm-snapshot.sh si disponible
    if check_external_script "$VM_SNAPSHOT_SCRIPT" "vm-snapshot.sh" 2>/dev/null; then
        if "$VM_SNAPSHOT_SCRIPT" "$vm_name" restore "$snap_name" -y 2>/dev/null; then
            _lyra_progress 3 3 "Post-verification" 100 0 0
            log_ok "Snapshot VM restaure: $vm_name -> $snap_name"
            return 0
        else
            log_warn "Echec via vm-snapshot.sh, tentative virsh direct..."
        fi
    fi

    # Fallback virsh direct
    if virsh snapshot-revert "$vm_name" --snapshotname "$snap_name"; then
        _lyra_progress 3 3 "Post-verification" 100 0 0
        log_ok "Snapshot VM restaure: $vm_name -> $snap_name"
        return 0
    else
        log_error "Echec restauration snapshot VM"
        return 1
    fi
}

# ==============================================
# Restore Manual
# ==============================================

restore_manual() {
    log_backup "manual" "RESTORE" "Restauration: $IDENTIFIER"

    # Verification source existe
    if [[ ! -d "$IDENTIFIER" ]]; then
        log_error "Backup non trouve: $IDENTIFIER"

        # Suggerer backups disponibles
        local manual_dir="${MANUAL_DEFAULT_DEST:-/backups/manual}"
        if [[ -d "$manual_dir" ]]; then
            log_info "Backups disponibles dans $manual_dir:"
            ls -1t "$manual_dir" 2>/dev/null | head -10 | sed 's/^/  - /' || echo "  (aucun)"
        fi
        return 1
    fi

    # Verification destination
    if [[ -z "$TARGET_DIR" ]]; then
        log_error "Destination requise (--target=PATH)"
        log_info "Exemple: --target=/home/user/restore"
        return 1
    fi

    if ! check_dependencies rsync; then
        return 1
    fi

    # Confirmation
    if ! confirm_restore "manual" "$IDENTIFIER"; then
        return 6
    fi

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] rsync -avz \"$IDENTIFIER/\" \"$TARGET_DIR/\""
        rsync -avz --dry-run "$IDENTIFIER/" "$TARGET_DIR/" 2>/dev/null | tail -10 || true
        return 0
    fi

    # Snapshot de securite
    _lyra_progress 1 3 "Pre-verification" 5 0 0
    create_pre_restore_snapshot "manual"

    _lyra_progress 2 3 "Restauration" 50 0 0
    log_step "Restauration backup manuel..."

    # Creer destination
    mkdir -p "$TARGET_DIR" 2>/dev/null || true

    log_info "Source: $IDENTIFIER"
    log_info "Destination: $TARGET_DIR"

    if rsync -avz --progress "$IDENTIFIER/" "$TARGET_DIR/"; then
        _lyra_progress 3 3 "Post-verification" 90 0 0
        log_ok "Restauration manuelle terminee"
        log_info "Fichiers restaures dans: $TARGET_DIR"
        _lyra_progress 3 3 "Post-verification" 100 0 0
        return 0
    else
        log_error "Echec restauration manuelle"
        return 1
    fi
}

# ==============================================
# Main
# ==============================================

main() {
    parse_args "$@"

    local result=0

    case "$RESTORE_TYPE" in
        timeshift)
            restore_timeshift
            result=$?
            ;;
        borg)
            restore_borg
            result=$?
            ;;
        vm-snapshot|vm)
            restore_vm_snapshot
            result=$?
            ;;
        manual)
            restore_manual
            result=$?
            ;;
        *)
            log_error "Type inconnu: $RESTORE_TYPE"
            log_info "Types valides: timeshift, borg, vm-snapshot, manual"
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
