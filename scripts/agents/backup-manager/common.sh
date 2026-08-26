#!/usr/bin/env bash
#
# common.sh - Fonctions communes pour le Backup Manager Agent
# Source ce fichier dans tous les scripts backup-manager
#
# Usage: source "${SCRIPT_DIR}/common.sh"
#

# ==============================================
# Guard contre multiple sourcing
# ==============================================
[[ -n "${_BACKUP_MANAGER_COMMON_LOADED:-}" ]] && return 0
_BACKUP_MANAGER_COMMON_LOADED=1

# ==============================================
# Configuration
# ==============================================

BACKUP_MANAGER_VERSION="1.0.0"
BACKUP_MANAGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${BACKUP_MANAGER_DIR}/../../.." && pwd)"

# Charger la config locale si elle existe
[[ -f "${PROJECT_ROOT}/scripts/config.env" ]] && source "${PROJECT_ROOT}/scripts/config.env"

# Variables avec defaults (permettent surcharge via config.env)
MCP_LOG_DIR="${MCP_LOG_DIR:-/var/log/mcp-agents}"
VM_SSH_USER="${VM_SSH_USER:-${SUDO_USER:-$USER}}"

# Fichier de configuration utilisateur
BACKUP_CONFIG_FILE="${BACKUP_CONFIG_FILE:-${HOME}/.config/backup-manager/config}"

# Repertoires
BACKUP_LOG_DIR="${BACKUP_LOG_DIR:-/var/log/backup-manager}"
LOCK_DIR="${LOCK_DIR:-/tmp/backup-manager-locks}"

# Paths vers scripts existants (defauts)
BORG_BACKUP_SCRIPT="${BACKUP_MANAGER_DIR}/../../backup/borg-backup.sh"
VM_SNAPSHOT_SCRIPT="${BACKUP_MANAGER_DIR}/../vm-controller/vm-snapshot.sh"
TEST_RESTORE_SCRIPT="${BACKUP_MANAGER_DIR}/../../backup/test-restore.sh"

# Configuration Borg (defauts)
BORG_REPO="${BORG_REPO:-/mnt/backup_cold/borg}"
BORG_MOUNT_POINT="${BORG_MOUNT_POINT:-/mnt/backup_cold}"
# Chemin vers le script de recuperation de passphrase
_GET_PASSPHRASE_SCRIPT="${PROJECT_ROOT}/scripts/backup/get-borg-passphrase.sh"

# Configuration Timeshift (defauts)
TIMESHIFT_BACKUP_DIR="${TIMESHIFT_BACKUP_DIR:-/backups/fast}"

# Configuration Manuel (defauts)
MANUAL_DEFAULT_DEST="${MANUAL_DEFAULT_DEST:-/backups/manual}"
MANUAL_RSYNC_OPTS="${MANUAL_RSYNC_OPTS:--avz --progress}"

# Retention (defauts)
RETENTION_TIMESHIFT_DAILY="${RETENTION_TIMESHIFT_DAILY:-7}"
RETENTION_TIMESHIFT_WEEKLY="${RETENTION_TIMESHIFT_WEEKLY:-4}"
RETENTION_BORG_DAILY="${RETENTION_BORG_DAILY:-7}"
RETENTION_BORG_WEEKLY="${RETENTION_BORG_WEEKLY:-4}"
RETENTION_BORG_MONTHLY="${RETENTION_BORG_MONTHLY:-6}"

# Seuils espace (en GB)
MIN_SPACE_BORG="${MIN_SPACE_BORG:-10}"
MIN_SPACE_TIMESHIFT="${MIN_SPACE_TIMESHIFT:-5}"
MIN_SPACE_MANUAL="${MIN_SPACE_MANUAL:-2}"

# Options
AUTO_PRE_RESTORE_SNAPSHOT="${AUTO_PRE_RESTORE_SNAPSHOT:-true}"
NOTIFY_METHOD="${NOTIFY_METHOD:-console}"
VERBOSE="${VERBOSE:-false}"

# Charger config utilisateur si existe
if [[ -f "$BACKUP_CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$BACKUP_CONFIG_FILE"
fi

# ==============================================
# Couleurs et Indicateurs
# ==============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Indicateurs pour affichage
ICON_OK="[OK]"
ICON_WARN="[!]"
ICON_ERROR="[X]"
ICON_TIMESHIFT="[TS]"
ICON_BORG="[BG]"
ICON_VM="[VM]"
ICON_MANUAL="[MN]"

# ==============================================
# Fonctions de Logging
# ==============================================

_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

_log_to_file() {
    local level="$1"
    local msg="$2"
    local script_name="${BASH_SOURCE[2]:-backup-manager}"
    script_name=$(basename "$script_name" .sh)

    # Creer repertoire si possible
    if [[ -w "/var/log" ]] || [[ -d "$BACKUP_LOG_DIR" && -w "$BACKUP_LOG_DIR" ]]; then
        mkdir -p "$BACKUP_LOG_DIR" 2>/dev/null || true
        local log_file="$BACKUP_LOG_DIR/$(date +%Y%m%d).log"
        echo "[$(_timestamp)] [$level] $script_name: $msg" >> "$log_file" 2>/dev/null || true
    fi
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    _log_to_file "INFO" "$1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    _log_to_file "WARN" "$1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    _log_to_file "ERROR" "$1"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
    _log_to_file "STEP" "$1"
}

log_ok() {
    echo -e "${GREEN}[OK]${NC}   $1"
    _log_to_file "OK" "$1"
}

log_debug() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
        _log_to_file "DEBUG" "$1"
    fi
}

# Log specialise backup avec type et action
log_backup() {
    local type="$1"
    local action="$2"
    local message="$3"
    local icon=""

    case "$type" in
        timeshift) icon="$ICON_TIMESHIFT" ;;
        borg)      icon="$ICON_BORG" ;;
        vm)        icon="$ICON_VM" ;;
        manual)    icon="$ICON_MANUAL" ;;
        *)         icon="[??]" ;;
    esac

    echo -e "${MAGENTA}${icon}${NC} ${CYAN}[$action]${NC} $message"
    _log_to_file "BACKUP" "$type:$action: $message"
}

# ==============================================
# Verification Espace Disque
# ==============================================

# Verifie l'espace disponible
# Usage: check_space <path> <min_gb>
# Return: 0 si OK, 4 si insuffisant, 1 si path inaccessible
check_space() {
    local path="$1"
    local min_gb="${2:-5}"

    if [[ ! -d "$path" ]]; then
        log_debug "Chemin non accessible: $path"
        return 1
    fi

    local available_kb
    available_kb=$(df -k "$path" 2>/dev/null | tail -1 | awk '{print $4}')
    local available_gb=$((available_kb / 1024 / 1024))

    log_debug "Espace disponible dans $path: ${available_gb}GB (minimum: ${min_gb}GB)"

    if [[ $available_gb -lt $min_gb ]]; then
        log_error "Espace insuffisant dans $path: ${available_gb}GB < ${min_gb}GB requis"
        return 4
    fi

    return 0
}

# Obtient resume utilisation espace
# Usage: get_space_usage <path>
get_space_usage() {
    local path="$1"

    if [[ ! -d "$path" ]]; then
        echo "N/A"
        return
    fi

    local used total percent
    local df_out
    df_out=$(df -h "$path" 2>/dev/null | tail -1)
    used=$(echo "$df_out" | awk '{print $3}' || echo "?")
    total=$(echo "$df_out" | awk '{print $2}' || echo "?")
    percent=$(echo "$df_out" | awk '{print $5}' || echo "?")

    echo "${used} / ${total} (${percent})"
}

# ==============================================
# Notifications
# ==============================================

# Envoie une notification
# Usage: notify <level> <message> [title]
notify() {
    local level="$1"
    local message="$2"
    local title="${3:-Backup Manager}"

    case "${NOTIFY_METHOD:-console}" in
        console)
            case "$level" in
                info)    log_info "$message" ;;
                warn)    log_warn "$message" ;;
                error)   log_error "$message" ;;
                success) log_ok "$message" ;;
            esac
            ;;
        desktop)
            local urgency="normal"
            [[ "$level" == "error" ]] && urgency="critical"
            notify-send -u "$urgency" "$title" "$message" 2>/dev/null || true
            # Fallback console
            log_info "[$level] $message"
            ;;
        *)
            log_info "[$level] $message"
            ;;
    esac
}

# ==============================================
# Gestion des Locks
# ==============================================

# Acquiert un lock pour eviter operations concurrentes
# Usage: lock_backup <type>
# Return: 0 si OK, 3 si conflit
lock_backup() {
    local type="$1"
    local lock_file="${LOCK_DIR}/${type}.lock"

    # Creer repertoire locks
    mkdir -p "$LOCK_DIR" 2>/dev/null || true

    # Verifier lock existant
    if [[ -f "$lock_file" ]]; then
        local pid
        pid=$(cat "$lock_file" 2>/dev/null || echo "")

        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "Operation $type deja en cours (PID: $pid)"
            return 3
        else
            log_warn "Lock file obsolete trouve, suppression..."
            rm -f "$lock_file"
        fi
    fi

    # Creer lock
    echo $$ > "$lock_file"
    log_debug "Lock acquis pour $type (PID: $$)"
    return 0
}

# Libere un lock
# Usage: unlock_backup <type>
unlock_backup() {
    local type="$1"
    local lock_file="${LOCK_DIR}/${type}.lock"

    rm -f "$lock_file" 2>/dev/null || true
    log_debug "Lock libere pour $type"
}

# ==============================================
# Validation Backups
# ==============================================

# Valide qu'un backup existe
# Usage: validate_backup <type> <identifier>
# Return: 0 si existe, 1 sinon
validate_backup() {
    local type="$1"
    local identifier="$2"

    case "$type" in
        timeshift)
            if ! command -v timeshift &>/dev/null; then
                return 1
            fi
            if ! timeshift --list 2>/dev/null | grep -q "$identifier"; then
                return 1
            fi
            ;;
        borg)
            if ! command -v borg &>/dev/null; then
                return 1
            fi
            # Charger passphrase automatiquement
            load_borg_passphrase || return 1
            if ! borg info "${BORG_REPO}::${identifier}" &>/dev/null; then
                return 1
            fi
            ;;
        vm)
            if ! command -v virsh &>/dev/null; then
                return 1
            fi
            local vm_name="${identifier%%:*}"
            local snap_name="${identifier##*:}"
            if ! virsh snapshot-info "$vm_name" --snapshotname "$snap_name" &>/dev/null 2>&1; then
                return 1
            fi
            ;;
        manual)
            if [[ ! -d "$identifier" ]]; then
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac

    return 0
}

# ==============================================
# Gestion Passphrase Borg (Auto)
# ==============================================

# Vérifie que borg est disponible (optionnel: avertit sans bloquer)
check_borg_available() {
    check_optional_dep "borg" "sudo dnf install borgbackup" || return 1
    return 0
}

# Vérifie que bw (Bitwarden CLI) est disponible (optionnel)
check_bw_available() {
    check_optional_dep "bw" "https://bitwarden.com/help/cli/" || return 1
    return 0
}

# Charge la passphrase Borg dans l'environnement
# Ordre de priorite : systemd-creds -> $BORG_PASSPHRASE -> bw CLI -> legacy /root/.borg-passphrase
# Usage: load_borg_passphrase
# Return: 0 si OK, 1 si echec
load_borg_passphrase() {
    # systemd-creds (mode service)
    if [[ -n "${CREDENTIALS_DIRECTORY:-}" ]] && \
       [[ -f "${CREDENTIALS_DIRECTORY}/borg-passphrase" ]]; then
        export BORG_PASSPHRASE
        BORG_PASSPHRASE=$(cat "${CREDENTIALS_DIRECTORY}/borg-passphrase")
        log_debug "Passphrase Borg chargee depuis CREDENTIALS_DIRECTORY (systemd-creds)"
        return 0
    fi

    # Via get-borg-passphrase.sh (bw CLI ou fallback legacy)
    if [[ -x "${_GET_PASSPHRASE_SCRIPT}" ]]; then
        export BORG_PASSPHRASE
        BORG_PASSPHRASE=$("${_GET_PASSPHRASE_SCRIPT}")
        log_debug "Passphrase Borg chargee via get-borg-passphrase.sh"
        return 0
    fi

    # Fallback legacy direct (deprecated)
    if [[ -f "/root/.borg-passphrase" ]]; then
        log_warn "DEPRECATED : lecture depuis /root/.borg-passphrase -- migrer vers Vaultwarden"
        export BORG_PASSPHRASE
        BORG_PASSPHRASE=$(cat /root/.borg-passphrase)
        return 0
    fi

    log_error "Passphrase Borg introuvable (get-borg-passphrase.sh absent : ${_GET_PASSPHRASE_SCRIPT})"
    return 1
}

# Alias pour compatibilite avec le code existant qui appelle ensure_borg_passphrase
ensure_borg_passphrase() {
    load_borg_passphrase
}

# Initialise le repo Borg s'il n'existe pas
# Usage: ensure_borg_repo
# Return: 0 si OK, 1 si echec
ensure_borg_repo() {
    local repo="${BORG_REPO:-/mnt/backup_cold/borg}"

    # D'abord s'assurer que la passphrase est disponible
    load_borg_passphrase || return 1

    # Verifier si le repo existe deja
    if [[ -d "$repo" ]] && borg info "$repo" &>/dev/null; then
        log_debug "Repo Borg existant: $repo"
        return 0
    fi

    # Creer le repo
    log_info "Initialisation du repo Borg: $repo"
    if borg init --encryption=repokey "$repo" 2>/dev/null; then
        log_ok "Repo Borg initialise: $repo"
        return 0
    else
        log_error "Echec initialisation repo Borg"
        return 1
    fi
}

# ==============================================
# Verification Mount Points
# ==============================================

# Verifie et monte si necessaire le point de montage Borg
# Usage: check_borg_mount
# Return: 0 si OK, 1 si echec
check_borg_mount() {
    local mount_point="${BORG_MOUNT_POINT:-/mnt/backup_cold}"

    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_debug "Mount point $mount_point OK"
        return 0
    fi

    log_warn "$mount_point n'est pas monte"

    # Tentative de montage auto
    log_info "Tentative de montage automatique..."
    if mount "$mount_point" 2>/dev/null; then
        log_info "Montage reussi: $mount_point"
        return 0
    else
        log_error "Impossible de monter $mount_point"
        return 1
    fi
}

# ==============================================
# Verification Scripts Externes
# ==============================================

# Verifie qu'un script externe existe et est executable
# Usage: check_external_script <path> <name>
# Return: 0 si OK, 1 sinon
check_external_script() {
    local script="$1"
    local name="$2"

    if [[ ! -f "$script" ]]; then
        log_warn "Script $name non trouve: $script"
        return 1
    fi

    if [[ ! -x "$script" ]]; then
        log_warn "Script $name non executable: $script"
        return 1
    fi

    log_debug "Script $name OK: $script"
    return 0
}

# ==============================================
# Utilitaires
# ==============================================

# Verifie execution en root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit etre execute en root"
        exit 1
    fi
}

# Verifie les dependances
# Usage: check_dependencies <cmd1> [cmd2] ...
# Return: 0 si OK, 1 si manquantes
check_dependencies() {
    local deps=("$@")
    local missing=()

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dependances manquantes: ${missing[*]}"
        return 1
    fi

    return 0
}

# Vérifie la présence d'un outil optionnel
# Usage: check_optional_dep <tool> [install_hint]
# Return: 0 si présent, 1 si absent (avec warning)
check_optional_dep() {
    local tool="$1"
    local install_hint="${2:-}"
    if ! command -v "$tool" &>/dev/null; then
        log_warn "Outil optionnel manquant: $tool${install_hint:+ -- $install_hint}"
        return 1
    fi
    return 0
}

# Affiche aide module commune
show_module_help() {
    local script_name="$1"
    cat << EOF

Backup Manager Agent v${BACKUP_MANAGER_VERSION}
Script: $script_name

Config: $BACKUP_CONFIG_FILE
Logs:   $BACKUP_LOG_DIR

Documentation: scripts/agents/backup-agent.md
EOF
}

# Formatte une duree en secondes vers format lisible
format_duration() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [[ $hours -gt 0 ]]; then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

# ==============================================
# Initialisation
# ==============================================

# Creer repertoire logs si possible
mkdir -p "$BACKUP_LOG_DIR" 2>/dev/null || true

# Debug: afficher config chargee si VERBOSE
if [[ "${VERBOSE:-false}" == "true" ]]; then
    log_debug "Backup Manager v${BACKUP_MANAGER_VERSION} charge"
    log_debug "Config file: $BACKUP_CONFIG_FILE"
    log_debug "Borg repo: $BORG_REPO"
    log_debug "Timeshift dir: $TIMESHIFT_BACKUP_DIR"
fi

# === Lyra Progress Tracking ===
# Ecrit l'avancement dans LYRA_PROGRESS_FILE si defini
# Usage: _lyra_progress STEP TOTAL NAME PCT [GB_DONE] [GB_TOTAL]
_lyra_progress() {
    local step=$1 total=$2 name=$3 pct=$4
    local gb_done=${5:-0} gb_total=${6:-0}
    if [ -n "${LYRA_PROGRESS_FILE:-}" ]; then
        LC_NUMERIC=C printf '{"step":%d,"total":%d,"name":"%s","pct":%d,"percentage":%d,"gb_done":%.1f,"gb_total":%.1f}\n' \
            "$step" "$total" "$name" "$pct" "$pct" "$gb_done" "$gb_total" > "$LYRA_PROGRESS_FILE"
    fi
}
