#!/usr/bin/env bash
#
# backup-create.sh - Creer des backups (timeshift, borg, vm-snapshot, manual)
#
# Usage: backup-create.sh <type> [OPTIONS]
#
# Types: timeshift, borg, vm-snapshot, manual
#
# Codes retour:
#   0 = Succes
#   1 = Erreur generale
#   3 = Lock conflict
#   4 = Espace insuffisant
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ==============================================
# Variables
# ==============================================

BACKUP_TYPE=""
COMMENT=""
VERIFY_AFTER=false
NOTIFY_RESULT=false
DRY_RUN=false

# Options vm-snapshot
VM_NAME=""
VM_LIVE=false

# Options manual
MANUAL_SOURCE=""
MANUAL_DEST=""

# Options borg
BORG_EXTRA_ARGS=""

# ==============================================
# Usage
# ==============================================

usage() {
    cat << EOF
Usage: $(basename "$0") <type> [OPTIONS]

Creer un backup du type specifie.

Types:
    timeshift         Snapshot systeme rapide (Timeshift)
    borg              Backup complet chiffre (Borgbackup)
    vm-snapshot       Snapshot VM KVM (necessite --vm)
    manual            Backup rsync (necessite --source)

Options generales:
    --comment="X"     Commentaire/description du backup
    --verify          Verifier l'integrite apres creation
    --notify          Notifier du resultat
    --dry-run         Simulation sans execution
    -h, --help        Afficher cette aide

Options vm-snapshot:
    --vm=NAME         Nom de la VM (requis)
    --live            Snapshot a chaud avec etat memoire

Options manual:
    --source=PATH     Chemin source a sauvegarder (requis)
    --dest=PATH       Destination (defaut: $MANUAL_DEFAULT_DEST)

Exemples:
    $(basename "$0") timeshift --comment="Avant mise a jour"
    $(basename "$0") borg --verify --notify
    $(basename "$0") vm-snapshot --vm=preprod --comment="pre-deploy"
    $(basename "$0") manual --source=/home/user/projects --dest=/backup/projects

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
        log_error "Type de backup requis"
        usage
        exit 1
    fi

    BACKUP_TYPE="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --comment=*)
                COMMENT="${1#*=}"
                shift
                ;;
            --verify)
                VERIFY_AFTER=true
                shift
                ;;
            --notify)
                NOTIFY_RESULT=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --vm=*)
                VM_NAME="${1#*=}"
                shift
                ;;
            --live)
                VM_LIVE=true
                shift
                ;;
            --source=*)
                MANUAL_SOURCE="${1#*=}"
                shift
                ;;
            --dest=*)
                MANUAL_DEST="${1#*=}"
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
# Timeshift Backup
# ==============================================

create_timeshift() {
    log_backup "timeshift" "CREATE" "Demarrage snapshot Timeshift"

    # Verifications
    check_root
    if ! check_dependencies timeshift; then
        log_error "Timeshift non installe. Installez avec: sudo dnf install timeshift"
        return 1
    fi

    # Verifier espace
    if ! check_space "$TIMESHIFT_BACKUP_DIR" "$MIN_SPACE_TIMESHIFT"; then
        return 4
    fi

    # Acquerir lock
    if ! lock_backup "timeshift"; then
        return 3
    fi
    trap 'unlock_backup "timeshift"' EXIT

    local comment="${COMMENT:-Auto snapshot $(date '+%Y-%m-%d %H:%M')}"

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] timeshift --create --comments \"$comment\""
        return 0
    fi

    # Execution
    _lyra_progress 1 2 "Demarrage" 10 0 0
    local start_time
    start_time=$(date +%s)

    _lyra_progress 2 2 "Snapshot timeshift" 50 0 0
    if timeshift --create --comments "$comment"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        _lyra_progress 2 2 "Snapshot timeshift" 100 0 0
        log_ok "Snapshot Timeshift cree en $(format_duration $duration)"

        # Verification si demandee
        if [[ "$VERIFY_AFTER" == true ]]; then
            log_step "Verification du snapshot..."
            timeshift --list 2>/dev/null | head -5
        fi

        [[ "$NOTIFY_RESULT" == true ]] && notify "success" "Snapshot Timeshift cree: $comment"
        return 0
    else
        log_error "Echec creation snapshot Timeshift"
        [[ "$NOTIFY_RESULT" == true ]] && notify "error" "Echec snapshot Timeshift"
        return 1
    fi
}

# ==============================================
# Borg Backup
# ==============================================

create_borg() {
    log_backup "borg" "CREATE" "Demarrage backup Borg"

    # Verifications
    check_root
    if ! check_dependencies borg; then
        log_error "Borgbackup non installe. Installez avec: sudo dnf install borgbackup"
        return 1
    fi

    # Verifier mount point
    if ! check_borg_mount; then
        log_error "Mount point Borg non disponible"
        return 1
    fi

    # Verifier espace
    if ! check_space "$BORG_MOUNT_POINT" "$MIN_SPACE_BORG"; then
        return 4
    fi

    # Acquerir lock
    if ! lock_backup "borg"; then
        return 3
    fi
    trap 'unlock_backup "borg"' EXIT

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        if check_external_script "$BORG_BACKUP_SCRIPT" "borg-backup.sh"; then
            log_info "[DRY-RUN] $BORG_BACKUP_SCRIPT backup"
        else
            log_info "[DRY-RUN] borg create (script borg-backup.sh non trouve)"
            log_warn "Note: Le script borg-backup.sh devra etre cree (voir Prompt 5)"
        fi
        return 0
    fi

    _lyra_progress 1 2 "Preparation" 10 0 0
    local start_time
    start_time=$(date +%s)

    # Utiliser script existant si disponible
    if check_external_script "$BORG_BACKUP_SCRIPT" "borg-backup.sh"; then
        log_info "Utilisation de $BORG_BACKUP_SCRIPT"

        _lyra_progress 2 2 "Backup borg" 50 0 0
        if "$BORG_BACKUP_SCRIPT" backup; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))

            _lyra_progress 2 2 "Backup borg" 100 0 0
            log_ok "Backup Borg termine en $(format_duration $duration)"

            # Verification si demandee
            if [[ "$VERIFY_AFTER" == true ]]; then
                log_step "Verification du backup..."
                "$BORG_BACKUP_SCRIPT" verify || log_warn "Verification a echoue"
            fi

            [[ "$NOTIFY_RESULT" == true ]] && notify "success" "Backup Borg termine"
            return 0
        else
            log_error "Echec backup Borg"
            [[ "$NOTIFY_RESULT" == true ]] && notify "error" "Echec backup Borg"
            return 1
        fi
    else
        # Fallback: execution directe borg
        log_warn "Script borg-backup.sh non trouve, execution directe"
        log_warn "Note: Le script devra etre cree au Prompt 5"

        # Charger passphrase (systemd-creds -> bw CLI -> legacy, cf. common.sh)
        if ! load_borg_passphrase 2>/dev/null || [[ -z "${BORG_PASSPHRASE:-}" ]]; then
            log_error "Passphrase Borg introuvable (voir load_borg_passphrase, common.sh)"
            return 1
        fi
        export BORG_REPO

        local archive_name="backup-$(hostname)-$(date +%Y%m%d-%H%M%S)"
        local comment_arg=""
        [[ -n "$COMMENT" ]] && comment_arg="--comment=$COMMENT"

        _lyra_progress 2 2 "Backup borg" 50 0 0
        if borg create \
            --verbose \
            --stats \
            --compression zstd,3 \
            $comment_arg \
            "${BORG_REPO}::${archive_name}" \
            /home /etc /root /var/log \
            --exclude '*.cache' \
            --exclude '*/.cache/*' \
            --exclude '*/node_modules/*' \
            --exclude '*/__pycache__/*'; then

            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))

            _lyra_progress 2 2 "Backup borg" 100 0 0
            log_ok "Backup Borg cree: $archive_name ($(format_duration $duration))"

            [[ "$NOTIFY_RESULT" == true ]] && notify "success" "Backup Borg: $archive_name"
            return 0
        else
            log_error "Echec creation backup Borg"
            [[ "$NOTIFY_RESULT" == true ]] && notify "error" "Echec backup Borg"
            return 1
        fi
    fi
}

# ==============================================
# VM Snapshot
# ==============================================

create_vm_snapshot() {
    log_backup "vm" "CREATE" "Demarrage snapshot VM"

    # Verification VM specifiee
    if [[ -z "$VM_NAME" ]]; then
        log_error "Nom de VM requis (--vm=NAME)"
        log_info "VMs disponibles:"
        virsh list --all --name 2>/dev/null | grep -v '^$' | sed 's/^/  - /' || echo "  (aucune)"
        return 1
    fi

    # Verification virsh
    if ! check_dependencies virsh; then
        log_error "Libvirt non installe"
        return 1
    fi

    # Verification VM existe
    if ! virsh dominfo "$VM_NAME" &>/dev/null 2>&1; then
        log_error "VM non trouvee: $VM_NAME"
        log_info "VMs disponibles:"
        virsh list --all --name 2>/dev/null | grep -v '^$' | sed 's/^/  - /'
        return 1
    fi

    # Acquerir lock
    if ! lock_backup "vm-snapshot"; then
        return 3
    fi
    trap 'unlock_backup "vm-snapshot"' EXIT

    local snap_name="backup-$(date +%Y%m%d-%H%M%S)"
    local description="${COMMENT:-Auto snapshot by backup-manager}"

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        local cmd="virsh snapshot-create-as \"$VM_NAME\" \"$snap_name\" --description \"$description\""
        [[ "$VM_LIVE" == true ]] && cmd="$cmd --live"
        log_info "[DRY-RUN] $cmd"
        return 0
    fi

    _lyra_progress 1 2 "Preparation" 10 0 0
    local start_time
    start_time=$(date +%s)

    # Utiliser vm-snapshot.sh si disponible
    if check_external_script "$VM_SNAPSHOT_SCRIPT" "vm-snapshot.sh"; then
        log_info "Utilisation de $VM_SNAPSHOT_SCRIPT"

        local args=("$VM_NAME" "create" "$snap_name")
        [[ -n "$COMMENT" ]] && args+=("--description=$description")
        [[ "$VM_LIVE" == true ]] && args+=("--live")
        args+=("-y")  # Non-interactif

        _lyra_progress 2 2 "Snapshot VM" 50 0 0
        if "$VM_SNAPSHOT_SCRIPT" "${args[@]}"; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))

            _lyra_progress 2 2 "Snapshot VM" 100 0 0
            log_ok "Snapshot VM cree: $VM_NAME:$snap_name ($(format_duration $duration))"
            [[ "$NOTIFY_RESULT" == true ]] && notify "success" "Snapshot VM $VM_NAME cree"
            return 0
        else
            log_error "Echec snapshot VM via vm-snapshot.sh"
            [[ "$NOTIFY_RESULT" == true ]] && notify "error" "Echec snapshot VM $VM_NAME"
            return 1
        fi
    else
        # Fallback: virsh direct
        log_warn "Script vm-snapshot.sh non trouve, utilisation virsh direct"

        local virsh_cmd="virsh snapshot-create-as \"$VM_NAME\" \"$snap_name\" --description \"$description\""
        [[ "$VM_LIVE" == true ]] && virsh_cmd="$virsh_cmd --live"

        _lyra_progress 2 2 "Snapshot VM" 50 0 0
        if eval "$virsh_cmd"; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))

            _lyra_progress 2 2 "Snapshot VM" 100 0 0
            log_ok "Snapshot VM cree: $VM_NAME:$snap_name ($(format_duration $duration))"
            [[ "$NOTIFY_RESULT" == true ]] && notify "success" "Snapshot VM $VM_NAME cree"
            return 0
        else
            log_error "Echec creation snapshot VM"
            [[ "$NOTIFY_RESULT" == true ]] && notify "error" "Echec snapshot VM $VM_NAME"
            return 1
        fi
    fi
}

# ==============================================
# Manual Backup (rsync)
# ==============================================

create_manual() {
    log_backup "manual" "CREATE" "Demarrage backup manuel"

    # Verification source
    if [[ -z "$MANUAL_SOURCE" ]]; then
        log_error "Source requise (--source=PATH)"
        return 1
    fi

    if [[ ! -e "$MANUAL_SOURCE" ]]; then
        log_error "Source non trouvee: $MANUAL_SOURCE"
        return 1
    fi

    # Destination
    local dest="${MANUAL_DEST:-$MANUAL_DEFAULT_DEST}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local source_name
    source_name=$(basename "$MANUAL_SOURCE")
    local backup_dest="${dest}/${source_name}-${timestamp}"

    # Verification rsync
    if ! check_dependencies rsync; then
        log_error "rsync non installe"
        return 1
    fi

    # Verifier espace (sur parent si dest n'existe pas)
    local space_check_path="$dest"
    [[ ! -d "$dest" ]] && space_check_path="$(dirname "$dest")"
    if ! check_space "$space_check_path" "$MIN_SPACE_MANUAL"; then
        return 4
    fi

    # Acquerir lock
    if ! lock_backup "manual"; then
        return 3
    fi
    trap 'unlock_backup "manual"' EXIT

    # Creer repertoire destination
    mkdir -p "$dest" 2>/dev/null || true

    # Dry run
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] rsync $MANUAL_RSYNC_OPTS \"$MANUAL_SOURCE\" \"$backup_dest\""
        # Afficher stats
        rsync $MANUAL_RSYNC_OPTS --dry-run "$MANUAL_SOURCE" "$backup_dest" 2>/dev/null | tail -5 || true
        return 0
    fi

    log_info "Source: $MANUAL_SOURCE"
    log_info "Destination: $backup_dest"

    local start_time
    start_time=$(date +%s)

    # shellcheck disable=SC2086
    if rsync $MANUAL_RSYNC_OPTS "$MANUAL_SOURCE" "$backup_dest"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_ok "Backup manuel termine: $backup_dest ($(format_duration $duration))"

        # Verification si demandee
        if [[ "$VERIFY_AFTER" == true ]]; then
            log_step "Verification..."
            local src_size dst_size
            src_size=$(du -sh "$MANUAL_SOURCE" 2>/dev/null | awk '{print $1}')
            dst_size=$(du -sh "$backup_dest" 2>/dev/null | awk '{print $1}')
            log_info "Source: $src_size, Destination: $dst_size"
        fi

        [[ "$NOTIFY_RESULT" == true ]] && notify "success" "Backup manuel: $source_name"
        return 0
    else
        log_error "Echec backup manuel"
        [[ "$NOTIFY_RESULT" == true ]] && notify "error" "Echec backup manuel"
        return 1
    fi
}

# ==============================================
# Main
# ==============================================

main() {
    parse_args "$@"

    local result=0

    case "$BACKUP_TYPE" in
        timeshift)
            create_timeshift
            result=$?
            ;;
        borg)
            create_borg
            result=$?
            ;;
        vm-snapshot|vm)
            create_vm_snapshot
            result=$?
            ;;
        manual|rsync)
            create_manual
            result=$?
            ;;
        *)
            log_error "Type de backup inconnu: $BACKUP_TYPE"
            log_info "Types valides: timeshift, borg, vm-snapshot, manual"
            result=1
            ;;
    esac

    exit $result
}

# Permettre sourcing sans execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
