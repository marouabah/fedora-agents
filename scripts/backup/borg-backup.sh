#!/usr/bin/env bash
#
# borg-backup.sh - Backup complet avec Borgbackup
# Repository: /mnt/backup_cold (HDD 3To)
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
log_section() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

# Configuration
BORG_REPO="/mnt/backup_cold/borg"
BORG_KEY_BACKUP="/root/.borg-key-backup"
LOCK_FILE="/var/run/borg-backup.lock"
LOG_FILE="/var/log/borg-backup.log"

# Dossiers à sauvegarder
BACKUP_PATHS=(
    "/home"
    "/etc"
    "/root"
    "/var/log"
)

# Exclusions
EXCLUDES=(
    # Cache navigateurs et outils (pattern corrige : pas de \ avant le .)
    "*/.cache/*"
    "*/.mozilla/firefox/*/cache2/*"
    "*/.config/chromium/*/Cache/*"
    "*/.config/google-chrome/*/Cache/*"
    # Node.js
    "*/node_modules/*"
    # Python
    "*/.venv/*"
    "*/venv/*"
    "*/__pycache__/*"
    "*/.pyc"
    "*.pyo"
    # Temporaires
    "*/tmp/*"
    "*/.tmp/*"
    "*.tmp"
    "*.swp"
    "*~"
    # Logs volumineux (on garde /var/log mais pas les gros fichiers)
    "*/journal/*"
    # Log du backup lui-meme (grossit pendant le backup, feedback loop)
    "/var/log/borg-backup.log"
    # Logs temporaires guestfish (KVM operations, potentiellement enornes)
    "/var/log/libvirt/qemu/guestfs-*"
    # Divers
    "*/.local/share/Trash/*"
    "*/Downloads/*"
    "*/.thumbnails/*"
    "*/lost+found/*"
    # Steam (integralite : jeux + runtime + Proton + appcache, tout re-telechargeable)
    "*/.local/share/Steam/*"
    "*/.steam/*"
    # Containers locaux (podman/docker, re-pullables)
    "*/.local/share/containers/*"
    # Packages Python utilisateur (re-installables via pip)
    "*/.local/lib/python*/*"
    # Virtualenvs nommes autrement que .venv/venv (ex: venv-pipeline, env, etc.)
    "*/venv*/*"
    "*/env/lib/python*/*"
)

export BORG_REPO
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

# Tracking MCP (optionnel — visible dans le dashboard si l'API tourne)
_TRACKING_HELPER=""
for _candidate in \
    "$(dirname "${BASH_SOURCE[0]}")/../utils/tracking.sh" \
    "/usr/local/lib/mcp/tracking.sh"; do
    if [[ -f "$_candidate" ]]; then
        _TRACKING_HELPER="$_candidate"
        break
    fi
done
if [[ -n "$_TRACKING_HELPER" ]]; then
    source "$_TRACKING_HELPER" || true
fi
# Stubs no-op si le helper n'est pas disponible
command -v tracking_init     &>/dev/null || tracking_init()     { :; }
command -v tracking_progress &>/dev/null || tracking_progress() { :; }
command -v tracking_extra    &>/dev/null || tracking_extra()    { :; }
command -v tracking_log      &>/dev/null || tracking_log()      { :; }
command -v tracking_error    &>/dev/null || tracking_error()    { :; }
command -v tracking_done     &>/dev/null || tracking_done()     { :; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en root"
        exit 1
    fi
}

count_backup_files() {
    local find_args=()
    for pattern in "${EXCLUDES[@]}"; do
        find_args+=(-not -path "$pattern")
    done
    find "${BACKUP_PATHS[@]}" -type f "${find_args[@]}" 2>/dev/null | wc -l
}

load_passphrase() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # systemd-creds (mode service)
    if [[ -n "${CREDENTIALS_DIRECTORY:-}" ]] && [[ -f "${CREDENTIALS_DIRECTORY}/borg-passphrase" ]]; then
        export BORG_PASSPHRASE
        BORG_PASSPHRASE=$(cat "${CREDENTIALS_DIRECTORY}/borg-passphrase")
        return 0
    fi

    # bw CLI ou fallback legacy via get-borg-passphrase.sh
    if [[ -x "${script_dir}/get-borg-passphrase.sh" ]]; then
        export BORG_PASSPHRASE
        BORG_PASSPHRASE=$("${script_dir}/get-borg-passphrase.sh")
        return 0
    fi

    # Fallback legacy direct (deprecated)
    if [[ -f "/root/.borg-passphrase" ]]; then
        log_warn "DEPRECATED : lecture depuis /root/.borg-passphrase -- migrer vers Vaultwarden"
        export BORG_PASSPHRASE
        BORG_PASSPHRASE=$(cat /root/.borg-passphrase)
        return 0
    fi

    log_error "Passphrase Borg introuvable"
    exit 1
}

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_error "Un backup est déjà en cours (PID: $pid)"
            exit 1
        else
            log_warn "Lock file obsolète trouvé, suppression..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap '_on_exit' EXIT
    trap '_on_interrupt' INT TERM
}

_on_interrupt() {
    log_warn "Backup interrompu (signal recu)"
    tracking_error "Backup interrompu avant la fin"
    borg break-lock "$BORG_REPO" 2>/dev/null || true
    rm -f "$LOCK_FILE"
    exit 130
}

_on_exit() {
    rm -f "$LOCK_FILE"
}

check_repository() {
    log_info "Vérification du repository Borg..."

    if [[ ! -d "$BORG_REPO" ]]; then
        log_error "Repository non trouvé: $BORG_REPO"
        log_error "Exécutez d'abord: sudo $(dirname "$0")/setup-borg.sh"
        exit 1
    fi

    if ! borg info "$BORG_REPO" &>/dev/null; then
        log_error "Repository invalide ou passphrase incorrecte"
        exit 1
    fi

    log_info "Repository OK"
}

check_backup_mount() {
    local mount_point="/mnt/backup_cold"

    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        log_warn "$mount_point n'est pas monté"
        log_info "Tentative de montage automatique..."

        if mount "$mount_point" 2>/dev/null; then
            log_info "Montage réussi"
        else
            log_error "Impossible de monter $mount_point"
            log_error "Vérifiez /etc/fstab ou montez manuellement"
            exit 1
        fi
    fi
}

run_backup() {
    local total_files="${1:-0}"
    tracking_progress 0 "Backup Borg demarre — creation archive"
    tracking_extra "phase" "backup / en cours"
    log_section "Démarrage du backup"

    local archive_name="backup-$(hostname)-$(date +%Y-%m-%d_%H%M%S)"
    local exclude_args=()

    for pattern in "${EXCLUDES[@]}"; do
        exclude_args+=("--exclude" "$pattern")
    done

    log_info "Archive: $archive_name"
    log_info "Dossiers: ${BACKUP_PATHS[*]}"

    local start_time=$(date +%s)

    # Fichier temporaire pour capturer la sortie borg en temps reel
    local tmp_log tmp_count
    tmp_log=$(mktemp /tmp/borg-run.XXXXXX)
    tmp_count=$(mktemp /tmp/borg-count.XXXXXX)
    echo "0" > "$tmp_count"
    trap 'rm -f "$tmp_log" "$tmp_count"' RETURN

    # Lancer borg en arriere-plan
    borg create \
        --filter AME \
        --list \
        --stats \
        --show-rc \
        --compression zstd,3 \
        --exclude-caches \
        --exclude-if-present .nobackup \
        --exclude-if-present pyvenv.cfg \
        "${exclude_args[@]}" \
        "$BORG_REPO::$archive_name" \
        "${BACKUP_PATHS[@]}" \
        > "$tmp_log" 2>&1 &
    local borg_pid=$!

    # Parser la sortie en temps reel : compte les fichiers A/M/U et met a jour tracking
    (
        local nfiles=0
        local last_report=0
        tail -f "$tmp_log" 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                [AMU]\ *)
                    (( nfiles++ )) || true
                    echo "$nfiles" > "$tmp_count"
                    if (( nfiles - last_report >= 200 )); then
                        tracking_progress "$nfiles" "${nfiles}/${total_files} fichiers traites"
                        last_report=$nfiles
                    fi
                    ;;
            esac
        done
    ) &
    local parser_pid=$!

    # Attendre la fin de borg
    local backup_exit=0
    wait "$borg_pid" || backup_exit=$?

    # Arreter le parser et copier dans le vrai log
    kill "$parser_pid" 2>/dev/null || true
    wait "$parser_pid" 2>/dev/null || true
    cat "$tmp_log" >> "$LOG_FILE"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Extraire les stats finales et les remonter au tracking
    local orig_size nfiles_total
    orig_size=$(grep -oP 'This archive:\s+\K[0-9.]+ [A-Z]+' "$tmp_log" 2>/dev/null | head -1 || echo "?")
    nfiles_total=$(grep -oP 'Number of files: \K[0-9]+' "$tmp_log" 2>/dev/null | head -1 || echo "?")
    tracking_extra "stats" "taille: ${orig_size} | fichiers: ${nfiles_total}"

    if [[ $backup_exit -eq 0 ]]; then
        tracking_progress "$total_files" "Archive creee en ${duration}s (${nfiles_total} fichiers, ${orig_size})"
        log_info "Backup terminé en ${duration}s"
    elif [[ $backup_exit -eq 1 ]]; then
        tracking_progress "$total_files" "Archive creee avec warnings en ${duration}s"
        log_warn "Backup terminé avec warnings en ${duration}s"
    else
        tracking_error "Backup echoue (exit code: $backup_exit) apres ${duration}s"
        log_error "Backup échoué (exit code: $backup_exit)"
        return $backup_exit
    fi
}

prune_old_backups() {
    local total_files="${1:-0}"
    tracking_progress "$total_files" "Nettoyage des anciennes archives (prune)"
    log_section "Nettoyage des anciens backups"

    log_info "Politique de rétention:"
    log_info "  - 7 derniers quotidiens"
    log_info "  - 4 dernières semaines"
    log_info "  - 6 derniers mois"

    borg prune \
        --list \
        --show-rc \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 6 \
        "$BORG_REPO" \
        2>&1 | tee -a "$LOG_FILE"

    local prune_exit=${PIPESTATUS[0]}

    if [[ $prune_exit -eq 0 ]]; then
        log_info "Nettoyage terminé"
    else
        log_warn "Nettoyage terminé avec warnings"
    fi
}

compact_repository() {
    local total_files="${1:-0}"
    tracking_progress "$total_files" "Compactage du repository"
    log_section "Compactage du repository"

    borg compact "$BORG_REPO" 2>&1 | tee -a "$LOG_FILE"

    tracking_done "Backup Borg complet — archive + prune + compact termines"
    log_info "Compactage terminé"
}

show_info() {
    log_section "Informations repository"

    borg info "$BORG_REPO"

    echo ""
    log_info "Derniers backups:"
    borg list --last 5 "$BORG_REPO"
}

usage() {
    cat << EOF
Usage: $0 [COMMAND]

Commands:
    backup      Exécuter un backup complet (défaut)
    prune       Nettoyer les anciens backups
    compact     Compacter le repository
    info        Afficher les informations
    list        Lister tous les backups
    verify      Vérifier l'intégrité du dernier backup

Options:
    -h, --help  Afficher cette aide

Exemples:
    sudo $0                 # Backup complet + prune + compact
    sudo $0 backup          # Backup uniquement
    sudo $0 list            # Lister les archives
    sudo $0 verify          # Vérifier le dernier backup
EOF
}

cmd_list() {
    load_passphrase
    check_backup_mount
    borg list "$BORG_REPO"
}

cmd_verify() {
    load_passphrase
    check_backup_mount

    log_info "Vérification de l'intégrité du dernier backup..."

    local last_archive=$(borg list --last 1 --format '{archive}' "$BORG_REPO")

    if [[ -z "$last_archive" ]]; then
        log_error "Aucun backup trouvé"
        exit 1
    fi

    log_info "Vérification de: $last_archive"

    if borg check --verify-data "$BORG_REPO::$last_archive"; then
        log_info "Intégrité OK"
    else
        log_error "Problème d'intégrité détecté!"
        exit 1
    fi
}

main() {
    local cmd="${1:-backup}"

    case "$cmd" in
        -h|--help)
            usage
            exit 0
            ;;
        backup)
            check_root
            acquire_lock
            load_passphrase
            check_backup_mount
            check_repository
            # Compter les fichiers a sauvegarder pour un tracking precis
            log_info "Comptage des fichiers a sauvegarder..."
            local total_files
            total_files=$(count_backup_files)
            log_info "${total_files} fichiers a sauvegarder"
            tracking_init "Borg Backup - $(hostname)" "free" "$total_files" " fichiers"
            # Verifier et liberer l'espace avant le backup
            local _space_mgr
            _space_mgr="$(dirname "${BASH_SOURCE[0]}")/backup-space-manager.sh"
            if [[ -x "$_space_mgr" ]]; then
                "$_space_mgr" --borg
            fi
            run_backup "$total_files"
            prune_old_backups "$total_files"
            compact_repository "$total_files"
            show_info
            ;;
        prune)
            check_root
            load_passphrase
            check_backup_mount
            prune_old_backups
            ;;
        compact)
            check_root
            load_passphrase
            check_backup_mount
            compact_repository
            ;;
        info)
            load_passphrase
            check_backup_mount
            show_info
            ;;
        list)
            cmd_list
            ;;
        verify)
            check_root
            cmd_verify
            ;;
        *)
            log_error "Commande inconnue: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
