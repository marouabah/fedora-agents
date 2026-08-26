#!/usr/bin/env bash
#
# common.sh - Fonctions communes pour l'agent VM Controller
# Source ce fichier dans les autres scripts du module
#

# Prevent multiple sourcing
[[ -n "${_VM_CONTROLLER_COMMON_LOADED:-}" ]] && return 0
_VM_CONTROLLER_COMMON_LOADED=1

# ==============================================
# Configuration
# ==============================================

VM_CONTROLLER_VERSION="1.0.0"
VM_CONTROLLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVM_SCRIPTS_DIR="${VM_CONTROLLER_DIR}/../../kvm"

# Charger la config locale si elle existe
SCRIPT_ROOT="$(cd "${VM_CONTROLLER_DIR}/../../.." && pwd)"
[[ -f "${SCRIPT_ROOT}/scripts/config.env" ]] && source "${SCRIPT_ROOT}/scripts/config.env"

# Variables avec defaults (permettent surcharge via config.env)
KVM_IMAGES_DIR="${KVM_IMAGES_DIR:-/var/lib/libvirt/images}"
KVM_NETWORK="${KVM_NETWORK:-default}"

# Configuration utilisateur (peut être surchargée)
VM_CONFIG_FILE="${HOME}/.config/vm-controller/config"
VM_SSH_USER="${VM_SSH_USER:-${SUDO_USER:-$USER}}"
VM_SSH_PORT="${VM_SSH_PORT:-22}"
VM_TIMEOUT="${VM_TIMEOUT:-300}"
VM_SNAPSHOT_AUTO="${VM_SNAPSHOT_AUTO:-false}"
VM_LOG_DIR="${VM_LOG_DIR:-/var/log/vm-controller}"
VM_VERBOSE="${VM_VERBOSE:-false}"

# Charger config utilisateur si elle existe
[[ -f "$VM_CONFIG_FILE" ]] && source "$VM_CONFIG_FILE"

# ==============================================
# Couleurs et Logging
# ==============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Timestamp pour les logs
_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
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
    if [[ "$VM_VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
        _log_to_file "DEBUG" "$1"
    fi
}

_log_to_file() {
    local level="$1"
    local msg="$2"
    local script_name="${BASH_SOURCE[2]:-vm-controller}"
    script_name=$(basename "$script_name" .sh)

    # Créer le répertoire de logs si nécessaire (ignore les erreurs)
    if [[ -w "/var/log" ]] || [[ -w "$VM_LOG_DIR" ]]; then
        mkdir -p "$VM_LOG_DIR" 2>/dev/null || true
        local log_file="$VM_LOG_DIR/$(date +%Y%m%d).log"
        echo "[$(_timestamp)] [$level] $script_name: $msg" >> "$log_file" 2>/dev/null || true
    fi
}

# ==============================================
# Détection sudo/permissions
# ==============================================

SUDO="sudo"
VIRSH="sudo virsh -c qemu:///system"

check_sudo_available() {
    if [[ $EUID -ne 0 ]] && ! sudo -ln 2>/dev/null | grep -q "virsh\|ALL"; then
        log_warn "sudo non configure pour virsh -- certaines operations peuvent echouer"
        log_warn "Ajouter dans /etc/sudoers: $USER ALL=(root) NOPASSWD: /usr/bin/virsh"
    fi
}

setup_virsh_access() {
    # Toujours utiliser sudo pour les commandes libvirt
    # (passwordless sudo configuré pour virsh, virt-install, virt-clone, virt-viewer)
    check_optional_dep "virsh" "sudo dnf install libvirt-client" || true
    check_sudo_available
    log_debug "Utilisation de sudo pour virsh"
}

# ==============================================
# Fonctions de vérification VM
# ==============================================

# Vérifie qu'une VM existe
# Usage: check_vm <vm-name>
# Return: 0 si existe, 1 sinon
check_vm() {
    local vm="$1"

    if [[ -z "$vm" ]]; then
        log_error "Nom de VM requis"
        return 1
    fi

    setup_virsh_access

    if ! $VIRSH dominfo "$vm" &>/dev/null; then
        log_error "VM '$vm' non trouvée"
        return 1
    fi

    return 0
}

# Liste les VMs disponibles
list_vms() {
    setup_virsh_access
    $VIRSH list --all --name | grep -v '^$'
}

# Obtient l'état d'une VM
# Usage: get_vm_state <vm-name>
# Output: running, shut off, paused, etc.
get_vm_state() {
    local vm="$1"
    setup_virsh_access
    $VIRSH domstate "$vm" 2>/dev/null
}

# Vérifie si une VM est en cours d'exécution
# Usage: is_vm_running <vm-name>
# Return: 0 si running, 1 sinon
is_vm_running() {
    local vm="$1"
    local state=$(get_vm_state "$vm")
    # Support both English and French locales (handles Unicode apostrophe)
    [[ "$state" == "running" ]] || [[ "$state" =~ ^en\ cours ]]
}

# ==============================================
# Fonctions réseau/IP
# ==============================================

# Récupère l'IP d'une VM
# Usage: get_vm_ip <vm-name>
# Output: IP address ou vide
get_vm_ip() {
    local vm="$1"
    setup_virsh_access

    # Méthode 1: via virsh domifaddr (nécessite qemu-guest-agent)
    local ip=$($VIRSH domifaddr "$vm" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    # Méthode 2-4: fallback sans qemu-guest-agent
    local mac=$($VIRSH domiflist "$vm" 2>/dev/null | awk '/network|bridge/{print $5}' | head -1)
    if [[ -n "$mac" ]]; then
        # Méthode 2: leases dnsmasq
        if [[ -f /var/lib/libvirt/dnsmasq/virbr0.status ]]; then
            ip=$(grep -A2 "$mac" /var/lib/libvirt/dnsmasq/virbr0.status 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
            if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
        fi

        # Méthode 3: virsh net-dhcp-leases
        ip=$($VIRSH net-dhcp-leases default 2>/dev/null | grep -i "$mac" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi

        # Méthode 4: table ARP (ip neigh puis arp)
        ip=$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1)
        if [[ -z "$ip" ]]; then
            ip=$(arp -an 2>/dev/null | grep -i "$mac" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        fi
        if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    fi

    return 1
}

# Attend que l'IP soit assignée
# Usage: wait_ip <vm-name> [timeout]
# Output: IP address
# Return: 0 si OK, 2 si timeout
wait_ip() {
    local vm="$1"
    local timeout="${2:-$VM_TIMEOUT}"
    local elapsed=0
    local ip=""

    log_debug "Attente de l'IP pour $vm (timeout: ${timeout}s)"

    while [[ -z "$ip" && $elapsed -lt $timeout ]]; do
        ip=$(get_vm_ip "$vm")
        if [[ -z "$ip" ]]; then
            sleep 2
            ((elapsed+=2))
            echo -n "." >&2
        fi
    done
    echo "" >&2

    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    log_error "Timeout: IP non obtenue après ${timeout}s"
    return 2
}

# Attend que SSH soit accessible
# Usage: wait_ssh <vm-name> [timeout]
# Return: 0 si OK, 2 si timeout
wait_ssh() {
    local vm="$1"
    local timeout="${2:-$VM_TIMEOUT}"
    local elapsed=0

    log_debug "Attente SSH pour $vm (timeout: ${timeout}s)"

    # D'abord attendre l'IP
    local ip=$(wait_ip "$vm" "$timeout")
    if [[ -z "$ip" ]]; then
        return 2
    fi

    # Puis attendre que SSH réponde
    while [[ $elapsed -lt $timeout ]]; do
        if ssh -n -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
           -p "$VM_SSH_PORT" "${VM_SSH_USER}@${ip}" "exit 0" &>/dev/null; then
            log_debug "SSH accessible sur $ip"
            return 0
        fi
        sleep 2
        ((elapsed+=2))
        echo -n "." >&2
    done
    echo "" >&2

    log_error "Timeout: SSH non accessible après ${timeout}s"
    return 2
}

# Test si SSH est accessible (sans attente)
# Usage: is_ssh_accessible <vm-name>
# Return: 0 si accessible, 1 sinon
is_ssh_accessible() {
    local vm="$1"
    local ip=$(get_vm_ip "$vm")

    if [[ -z "$ip" ]]; then
        return 1
    fi

    # -n pour ne pas consommer stdin (important dans les boucles while read)
    ssh -n -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -p "$VM_SSH_PORT" "${VM_SSH_USER}@${ip}" "exit 0" &>/dev/null
}

# ==============================================
# Utilitaires
# ==============================================

# Vérifie les dépendances requises
check_dependencies() {
    local deps=("$@")
    local missing=()

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dépendances manquantes: ${missing[*]}"
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

# Affiche l'aide générique pour les scripts du module
show_module_help() {
    local script_name="$1"
    cat << EOF
VM Controller Agent v$VM_CONTROLLER_VERSION
Script: $script_name

Configuration:
  SSH User: $VM_SSH_USER
  SSH Port: $VM_SSH_PORT
  Timeout:  ${VM_TIMEOUT}s
  Log Dir:  $VM_LOG_DIR

Config file: $VM_CONFIG_FILE

Documentation: scripts/agents/vm-controller-agent.md
EOF
}

# ==============================================
# Initialisation automatique
# ==============================================

setup_virsh_access

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
