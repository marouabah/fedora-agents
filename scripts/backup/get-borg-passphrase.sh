#!/usr/bin/env bash
# get-borg-passphrase.sh -- Recupere la passphrase Borg sans l'ecrire sur disque
# Usage: BORG_PASSPHRASE=$(./get-borg-passphrase.sh)
#        source <(./get-borg-passphrase.sh --export)
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

EXPORT_MODE=false

if [[ "${1:-}" == "--export" ]]; then
    EXPORT_MODE=true
fi

get_passphrase() {
    # Priorite 1 : injection systemd-creds (mode service)
    if [[ -n "${CREDENTIALS_DIRECTORY:-}" ]] && \
       [[ -f "${CREDENTIALS_DIRECTORY}/borg-passphrase" ]]; then
        cat "${CREDENTIALS_DIRECTORY}/borg-passphrase"
        return 0
    fi

    # Priorite 2 : systemd-creds decrypt direct (root hors service)
    local _cred_file="/etc/systemd/system/borg-backup.service.d/borg-passphrase.cred"
    if [[ $EUID -eq 0 ]] && [[ -f "$_cred_file" ]]; then
        local _pass
        _pass=$(systemd-creds decrypt --name=borg-passphrase "$_cred_file" - 2>/dev/null) || true
        if [[ -n "$_pass" ]]; then
            echo "$_pass"
            return 0
        fi
    fi

    # Priorite 3 : BORG_PASSPHRASE deja dans l'environnement
    if [[ -n "${BORG_PASSPHRASE:-}" ]]; then
        echo "${BORG_PASSPHRASE}"
        return 0
    fi

    # Priorite 3 : bw CLI avec session active (env ou /root/.bw-session)
    if [[ -z "${BW_SESSION:-}" ]] && [[ -f "/root/.bw-session" ]]; then
        BW_SESSION=$(cat /root/.bw-session)
    fi
    # bw doit tourner en tant que l'utilisateur qui a bw configure (pas root)
    local BW_USER="${SUDO_USER:-$USER}"
    local BW_CMD
    if [[ $EUID -eq 0 ]]; then
        BW_CMD="sudo -u $BW_USER bw"
    else
        BW_CMD="bw"
    fi
    if command -v bw &>/dev/null && [[ -n "${BW_SESSION:-}" ]]; then
        local passphrase
        passphrase=$($BW_CMD get password "Borg Backup - fedora-setup" --session "$BW_SESSION" 2>/dev/null) || true
        if [[ -n "$passphrase" ]]; then
            echo "$passphrase"
            return 0
        fi
        log_warn "bw CLI disponible mais recuperation du secret echouee (item introuvable ou session invalide)"
    fi

    # Priorite 4 : fallback legacy /root/.borg-passphrase
    if [[ -f "/root/.borg-passphrase" ]]; then
        log_warn "DEPRECATED : lecture depuis /root/.borg-passphrase -- migrer vers Vaultwarden (item: 'Borg Backup - fedora-setup')"
        cat "/root/.borg-passphrase"
        return 0
    fi

    # Aucune source disponible
    log_error "Passphrase Borg introuvable. Sources verifiees :"
    log_error "  1. \$CREDENTIALS_DIRECTORY/borg-passphrase (systemd-creds)"
    log_error "  2. \$BORG_PASSPHRASE (variable d'environnement)"
    log_error "  3. bw CLI + \$BW_SESSION (Vaultwarden, item: 'Borg Backup - fedora-setup')"
    log_error "  4. /root/.borg-passphrase (legacy)"
    exit 1
}

passphrase=$(get_passphrase)

if [[ "$EXPORT_MODE" == "true" ]]; then
    echo "export BORG_PASSPHRASE=$(printf '%q' "$passphrase")"
else
    echo "$passphrase"
fi
