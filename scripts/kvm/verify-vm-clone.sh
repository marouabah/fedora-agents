#!/usr/bin/env bash
#
# verify-vm-clone.sh - Vérifie qu'une VM clone est une copie fidèle du système hôte
# Usage: verify-vm-clone.sh [options]
#
# Peut s'exécuter:
# - Depuis l'hôte (vérifie via SSH dans la VM)
# - Depuis la VM elle-même (mode self-check)
#

set -euo pipefail

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration par défaut
VM_NAME="neutron-clone"
VM_USER="${VM_SSH_USER:-${SUDO_USER:-$USER}}"
VM_IP=""
SSH_PORT=22
VERBOSE=false
QUICK=false
SAVE_REPORT=false
COMPARE_PACKAGES=false
COMPARE_CONTENT=false
SELF_CHECK=false
REPORT_FILE=""

# Scores - deux types:
# - Fonctionnel: la VM fonctionne-t-elle correctement?
# - Identité: la VM est-elle identique à l'hôte?
FUNC_TOTAL=0
FUNC_PASSED=0
IDENT_TOTAL=0
IDENT_PASSED=0

# Différences attendues (adaptations VM, ne comptent pas comme erreur)
EXPECTED_DIFFS=""

# Rapport détaillé
REPORT_DETAILS=""

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[====]${NC} $1"; }

usage() {
    cat << 'EOF'
Usage: ./verify-vm-clone.sh [OPTIONS]

Vérifie qu'une VM clonée est une copie fidèle du système hôte.

Modes d'exécution:
    Depuis l'hôte:  ./verify-vm-clone.sh --vm neutron-clone
    Depuis la VM:   ./verify-vm-clone.sh --self-check

Options:
    -v, --vm NAME        Nom de la VM à vérifier (défaut: neutron-clone)
    -i, --ip IP          IP de la VM (auto-détecté si non spécifié)
    -u, --user USER      Utilisateur SSH (défaut: utilisateur courant)
    -s, --self-check     Mode self-check (exécuter depuis la VM)
    --verbose            Afficher tous les détails
    --quick              Vérifications rapides uniquement
    --save-report        Sauvegarder le rapport dans docs/
    --compare-packages   Comparer les packages RPM en détail
    --compare-content    Comparaison approfondie du contenu des fichiers (deep verify)
    -h, --help           Afficher cette aide

Exemples:
    sudo ./verify-vm-clone.sh --vm neutron-clone
    ./verify-vm-clone.sh --self-check --verbose
    ./verify-vm-clone.sh --vm neutron-clone --compare-packages --save-report
EOF
}

# Détecter si on est dans une VM
detect_vm_environment() {
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        local product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
        if [[ "$product" == *"KVM"* ]] || [[ "$product" == *"QEMU"* ]]; then
            return 0
        fi
    fi
    if systemd-detect-virt -q 2>/dev/null; then
        return 0
    fi
    return 1
}

# Obtenir l'IP de la VM
get_vm_ip() {
    if [[ -n "$VM_IP" ]]; then
        return
    fi

    log_info "Détection de l'IP de la VM $VM_NAME..."

    # Obtenir l'adresse MAC de la VM
    local mac
    mac=$(virsh -c qemu:///system domiflist "$VM_NAME" 2>/dev/null | grep -oP '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1 || true)

    if [[ -z "$mac" ]]; then
        log_error "Impossible de récupérer l'adresse MAC de la VM"
        exit 1
    fi

    log_info "MAC de la VM: $mac"

    # Méthode 1: virsh domifaddr (nécessite qemu-guest-agent)
    VM_IP=$(virsh -c qemu:///system domifaddr "$VM_NAME" 2>/dev/null | grep -oP '192\.168\.\d+\.\d+' | head -1 || true)

    # Méthode 2: Fichier de leases dnsmasq
    if [[ -z "$VM_IP" ]]; then
        if [[ -f /var/lib/libvirt/dnsmasq/virbr0.status ]]; then
            VM_IP=$(grep -A2 "$mac" /var/lib/libvirt/dnsmasq/virbr0.status 2>/dev/null | grep -oP '192\.168\.122\.\d+' | head -1 || true)
        fi
    fi

    # Méthode 3: virsh net-dhcp-leases
    if [[ -z "$VM_IP" ]]; then
        VM_IP=$(virsh -c qemu:///system net-dhcp-leases default 2>/dev/null | grep -i "$mac" | grep -oP '192\.168\.122\.\d+' | head -1 || true)
    fi

    # Méthode 4: Table ARP
    if [[ -z "$VM_IP" ]]; then
        VM_IP=$(ip neigh show | grep -i "$mac" | awk '{print $1}' | head -1 || true)
        if [[ -z "$VM_IP" ]]; then
            VM_IP=$(arp -an | grep -i "$mac" | grep -oP '192\.168\.\d+\.\d+' | head -1 || true)
        fi
    fi

    # Méthode 5: Ping sweep pour peupler la table ARP
    if [[ -z "$VM_IP" ]]; then
        log_info "Scan du réseau 192.168.122.0/24..."
        # Ping sweep rapide en arrière-plan
        for i in {2..254}; do
            ping -c1 -W1 "192.168.122.$i" &>/dev/null &
        done
        wait 2>/dev/null
        sleep 1
        # Réessayer la table ARP
        VM_IP=$(ip neigh show | grep -i "$mac" | awk '{print $1}' | head -1 || true)
    fi

    # Méthode 6: nmap si disponible
    if [[ -z "$VM_IP" ]] && command -v nmap &>/dev/null; then
        log_info "Scan nmap du réseau..."
        VM_IP=$(nmap -sn 192.168.122.0/24 2>/dev/null | grep -B2 "$mac" | grep -oP '192\.168\.122\.\d+' | head -1 || true)
    fi

    if [[ -z "$VM_IP" ]]; then
        log_error "Impossible de détecter l'IP de la VM"
        echo ""
        log_info "La VM ne semble pas avoir d'adresse IP DHCP."
        log_info "Solutions possibles:"
        log_info "  1. Ouvrir la console: virt-viewer $VM_NAME"
        log_info "  2. Dans la VM, vérifier: ip addr show"
        log_info "  3. Spécifier l'IP: $0 --vm $VM_NAME --ip X.X.X.X"
        log_info "  4. Installer qemu-guest-agent dans la VM"
        exit 1
    fi

    log_info "IP détectée: $VM_IP"
}

# Vérifier la connexion SSH
check_ssh_connection() {
    log_info "Test de connexion SSH vers $VM_USER@$VM_IP..."

    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$VM_USER@$VM_IP" "echo OK" &>/dev/null; then
        log_error "Connexion SSH impossible vers $VM_USER@$VM_IP"
        log_info "Vérifiez que:"
        log_info "  1. La VM est démarrée"
        log_info "  2. SSH est actif dans la VM"
        log_info "  3. Votre clé SSH est configurée"
        exit 1
    fi

    log_info "Connexion SSH OK"
}

# Exécuter une commande sur la VM ou localement (avec timeout de 10s)
run_cmd() {
    local cmd="$1"
    local cmd_timeout="${2:-10}"  # Timeout par défaut: 10 secondes
    if [[ "$SELF_CHECK" == true ]]; then
        timeout "$cmd_timeout" bash -c "$cmd" 2>/dev/null || echo ""
    else
        # Ajouter ~/.local/bin au PATH pour trouver pipx, poetry, claude, etc.
        # BatchMode=yes évite les prompts interactifs, TERM=dumb évite les séquences d'échappement
        timeout "$cmd_timeout" ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM_USER@$VM_IP" \
            "export TERM=dumb; export PATH=~/.local/bin:~/.cargo/bin:\$PATH; $cmd" 2>/dev/null || echo ""
    fi
}

# Exécuter une commande localement (hôte)
run_host() {
    local cmd="$1"
    eval "$cmd" 2>/dev/null || echo ""
}

# Ajouter un résultat au rapport
# Usage: add_result category item status details [score_type]
# score_type: "func" (fonctionnel), "ident" (identité), "both" (défaut)
add_result() {
    local category="$1"
    local item="$2"
    local status="$3"  # ok, warn, fail, info (info = différence attendue, ne compte pas)
    local details="$4"
    local score_type="${5:-both}"  # func, ident, both (défaut)

    local icon
    local passed=false

    case "$status" in
        ok)   icon="✅"; passed=true ;;
        warn) icon="⚠️ "; passed=true ;;
        fail) icon="❌"; passed=false ;;
        info)
            # Différence attendue - ne compte pas dans le score
            icon="ℹ️ "
            EXPECTED_DIFFS+="  $item: $details\n"
            printf "  %s %-16s: %s\n" "$icon" "$item" "$details"
            return
            ;;
    esac

    # Mettre à jour les scores selon le type
    case "$score_type" in
        func)
            FUNC_TOTAL=$((FUNC_TOTAL + 1))
            [[ "$passed" == true ]] && FUNC_PASSED=$((FUNC_PASSED + 1))
            ;;
        ident)
            IDENT_TOTAL=$((IDENT_TOTAL + 1))
            [[ "$passed" == true ]] && IDENT_PASSED=$((IDENT_PASSED + 1))
            ;;
        both|*)
            FUNC_TOTAL=$((FUNC_TOTAL + 1))
            IDENT_TOTAL=$((IDENT_TOTAL + 1))
            if [[ "$passed" == true ]]; then
                FUNC_PASSED=$((FUNC_PASSED + 1))
                IDENT_PASSED=$((IDENT_PASSED + 1))
            fi
            ;;
    esac

    printf "  %s %-16s: %s\n" "$icon" "$item" "$details"

    if [[ "$VERBOSE" == true ]]; then
        REPORT_DETAILS+="[$category] $item: $details ($status)\n"
    fi
}

# ============================================================
# VÉRIFICATIONS
# ============================================================

check_system_base() {
    echo ""
    echo -e "${BOLD}📦 Système de base${NC}"

    # OS Version - identité (doit être le même OS)
    local host_os=$(run_host "cat /etc/fedora-release")
    local vm_os=$(run_cmd "cat /etc/fedora-release")

    if [[ "$host_os" == "$vm_os" ]]; then
        add_result "system" "OS Version" "ok" "Fedora $(echo $vm_os | grep -oP '\d+') (identique)" "both"
    else
        add_result "system" "OS Version" "warn" "Hôte: $host_os | VM: $vm_os" "both"
    fi

    # Kernel - identité (doit être le même kernel)
    local host_kernel=$(run_host "uname -r")
    local vm_kernel=$(run_cmd "uname -r")

    if [[ "$host_kernel" == "$vm_kernel" ]]; then
        add_result "system" "Kernel" "ok" "$vm_kernel (identique)" "both"
    else
        local host_major=$(echo "$host_kernel" | cut -d. -f1-2)
        local vm_major=$(echo "$vm_kernel" | cut -d. -f1-2)
        if [[ "$host_major" == "$vm_major" ]]; then
            add_result "system" "Kernel" "ok" "$vm_kernel (compatible)" "both"
        else
            add_result "system" "Kernel" "warn" "Hôte: $host_kernel | VM: $vm_kernel" "both"
        fi
    fi

    # Architecture - fonctionnel uniquement
    local arch=$(run_cmd "uname -m")
    add_result "system" "Architecture" "ok" "$arch" "func"

    # Hostname - fonctionnel uniquement (doit être différent de l'hôte)
    local host_hostname=$(run_host "hostname")
    local vm_hostname=$(run_cmd "hostname")

    if [[ "$host_hostname" != "$vm_hostname" ]]; then
        add_result "system" "Hostname" "ok" "$vm_hostname (différent OK)" "func"
    else
        add_result "system" "Hostname" "warn" "$vm_hostname (identique à l'hôte)" "func"
    fi

    # Utilisateur principal - fonctionnel
    if run_cmd "id $VM_USER" | grep -q "$VM_USER"; then
        local uid=$(run_cmd "id -u $VM_USER")
        add_result "system" "Utilisateur" "ok" "$VM_USER (uid=$uid)" "func"
    else
        add_result "system" "Utilisateur" "fail" "$VM_USER non trouvé" "func"
    fi
}

check_desktop_hyprland() {
    echo ""
    echo -e "${BOLD}🎨 Desktop Hyprland${NC}"

    # Hyprland
    local hypr_path=$(run_cmd "which Hyprland 2>/dev/null || echo ''")
    if [[ -n "$hypr_path" ]]; then
        local host_hypr_ver=$(run_host "Hyprland --version 2>/dev/null | head -1" || echo "")
        local vm_hypr_ver=$(run_cmd "Hyprland --version 2>/dev/null | head -1" || echo "")

        if [[ "$host_hypr_ver" == "$vm_hypr_ver" ]]; then
            add_result "desktop" "Hyprland" "ok" "$(echo $vm_hypr_ver | grep -oP 'v[\d.]+' || echo 'installé') (identique)"
        else
            add_result "desktop" "Hyprland" "warn" "Versions différentes"
        fi
    else
        add_result "desktop" "Hyprland" "fail" "Non installé"
    fi

    # Waybar
    if run_cmd "which waybar" | grep -q waybar; then
        add_result "desktop" "Waybar" "ok" "Installé"
    else
        add_result "desktop" "Waybar" "fail" "Non installé"
    fi

    # Kitty
    local kitty_path=$(run_cmd "which kitty 2>/dev/null || echo ''")
    if [[ -n "$kitty_path" ]]; then
        local kitty_ver=$(run_cmd "kitty --version 2>/dev/null | head -1" || echo "")
        add_result "desktop" "Kitty" "ok" "$(echo $kitty_ver | grep -oP '[\d.]+' || echo 'installé')"
    else
        add_result "desktop" "Kitty" "fail" "Non installé"
    fi

    # Wofi/Rofi
    if run_cmd "which wofi" | grep -q wofi; then
        add_result "desktop" "Wofi" "ok" "Installé"
    elif run_cmd "which rofi" | grep -q rofi; then
        add_result "desktop" "Rofi" "ok" "Installé"
    else
        add_result "desktop" "Launcher" "warn" "Ni wofi ni rofi"
    fi

    # Configs
    if [[ "$QUICK" != true ]]; then
        local configs=("hypr" "waybar" "kitty" "wofi")
        local configs_found=0
        local configs_identical=0

        for cfg in "${configs[@]}"; do
            local vm_cfg=$(run_cmd "ls -la /home/$VM_USER/.config/$cfg 2>/dev/null | wc -l" || echo "0")
            if [[ "$vm_cfg" -gt 0 ]]; then
                configs_found=$((configs_found + 1))

                # Comparer checksums si pas en mode quick
                local host_md5=$(run_host "find /home/$VM_USER/.config/$cfg -type f -exec md5sum {} \; 2>/dev/null | sort | md5sum" || echo "")
                local vm_md5=$(run_cmd "find /home/$VM_USER/.config/$cfg -type f -exec md5sum {} \; 2>/dev/null | sort | md5sum" || echo "")

                if [[ -n "$host_md5" ]] && [[ "$host_md5" == "$vm_md5" ]]; then
                    configs_identical=$((configs_identical + 1))
                fi
            fi
        done

        add_result "desktop" "Configs" "ok" "$configs_identical/${#configs[@]} identiques"
    fi
}

check_python_env() {
    echo ""
    echo -e "${BOLD}🐍 Environnement Python${NC}"

    # Python version
    local host_python=$(run_host "python3 --version 2>/dev/null | grep -oP '[\d.]+'" || echo "")
    local vm_python=$(run_cmd "python3 --version 2>/dev/null | grep -oP '[\d.]+'" || echo "")

    if [[ "$host_python" == "$vm_python" ]]; then
        add_result "python" "Python" "ok" "$vm_python (identique)"
    else
        add_result "python" "Python" "warn" "Hôte: $host_python | VM: $vm_python"
    fi

    # pyenv
    if run_cmd "ls /home/$VM_USER/.pyenv" | grep -q versions; then
        local pyenv_versions=$(run_cmd "ls /home/$VM_USER/.pyenv/versions 2>/dev/null | wc -l" || echo "0")
        add_result "python" "pyenv" "ok" "$pyenv_versions versions"
    else
        add_result "python" "pyenv" "warn" "Non configuré"
    fi

    # poetry
    local poetry_ver=$(run_cmd "poetry --version 2>/dev/null | grep -oP '[\d.]+'" || echo "")
    if [[ -n "$poetry_ver" ]]; then
        add_result "python" "poetry" "ok" "v$poetry_ver"
    else
        add_result "python" "poetry" "fail" "Non installé"
    fi

    # pipx
    local pipx_ver=$(run_cmd "pipx --version 2>/dev/null" || echo "")
    if [[ -n "$pipx_ver" ]]; then
        add_result "python" "pipx" "ok" "v$pipx_ver"
    else
        add_result "python" "pipx" "warn" "Non installé"
    fi

    # Outils dev
    local tools=("ipython" "ruff" "black" "mypy" "pytest")
    local tools_found=0

    for tool in "${tools[@]}"; do
        if run_cmd "which $tool 2>/dev/null" | grep -q "$tool"; then
            tools_found=$((tools_found + 1))
        fi
    done

    if [[ $tools_found -eq ${#tools[@]} ]]; then
        add_result "python" "Outils dev" "ok" "$tools_found/${#tools[@]} présents"
    elif [[ $tools_found -gt 0 ]]; then
        add_result "python" "Outils dev" "warn" "$tools_found/${#tools[@]} présents"
    else
        add_result "python" "Outils dev" "fail" "Aucun trouvé"
    fi
}

check_claude_code() {
    echo ""
    echo -e "${BOLD}🤖 Claude Code${NC}"

    # Binaire - vérifier si claude existe dans le PATH
    local claude_path=$(run_cmd "which claude 2>/dev/null || which claude-code 2>/dev/null || echo ''" 5)
    if [[ -n "$claude_path" ]]; then
        # Obtenir la version (timeout court car peut hang)
        local claude_ver=$(run_cmd "claude --version 2>/dev/null | head -1" 5)
        if [[ -n "$claude_ver" ]]; then
            add_result "claude" "Installé" "ok" "$claude_ver"
        else
            add_result "claude" "Installé" "ok" "Présent ($claude_path)"
        fi

        # Auth status - SKIP car peut hang en session non-interactive
        # claude auth status essaie souvent d'ouvrir un navigateur
        add_result "claude" "Auth" "warn" "Non vérifiée (SSH)"
    else
        add_result "claude" "Installé" "fail" "Non trouvé"
        add_result "claude" "Auth" "fail" "N/A"
    fi
}

check_projects_structure() {
    echo ""
    echo -e "${BOLD}📂 Projets & Scripts${NC}"

    # ~/dev existe
    if run_cmd "test -d /home/$VM_USER/dev && echo yes" | grep -q yes; then
        local dev_files=$(run_cmd "find /home/$VM_USER/dev -type f 2>/dev/null | wc -l" || echo "0")
        add_result "projects" "~/dev" "ok" "$dev_files fichiers"
    else
        add_result "projects" "~/dev" "fail" "Non trouvé"
    fi

    # fedora-setup
    if run_cmd "test -d /home/$VM_USER/dev/fedora-setup && echo yes" | grep -q yes; then
        local fs_files=$(run_cmd "find /home/$VM_USER/dev/fedora-setup -type f 2>/dev/null | wc -l" || echo "0")
        add_result "projects" "fedora-setup" "ok" "$fs_files fichiers"
    else
        add_result "projects" "fedora-setup" "warn" "Non trouvé"
    fi

    # dotfiles
    if run_cmd "test -d /home/$VM_USER/dev/dotfiles && echo yes" | grep -q yes; then
        add_result "projects" "dotfiles" "ok" "Présent"
    elif run_cmd "test -d /home/$VM_USER/dotfiles && echo yes" | grep -q yes; then
        add_result "projects" "dotfiles" "ok" "Présent (dans ~/)"
    else
        add_result "projects" "dotfiles" "warn" "Non trouvé"
    fi

    # Scripts personnels
    if run_cmd "test -d /home/$VM_USER/scripts && echo yes" | grep -q yes; then
        local scripts_count=$(run_cmd "find /home/$VM_USER/scripts -name '*.sh' 2>/dev/null | wc -l" || echo "0")
        add_result "projects" "Scripts" "ok" "$scripts_count scripts"
    else
        add_result "projects" "Scripts" "warn" "~/scripts non trouvé"
    fi
}

check_packages() {
    echo ""
    echo -e "${BOLD}📦 Packages (rpm)${NC}"

    if [[ "$QUICK" == true ]]; then
        local vm_pkg_count=$(run_cmd "rpm -qa | wc -l" || echo "0")
        add_result "packages" "Installés" "ok" "$vm_pkg_count packages" "ident"
        return
    fi

    local tmpdir=$(mktemp -d)

    # Obtenir les listes de packages (tri local avec LC_ALL=C pour cohérence)
    run_host "rpm -qa" | LC_ALL=C sort > "$tmpdir/host_packages.txt"
    run_cmd "rpm -qa" | LC_ALL=C sort > "$tmpdir/vm_packages.txt"

    local host_count=$(wc -l < "$tmpdir/host_packages.txt")
    local vm_count=$(wc -l < "$tmpdir/vm_packages.txt")

    # Comparer (2>/dev/null pour ignorer les warnings de tri)
    local common=$(comm -12 "$tmpdir/host_packages.txt" "$tmpdir/vm_packages.txt" 2>/dev/null | wc -l)
    local host_only=$(comm -23 "$tmpdir/host_packages.txt" "$tmpdir/vm_packages.txt" 2>/dev/null | wc -l)
    local vm_only=$(comm -13 "$tmpdir/host_packages.txt" "$tmpdir/vm_packages.txt" 2>/dev/null | wc -l)

    add_result "packages" "Installés" "ok" "$common/$host_count identiques" "ident"

    if [[ $host_only -gt 0 ]] || [[ $vm_only -gt 0 ]]; then
        add_result "packages" "Différences" "warn" "$host_only hôte-only, $vm_only VM-only" "ident"

        if [[ "$COMPARE_PACKAGES" == true ]] || [[ "$VERBOSE" == true ]]; then
            echo ""
            echo "     Packages sur hôte uniquement (échantillon):"
            comm -23 "$tmpdir/host_packages.txt" "$tmpdir/vm_packages.txt" 2>/dev/null | \
                grep -v -E "^kernel-|^kmod-|^libvirt|^qemu|^virt-" | head -5 | \
                while read pkg; do echo "       - $pkg"; done || true

            echo "     Packages sur VM uniquement (échantillon):"
            comm -13 "$tmpdir/host_packages.txt" "$tmpdir/vm_packages.txt" 2>/dev/null | \
                grep -v -E "^kernel-|^qemu-guest" | head -5 | \
                while read pkg; do echo "       - $pkg"; done || true
        fi
    fi

    rm -rf "$tmpdir"
}

check_systemd_services() {
    echo ""
    echo -e "${BOLD}🔧 Services systemd${NC}"

    # Services système running - fonctionnel
    local vm_services=$(run_cmd "systemctl list-units --state=running --no-pager --no-legend | wc -l" || echo "0")
    add_result "services" "Système" "ok" "$vm_services services actifs" "func"

    # Services utilisateur - fonctionnel
    local vm_user_services=$(run_cmd "systemctl --user list-units --state=running --no-pager --no-legend 2>/dev/null | wc -l" || echo "0")

    if [[ "$vm_user_services" -gt 0 ]]; then
        add_result "services" "Utilisateur" "ok" "$vm_user_services services" "func"
    else
        add_result "services" "Utilisateur" "warn" "Aucun (session non active?)" "func"
    fi

    # Services critiques - fonctionnel
    local critical=("sshd" "NetworkManager")
    local critical_ok=0

    for svc in "${critical[@]}"; do
        if run_cmd "systemctl is-active $svc 2>/dev/null" | grep -q "^active"; then
            critical_ok=$((critical_ok + 1))
        fi
    done

    if [[ $critical_ok -eq ${#critical[@]} ]]; then
        add_result "services" "Critiques" "ok" "$critical_ok/${#critical[@]} actifs" "func"
    else
        add_result "services" "Critiques" "warn" "$critical_ok/${#critical[@]} actifs" "func"
    fi
}

check_network() {
    echo ""
    echo -e "${BOLD}🌐 Réseau${NC}"

    # SSH Server - fonctionnel
    if run_cmd "systemctl is-active sshd" | grep -q "^active"; then
        add_result "network" "SSH Server" "ok" "Actif" "func"
    else
        add_result "network" "SSH Server" "fail" "Inactif" "func"
    fi

    # Port 22 - fonctionnel
    if run_cmd "ss -tulpn | grep ':22 '" | grep -q LISTEN; then
        add_result "network" "Port 22" "ok" "Ouvert" "func"
    else
        add_result "network" "Port 22" "fail" "Fermé" "func"
    fi

    # IP - fonctionnel
    local vm_ip_internal=$(run_cmd "hostname -I | awk '{print \$1}'" || echo "")
    if [[ -n "$vm_ip_internal" ]]; then
        add_result "network" "IP" "ok" "$vm_ip_internal" "func"
    else
        add_result "network" "IP" "warn" "Non détectée" "func"
    fi

    # Test connexion depuis hôte - fonctionnel
    if [[ "$SELF_CHECK" != true ]]; then
        if ping -c1 -W2 "$VM_IP" &>/dev/null; then
            add_result "network" "Ping hôte" "ok" "Accessible" "func"
        else
            add_result "network" "Ping hôte" "fail" "Non accessible" "func"
        fi
    fi
}

check_dotfiles() {
    echo ""
    echo -e "${BOLD}📄 Dotfiles${NC}"

    if [[ "$QUICK" == true ]]; then
        if run_cmd "test -f /home/$VM_USER/.bashrc && echo yes" | grep -q yes; then
            add_result "dotfiles" "bashrc" "ok" "Présent"
        else
            add_result "dotfiles" "bashrc" "fail" "Manquant"
        fi
        return
    fi

    # Liste des fichiers à comparer
    local dotfiles=(
        ".bashrc"
        ".config/hypr/hyprland.conf"
        ".config/waybar/config"
        ".config/kitty/kitty.conf"
        ".gitconfig"
    )

    local identical=0
    local total=0

    for df in "${dotfiles[@]}"; do
        local host_file="/home/$VM_USER/$df"

        if [[ -f "$host_file" ]]; then
            total=$((total + 1))
            local host_md5=$(run_host "md5sum '$host_file' 2>/dev/null | cut -d' ' -f1" || echo "")
            local vm_md5=$(run_cmd "md5sum '/home/$VM_USER/$df' 2>/dev/null | cut -d' ' -f1" || echo "")

            if [[ -n "$host_md5" ]] && [[ "$host_md5" == "$vm_md5" ]]; then
                identical=$((identical + 1))
            fi
        fi
    done

    # bashrc - identité uniquement
    local bashrc_host=$(run_host "md5sum /home/$VM_USER/.bashrc 2>/dev/null | cut -d' ' -f1" || echo "")
    local bashrc_vm=$(run_cmd "md5sum /home/$VM_USER/.bashrc 2>/dev/null | cut -d' ' -f1" || echo "")

    if [[ -n "$bashrc_host" ]] && [[ "$bashrc_host" == "$bashrc_vm" ]]; then
        add_result "dotfiles" "bashrc" "ok" "Identique" "ident"
    elif [[ -n "$bashrc_vm" ]]; then
        add_result "dotfiles" "bashrc" "warn" "Différent" "ident"
    else
        add_result "dotfiles" "bashrc" "fail" "Manquant" "ident"
    fi

    # hyprland.conf - différence attendue (adapté pour VM avec GPU virtio)
    local hypr_host=$(run_host "md5sum /home/$VM_USER/.config/hypr/hyprland.conf 2>/dev/null | cut -d' ' -f1" || echo "")
    local hypr_vm=$(run_cmd "md5sum /home/$VM_USER/.config/hypr/hyprland.conf 2>/dev/null | cut -d' ' -f1" || echo "")

    if [[ -n "$hypr_host" ]] && [[ "$hypr_host" == "$hypr_vm" ]]; then
        add_result "dotfiles" "hyprland.conf" "ok" "Identique" "ident"
    elif [[ -n "$hypr_vm" ]]; then
        # Différence attendue: adapté pour GPU virtio dans la VM
        add_result "dotfiles" "hyprland.conf" "info" "Adapté pour VM (GPU virtio)"
    else
        add_result "dotfiles" "hyprland.conf" "fail" "Manquant" "ident"
    fi

    # Autres configs - identité uniquement
    if [[ $total -gt 0 ]]; then
        add_result "dotfiles" "Autres" "ok" "$identical/$total identiques" "ident"
    fi
}

check_file_content_deep() {
    # Ne s'exécute que si --compare-content est activé
    if [[ "$COMPARE_CONTENT" != true ]]; then
        return
    fi

    echo ""
    echo -e "${BOLD}🔍 Comparaison approfondie du contenu (Deep Verify)${NC}"

    local tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    # Répertoires à comparer (fichiers importants)
    local dirs_to_check=(
        ".config/hypr"
        ".config/waybar"
        ".config/kitty"
        ".config/wofi"
        ".bashrc"
        ".bash_profile"
        ".gitconfig"
        "dev/fedora-setup"
        "scripts"
    )

    local total_files=0
    local identical_files=0
    local different_files=0
    local missing_files=0
    local diff_details=""

    for target in "${dirs_to_check[@]}"; do
        local host_path="/home/$VM_USER/$target"
        local vm_path="/home/$VM_USER/$target"

        # Vérifier si c'est un fichier ou un répertoire
        if [[ -f "$host_path" ]]; then
            # C'est un fichier unique
            total_files=$((total_files + 1))

            local host_md5=$(md5sum "$host_path" 2>/dev/null | cut -d' ' -f1 || echo "")
            local vm_md5=$(run_cmd "md5sum '$vm_path' 2>/dev/null | cut -d' ' -f1" || echo "")

            if [[ -z "$vm_md5" ]]; then
                missing_files=$((missing_files + 1))
                diff_details+="  ❌ MANQUANT: $target\n"
            elif [[ "$host_md5" == "$vm_md5" ]]; then
                identical_files=$((identical_files + 1))
            else
                different_files=$((different_files + 1))
                diff_details+="  ⚠️  DIFFÉRENT: $target\n"
            fi

        elif [[ -d "$host_path" ]]; then
            # C'est un répertoire - comparaison optimisée
            # Étape 1: Lister les fichiers avec taille sur l'hôte
            find "$host_path" -type f -printf '%s %P\n' 2>/dev/null | sort -k2 > "$tmpdir/host_${target//\//_}.txt"

            # Étape 2: Même chose sur la VM
            run_cmd "find '$vm_path' -type f -printf '%s %P\n' 2>/dev/null" | sort -k2 > "$tmpdir/vm_${target//\//_}.txt"

            # Étape 3: Comparer les listes
            local host_file="$tmpdir/host_${target//\//_}.txt"
            local vm_file="$tmpdir/vm_${target//\//_}.txt"

            while IFS=' ' read -r host_size host_relpath; do
                [[ -z "$host_relpath" ]] && continue
                total_files=$((total_files + 1))

                # Chercher le fichier correspondant dans la VM
                local vm_line=$(grep -E "^[0-9]+ ${host_relpath}$" "$vm_file" 2>/dev/null || echo "")

                if [[ -z "$vm_line" ]]; then
                    # Fichier manquant sur la VM
                    missing_files=$((missing_files + 1))
                    if [[ "$VERBOSE" == true ]]; then
                        diff_details+="  ❌ MANQUANT: $target/$host_relpath\n"
                    fi
                else
                    local vm_size=$(echo "$vm_line" | awk '{print $1}')

                    if [[ "$host_size" != "$vm_size" ]]; then
                        # Tailles différentes = contenu différent
                        different_files=$((different_files + 1))
                        if [[ "$VERBOSE" == true ]]; then
                            diff_details+="  ⚠️  DIFFÉRENT (taille): $target/$host_relpath ($host_size vs $vm_size)\n"
                        fi
                    else
                        # Même taille - vérifier le checksum pour être sûr
                        local full_host_path="$host_path/$host_relpath"
                        local full_vm_path="$vm_path/$host_relpath"

                        local host_md5=$(md5sum "$full_host_path" 2>/dev/null | cut -d' ' -f1 || echo "")
                        local vm_md5=$(run_cmd "md5sum '$full_vm_path' 2>/dev/null | cut -d' ' -f1" || echo "")

                        if [[ "$host_md5" == "$vm_md5" ]]; then
                            identical_files=$((identical_files + 1))
                        else
                            different_files=$((different_files + 1))
                            if [[ "$VERBOSE" == true ]]; then
                                diff_details+="  ⚠️  DIFFÉRENT (contenu): $target/$host_relpath\n"
                            fi
                        fi
                    fi
                fi
            done < "$host_file"

            # Vérifier les fichiers présents uniquement sur la VM (fichiers orphelins)
            while IFS=' ' read -r vm_size vm_relpath; do
                [[ -z "$vm_relpath" ]] && continue
                if ! grep -qE "^[0-9]+ ${vm_relpath}$" "$host_file" 2>/dev/null; then
                    # Fichier présent uniquement sur la VM (pas forcément un problème)
                    if [[ "$VERBOSE" == true ]]; then
                        diff_details+="  ℹ️  VM-ONLY: $target/$vm_relpath\n"
                    fi
                fi
            done < "$vm_file"
        fi
    done

    # Résultats - identité uniquement (deep verify = comparaison avec hôte)
    if [[ $total_files -eq 0 ]]; then
        add_result "deep" "Fichiers" "warn" "Aucun fichier à comparer" "ident"
        return
    fi

    local match_percent=$((identical_files * 100 / total_files))

    if [[ $different_files -eq 0 ]] && [[ $missing_files -eq 0 ]]; then
        add_result "deep" "Contenu" "ok" "$identical_files/$total_files fichiers identiques (100%)" "ident"
    elif [[ $match_percent -ge 95 ]]; then
        add_result "deep" "Contenu" "ok" "$identical_files/$total_files identiques ($match_percent%)" "ident"
        add_result "deep" "Différences" "warn" "$different_files différents, $missing_files manquants" "ident"
    elif [[ $match_percent -ge 80 ]]; then
        add_result "deep" "Contenu" "warn" "$identical_files/$total_files identiques ($match_percent%)" "ident"
        add_result "deep" "Différences" "warn" "$different_files différents, $missing_files manquants" "ident"
    else
        add_result "deep" "Contenu" "fail" "$identical_files/$total_files identiques ($match_percent%)" "ident"
        add_result "deep" "Différences" "fail" "$different_files différents, $missing_files manquants" "ident"
    fi

    # Afficher les détails si verbose ou s'il y a des différences significatives
    if [[ -n "$diff_details" ]] && { [[ "$VERBOSE" == true ]] || [[ $different_files -gt 5 ]] || [[ $missing_files -gt 5 ]]; }; then
        echo ""
        echo "     Détails des différences (échantillon):"
        echo -e "$diff_details" | head -20
        if [[ $(echo -e "$diff_details" | wc -l) -gt 20 ]]; then
            echo "     ... et $(($(echo -e "$diff_details" | wc -l) - 20)) autres"
        fi
    fi
}

# ============================================================
# RAPPORT
# ============================================================

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════"
    if [[ "$COMPARE_CONTENT" == true ]]; then
        echo "   VERIFICATION VM CLONE - DEEP VERIFY REPORT"
    else
        echo "     VERIFICATION VM CLONE - RAPPORT COMPLET"
    fi
    echo "═══════════════════════════════════════════════════"

    if [[ "$SELF_CHECK" == true ]]; then
        echo "Mode: Self-check (depuis la VM)"
    else
        echo "Mode: Vérification distante via SSH"
        echo "VM:   $VM_NAME ($VM_IP)"
    fi
    if [[ "$COMPARE_CONTENT" == true ]]; then
        echo "Deep: Comparaison contenu fichiers activée"
    fi
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
}

print_footer() {
    echo ""

    # Afficher les différences attendues si présentes
    if [[ -n "$EXPECTED_DIFFS" ]]; then
        echo -e "${BOLD}📋 Différences attendues (adaptations VM)${NC}"
        echo -e "$EXPECTED_DIFFS"
    fi

    echo "═══════════════════════════════════════════════════"

    # Calcul des deux scores
    local func_score=0
    local ident_score=0
    [[ $FUNC_TOTAL -gt 0 ]] && func_score=$((FUNC_PASSED * 100 / FUNC_TOTAL))
    [[ $IDENT_TOTAL -gt 0 ]] && ident_score=$((IDENT_PASSED * 100 / IDENT_TOTAL))

    # Status basé sur le score fonctionnel
    local status
    if [[ $func_score -ge 90 ]]; then
        status="${GREEN}PRÊT POUR UTILISATION${NC}"
    elif [[ $func_score -ge 70 ]]; then
        status="${YELLOW}VÉRIFICATIONS RECOMMANDÉES${NC}"
    else
        status="${RED}PROBLÈMES DÉTECTÉS${NC}"
    fi

    # Affichage des deux scores
    printf "%-20s ${BOLD}%3d/100${NC}  (%d/%d) - VM opérationnelle?\n" "🔧 FONCTIONNEL:" "$func_score" "$FUNC_PASSED" "$FUNC_TOTAL"
    printf "%-20s ${BOLD}%3d/100${NC}  (%d/%d) - Clone fidèle?\n" "🔄 IDENTITÉ:" "$ident_score" "$IDENT_PASSED" "$IDENT_TOTAL"
    echo ""
    echo -e "STATUS: $status"
    echo "═══════════════════════════════════════════════════"

    if [[ -n "$REPORT_FILE" ]]; then
        echo ""
        echo "Détails complets : $REPORT_FILE"
    fi
}

save_report() {
    if [[ "$SAVE_REPORT" != true ]]; then
        return
    fi

    local docs_dir
    if [[ "$SELF_CHECK" == true ]]; then
        docs_dir="/home/$VM_USER/dev/fedora-setup/docs"
    else
        docs_dir="$(dirname "$0")/../../docs"
    fi

    mkdir -p "$docs_dir"
    REPORT_FILE="$docs_dir/vm-verification-report-$(date +%Y%m%d-%H%M).txt"

    # Sauvegarder stdout dans le fichier
    exec > >(tee "$REPORT_FILE")
}

# ============================================================
# MAIN
# ============================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--vm)
                VM_NAME="$2"
                shift 2
                ;;
            -i|--ip)
                VM_IP="$2"
                shift 2
                ;;
            -u|--user)
                VM_USER="$2"
                shift 2
                ;;
            -s|--self-check)
                SELF_CHECK=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --quick)
                QUICK=true
                shift
                ;;
            --save-report)
                SAVE_REPORT=true
                shift
                ;;
            --compare-packages)
                COMPARE_PACKAGES=true
                shift
                ;;
            --compare-content)
                COMPARE_CONTENT=true
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

main() {
    parse_args "$@"

    # Détection automatique du mode
    if [[ "$SELF_CHECK" != true ]] && detect_vm_environment; then
        log_info "Environnement VM détecté, passage en mode self-check"
        SELF_CHECK=true
    fi

    # Configuration selon le mode
    if [[ "$SELF_CHECK" != true ]]; then
        # Mode hôte -> VM via SSH
        if [[ $EUID -ne 0 ]]; then
            # Pas besoin de root pour SSH mais utile pour virsh
            log_warn "Sans root, la détection d'IP peut échouer"
        fi

        # Vérifier que la VM existe et est running
        local vm_state
        vm_state=$(LANG=C virsh -c qemu:///system domstate "$VM_NAME" 2>/dev/null | tr -d '[:space:]')
        if [[ -z "$vm_state" ]]; then
            log_error "VM '$VM_NAME' introuvable"
            log_info "VMs disponibles:"
            virsh -c qemu:///system list --all 2>/dev/null | tail -n +3 || true
            exit 1
        fi
        if [[ "$vm_state" != "running" ]]; then
            log_error "VM '$VM_NAME' n'est pas en cours d'exécution (état: $vm_state)"
            log_info "Démarrez-la avec: virsh start $VM_NAME"
            exit 1
        fi

        get_vm_ip
        check_ssh_connection
    fi

    # Sauvegarder le rapport si demandé
    if [[ "$SAVE_REPORT" == true ]]; then
        save_report
    fi

    # Afficher l'en-tête
    print_header

    # Exécuter les vérifications
    check_system_base
    check_desktop_hyprland
    check_python_env
    check_claude_code
    check_projects_structure
    check_packages
    check_systemd_services
    check_network
    check_dotfiles
    check_file_content_deep

    # Afficher le résumé
    print_footer
}

main "$@"
