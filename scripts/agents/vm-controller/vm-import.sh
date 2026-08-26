#!/usr/bin/env bash
#
# vm-import.sh - Import d'une VM KVM depuis une archive exportee par vm-export.sh
#
# Usage: vm-import.sh <archive.tar.gz> [OPTIONS]
#
# Exit codes:
#   0 = Succes
#   1 = Erreur generique
#   3 = Dependances manquantes
#   4 = Espace insuffisant
#   5 = Verification echouee
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ==============================================
# Configuration
# ==============================================

NEW_NAME=""
POOL_DIR="/var/lib/libvirt/images"
START_AFTER=false
DRY_RUN=false
MIN_FREE_GB=5

# ==============================================
# Aide
# ==============================================

usage() {
    cat << EOF
Usage: $(basename "$0") <archive.tar.gz> [OPTIONS]

Importe une VM KVM depuis une archive creee par vm-export.sh.

Arguments:
    archive.tar.gz   Archive .tar.gz generee par vm-export.sh

Options:
    --name=NOM      Nom de la nouvelle VM (defaut: nom dans l'archive)
    --pool=DIR      Dossier images libvirt (defaut: /var/lib/libvirt/images)
    --start         Demarrer la VM apres import et attendre SSH
    --dry-run       Simuler sans modifier le systeme
    -h, --help      Afficher cette aide

Exit codes:
    0 = Succes
    1 = Erreur generique
    3 = Dependances manquantes
    4 = Espace insuffisant
    5 = Verification echouee

Exemples:
    $(basename "$0") preprod-01-export-20260226-120000-classic.tar.gz
    $(basename "$0") vm.tar.gz --name=mon-import --start
    $(basename "$0") vm.tar.gz --pool=/data/images --dry-run

EOF
}

# ==============================================
# Parse des arguments
# ==============================================

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                usage
                exit 0
                ;;
        esac
    done

    ARCHIVE_PATH="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name=*)
                NEW_NAME="${1#*=}"
                if [[ ! "$NEW_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
                    log_error "Nom invalide: '$NEW_NAME'"
                    exit 1
                fi
                shift
                ;;
            --pool=*)
                POOL_DIR="${1#*=}"
                shift
                ;;
            --start)
                START_AFTER=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
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

# ==============================================
# Fonctions utilitaires
# ==============================================

check_import_dependencies() {
    local missing=()
    for cmd in qemu-img python3; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dependances manquantes: ${missing[*]}"
        return 3
    fi
    return 0
}

# Generer un MAC address aleatoire au format libvirt (52:54:00:xx:xx:xx)
generate_mac() {
    printf '52:54:00:%02x:%02x:%02x' \
        $(( RANDOM % 256 )) \
        $(( RANDOM % 256 )) \
        $(( RANDOM % 256 ))
}

# ==============================================
# Etape 1: Pre-test import
# ==============================================

pretest_import() {
    local archive="$1"

    log_step "[PRE-TEST] Verification de l'archive: $archive"

    # 1. Dependances
    check_import_dependencies || return $?

    # 2. Archive existe et lisible
    if [[ ! -f "$archive" ]]; then
        log_error "Archive introuvable: $archive"
        return 1
    fi
    if [[ ! -r "$archive" ]]; then
        log_error "Archive non lisible: $archive"
        return 1
    fi

    local archive_size
    archive_size=$(du -sh "$archive" 2>/dev/null | cut -f1 || echo "?")
    log_info "Archive: $archive ($archive_size)"

    # 3. Lister le contenu (head -20 : arret rapide, evite de decompresser tout l'archive)
    log_step "Lecture du contenu de l'archive (rapide)..."
    local files
    files=$(tar tzf "$archive" 2>/dev/null | head -20) || true
    if [[ -z "$files" ]]; then
        log_error "Archive corrompue ou format invalide (aucun fichier lu)"
        return 5
    fi
    log_ok "Archive lisible"

    # 4. Detecter le nom de la VM

    # Detecter le nom du qcow2 dans l'archive
    ARCHIVE_VM_NAME=$(echo "$files" | grep '\.qcow2$' | head -1 | sed 's/\.qcow2$//')
    if [[ -z "$ARCHIVE_VM_NAME" ]]; then
        log_error "Pas de fichier .qcow2 dans l'archive"
        return 5
    fi

    # Verifier presence du XML
    if ! echo "$files" | grep -q "^${ARCHIVE_VM_NAME}\.xml$"; then
        log_error "Fichier XML manquant dans l'archive: ${ARCHIVE_VM_NAME}.xml"
        return 5
    fi
    log_ok "Contenu valide: ${ARCHIVE_VM_NAME}.qcow2 + ${ARCHIVE_VM_NAME}.xml"
    log_info "VM detectee dans l'archive: $ARCHIVE_VM_NAME"

    # Lire et afficher le manifest.json si present
    if echo "$files" | grep -q "^manifest\.json$"; then
        local tmp_manifest
        tmp_manifest=$(mktemp)
        tar xzf "$archive" -O manifest.json > "$tmp_manifest" 2>/dev/null || true
        if [[ -s "$tmp_manifest" ]]; then
            local exported_at source_vm mode sanitized firstboot_required format_version
            exported_at=$(python3 -c "import json,sys; d=json.load(open('$tmp_manifest')); print(d.get('exported_at','?'))" 2>/dev/null || echo "?")
            source_vm=$(python3 -c "import json,sys; d=json.load(open('$tmp_manifest')); print(d.get('source_vm','?'))" 2>/dev/null || echo "?")
            mode=$(python3 -c "import json,sys; d=json.load(open('$tmp_manifest')); print(d.get('mode','?'))" 2>/dev/null || echo "?")
            sanitized=$(python3 -c "import json,sys; d=json.load(open('$tmp_manifest')); print(d.get('sanitized','?'))" 2>/dev/null || echo "?")
            firstboot_required=$(python3 -c "import json,sys; d=json.load(open('$tmp_manifest')); print(d.get('firstboot_required',False))" 2>/dev/null || echo "False")
            format_version=$(python3 -c "import json,sys; d=json.load(open('$tmp_manifest')); print(d.get('format_version','?'))" 2>/dev/null || echo "?")
            log_info "--- manifest.json ---"
            log_info "  Export: $exported_at"
            log_info "  VM source: $source_vm  |  Mode: $mode"
            log_info "  Sanitise: $sanitized  |  Format: v$format_version"
            if [[ "$firstboot_required" == "True" ]]; then
                log_warn "  firstboot_required=true: un script de configuration s'executera"
                log_warn "  au PREMIER DEMARRAGE de cette VM (connexion console requise)"
            fi
            log_info "---------------------"
        fi
        rm -f "$tmp_manifest"
    else
        log_debug "Pas de manifest.json dans l'archive (archive ancienne)"
    fi

    # 5. Nom final de la VM
    if [[ -z "$NEW_NAME" ]]; then
        NEW_NAME="$ARCHIVE_VM_NAME"
    fi
    log_info "Nom de la VM apres import: $NEW_NAME"

    # 6. Verifier que le nom n'est pas deja pris
    if $VIRSH dominfo "$NEW_NAME" &>/dev/null 2>&1; then
        # Verifier si c'est une VM orpheline (definie mais sans disque)
        local existing_disk
        existing_disk=$($VIRSH domblklist "$NEW_NAME" 2>/dev/null | awk 'NR>2 && $2 != "-" {print $2}' | head -1)
        if [[ -n "$existing_disk" && ! -f "$existing_disk" ]]; then
            log_warn "VM '$NEW_NAME' definie mais son disque est absent ($existing_disk)"
            log_warn "Nettoyage automatique de la definition orpheline..."
            if $VIRSH undefine "$NEW_NAME" --nvram &>/dev/null 2>&1 || $VIRSH undefine "$NEW_NAME" &>/dev/null 2>&1; then
                log_ok "Definition orpheline supprimee, l'import peut continuer"
            else
                log_error "Impossible de supprimer la definition orpheline de '$NEW_NAME'"
                return 1
            fi
        else
            log_error "Une VM nommee '$NEW_NAME' existe deja (avec disque actif)."
            log_error "Utilisez --name=NOUVEAU_NOM pour choisir un autre nom."
            return 1
        fi
    fi

    # 7. Espace disque
    local archive_raw_gb
    archive_raw_gb=$(du -BG "$archive" 2>/dev/null | awk '{gsub("G",""); print int($1)}' || echo 1)
    # Estimation: qcow2 decompresse ~2x l'archive pour l'extraction + ~2x pour le pool
    local needed_extract_gb=$(( archive_raw_gb * 2 + MIN_FREE_GB ))
    local needed_pool_gb=$(( archive_raw_gb * 2 + MIN_FREE_GB ))

    # Espace dossier extraction (meme partition que l'archive)
    local archive_dir
    archive_dir=$(dirname "$(realpath "$archive")")
    local free_extract_gb
    free_extract_gb=$(df -BG "$archive_dir" 2>/dev/null | awk 'NR==2{gsub("G",""); print int($4)}' || echo 0)
    log_info "Extraction: besoin ~${needed_extract_gb} Go, dispo dans $archive_dir: ${free_extract_gb} Go"
    if [[ $free_extract_gb -lt $needed_extract_gb ]]; then
        log_error "Espace insuffisant pour extraction dans $archive_dir"
        log_error "  Disponible: ${free_extract_gb} Go  |  Requis: ~${needed_extract_gb} Go"
        return 4
    fi

    # Espace pool libvirt (utilise le premier parent existant si POOL_DIR n'existe pas encore)
    local df_target="$POOL_DIR"
    while [[ ! -d "$df_target" ]] && [[ "$df_target" != "/" ]]; do
        df_target=$(dirname "$df_target")
    done
    local free_pool_gb
    free_pool_gb=$(df -BG "$df_target" 2>/dev/null | awk 'NR==2{gsub("G",""); print int($4)}' || echo 0)
    log_info "Pool libvirt: besoin ~${needed_pool_gb} Go, dispo dans $df_target: ${free_pool_gb} Go"
    if [[ $free_pool_gb -lt $needed_pool_gb ]]; then
        log_error "Espace insuffisant dans le pool libvirt $POOL_DIR"
        log_error "  Disponible: ${free_pool_gb} Go  |  Requis: ~${needed_pool_gb} Go"
        return 4
    fi
    log_ok "Espace disque: OK (extraction: ${free_extract_gb} Go, pool: ${free_pool_gb} Go)"

    log_ok "[PRE-TEST] Verifications passees"
    return 0
}

# ==============================================
# Etape 2: Extraction + verification qcow2
# ==============================================

extract_archive() {
    local archive="$1"
    local work_dir="$2"

    local archive_bytes
    archive_bytes=$(stat -c%s "$archive" 2>/dev/null || echo 1)
    local archive_human
    archive_human=$(du -sh "$archive" | cut -f1)
    log_step "Extraction de l'archive ($archive_human compressed)..."
    log_info "Destination: $work_dir"
    _lyra_progress 2 5 "Extraction archive" 0 0 0

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] tar xzf $archive (simule)"
        touch "${work_dir}/${ARCHIVE_VM_NAME}.qcow2"
        echo "<domain type='kvm'><name>${ARCHIVE_VM_NAME}</name></domain>" \
            > "${work_dir}/${ARCHIVE_VM_NAME}.xml"
        return 0
    fi

    # Lancer tar en arriere-plan et suivre la taille du qcow2 extrait
    tar xzf "$archive" -C "$work_dir" &
    local tar_pid=$!

    log_info "Extraction en cours (PID $tar_pid)..."
    local expected_qcow="${work_dir}/${ARCHIVE_VM_NAME}.qcow2"
    # Estimation : qcow2 decompresse ~2x l'archive compressee (conservateur)
    local estimated_bytes=$(( archive_bytes * 2 ))

    while kill -0 "$tar_pid" 2>/dev/null; do
        local out_bytes=0
        [ -f "$expected_qcow" ] && out_bytes=$(stat -c%s "$expected_qcow" 2>/dev/null || echo 0) || true
        local gb_done gb_total pct
        gb_done=$(awk "BEGIN{printf \"%.1f\", $out_bytes/1073741824}")
        gb_total=$(awk "BEGIN{printf \"%.1f\", $estimated_bytes/1073741824}")
        pct=0
        [ "$estimated_bytes" -gt 0 ] && pct=$(( out_bytes * 100 / estimated_bytes )) || true
        [ "$pct" -gt 95 ] && pct=95 || true
        _lyra_progress 2 5 "Extraction archive" "$pct" "$gb_done" "$gb_total"
        sleep 1
    done

    local tar_rc=0
    wait "$tar_pid" || tar_rc=$?
    if [[ $tar_rc -ne 0 ]]; then
        log_error "Echec de l'extraction (code $tar_rc) - espace disque insuffisant ?"
        return 1
    fi

    log_ok "Archive extraite dans $work_dir"
    _lyra_progress 2 5 "Extraction archive" 100 0 0

    # Verification integrite du qcow2 extrait
    log_step "Verification integrite du disque extrait..."
    local check_result filtered_result
    check_result=$(qemu-img check -q "${work_dir}/${ARCHIVE_VM_NAME}.qcow2" 2>&1) || true
    filtered_result=$(echo "$check_result" | grep -v \
        -e "OFLAG_COPIED" \
        -e "counting reference for region exceeding" \
        -e "refcount block.*outside image" \
        -e "ERROR refcount block" \
        || true)
    if echo "$filtered_result" | grep -q "errors were found"; then
        log_error "Disque extrait corrompu: $filtered_result"
        return 5
    elif [ -n "$(echo "$filtered_result" | grep -i 'error\|warn')" ]; then
        log_warn "Avertissement disque (non bloquant): $filtered_result"
    else
        log_ok "Disque extrait: integrite verifiee"
    fi
}

# ==============================================
# Etape 3: Installation du disque
# ==============================================

_cp_with_progress() {
    local step=$1 total=$2 src=$3 dst=$4
    local src_bytes src_gb
    src_bytes=$(stat -c%s "$src" 2>/dev/null || echo 0)
    src_gb=$(awk "BEGIN{printf \"%.1f\", $src_bytes/1073741824}")

    cp "$src" "$dst" &
    local cpid=$!

    while kill -0 "$cpid" 2>/dev/null; do
        local dst_bytes=0 pct=0 gb_done=0
        [ -f "$dst" ] && dst_bytes=$(stat -c%s "$dst" 2>/dev/null || echo 0)
        [ "$src_bytes" -gt 0 ] && pct=$((dst_bytes * 100 / src_bytes))
        gb_done=$(awk "BEGIN{printf \"%.1f\", $dst_bytes/1073741824}")
        _lyra_progress "$step" "$total" "Copie disque" "$pct" "$gb_done" "$src_gb"
        sleep 0.8
    done

    wait "$cpid"
}

install_disk() {
    local src_disk="$1"
    local dst_disk="$2"

    log_step "Copie du disque vers $POOL_DIR..."
    log_info "  Source : $src_disk"
    log_info "  Destination : $dst_disk"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] cp $src_disk $dst_disk (simule)"
        return 0
    fi

    if [[ -f "$dst_disk" ]]; then
        log_error "Un disque existe deja: $dst_disk"
        log_error "Supprimez-le ou utilisez --name=AUTRE_NOM"
        return 1
    fi

    # Copie du disque dans le pool libvirt (script doit tourner en root)
    mkdir -p "$POOL_DIR"
    _cp_with_progress 3 5 "$src_disk" "$dst_disk"
    # Permissions correctes pour libvirt
    chmod 640 "$dst_disk" 2>/dev/null || true
    chown root:root "$dst_disk" 2>/dev/null || true

    local disk_size
    disk_size=$(du -sh "$dst_disk" | cut -f1)
    log_ok "Disque installe: $dst_disk ($disk_size)"
}

# ==============================================
# Etape 4: Patch du XML (UUID, MAC, chemin disque, nom)
# ==============================================

patch_xml() {
    local src_xml="$1"
    local dst_xml="$2"
    local vm_name="$3"
    local disk_path="$4"
    local new_uuid new_mac

    new_uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
    new_mac=$(generate_mac)

    log_step "Patch du XML: nom=$vm_name, uuid=$new_uuid, mac=$new_mac"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] patch XML (simule)"
        cp "$src_xml" "$dst_xml"
        return 0
    fi

    python3 << PYTHON_EOF
import xml.etree.ElementTree as ET
import sys

try:
    tree = ET.parse('$src_xml')
    root = tree.getroot()
except ET.ParseError as e:
    print(f"Erreur XML: {e}", file=sys.stderr)
    sys.exit(1)

# 1. Nom de la VM
name_elem = root.find('name')
if name_elem is not None:
    name_elem.text = '$vm_name'
else:
    name_elem = ET.SubElement(root, 'name')
    name_elem.text = '$vm_name'

# 2. Nouveau UUID
uuid_elem = root.find('uuid')
if uuid_elem is not None:
    uuid_elem.text = '$new_uuid'
else:
    # Inserer avant le premier enfant
    uuid_elem = ET.Element('uuid')
    uuid_elem.text = '$new_uuid'
    root.insert(1, uuid_elem)

# 3. Nouveau MAC address
for interface in root.findall('.//devices/interface'):
    mac_elem = interface.find('mac')
    if mac_elem is not None:
        mac_elem.set('address', '$new_mac')
    else:
        mac_elem = ET.SubElement(interface, 'mac')
        mac_elem.set('address', '$new_mac')

# 4. Chemin reel du disque
for source in root.findall('.//devices/disk/source'):
    current = source.get('file', '')
    if '__DISK_PATH__' in current or current.endswith('.qcow2'):
        source.set('file', '$disk_path')

# 5. Mettre a jour le chemin NVRAM (EFI vars) pour la nouvelle VM
# Le template OVMF reste mais le fichier vars est renomme avec le nouveau nom
os_elem = root.find('os')
if os_elem is not None:
    nvram_elem = os_elem.find('nvram')
    if nvram_elem is not None:
        nvram_elem.text = '/var/lib/libvirt/qemu/nvram/$vm_name' + '_VARS.qcow2'

# Ecrire le XML patche
ET.indent(root, space='  ')
with open('$dst_xml', 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    ET.indent(root)
    tree.write(f, encoding='unicode', xml_declaration=False)

print("[OK] XML patche: nom=$vm_name, uuid=$new_uuid, mac=$new_mac")
PYTHON_EOF

    log_ok "XML patche: $dst_xml"
}

# ==============================================
# Etape 5: Definition de la VM avec virsh
# ==============================================

define_vm() {
    local xml_path="$1"
    local vm_name="$2"

    log_step "Definition de la VM '$vm_name' avec virsh..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] virsh define $xml_path (simule)"
        return 0
    fi

    if ! $VIRSH define "$xml_path" &>/dev/null; then
        log_error "Echec de virsh define. Verifier le XML: $xml_path"
        # Afficher les erreurs virsh pour le debug
        $VIRSH define "$xml_path" 2>&1 | head -20 >&2 || true
        return 1
    fi

    log_ok "VM '$vm_name' definie dans libvirt"
}

# ==============================================
# Etape 6: Post-test import
# ==============================================

posttest_import() {
    local vm_name="$1"
    local disk_path="$2"

    log_step "[POST-TEST] Verification de l'import"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] verification (simulee)"
        log_ok "[POST-TEST] OK (dry-run)"
        return 0
    fi

    # 1. VM presente dans virsh
    log_step "Verification presence VM dans libvirt..."
    if ! $VIRSH dominfo "$vm_name" &>/dev/null 2>&1; then
        log_error "VM '$vm_name' non trouvee dans libvirt apres import"
        return 5
    fi
    log_ok "VM '$vm_name' presente dans libvirt"
    _lyra_progress 5 5 "Verification finale" 30 0 0

    # 2. Disque existe et lisible
    if [[ ! -f "$disk_path" ]]; then
        log_error "Disque manquant apres import: $disk_path"
        return 5
    fi
    local disk_human
    disk_human=$(du -sh "$disk_path" | cut -f1)
    log_ok "Disque present: $disk_path ($disk_human)"
    _lyra_progress 5 5 "Verification finale" 60 0 0

    # 3. Integrite finale du disque
    log_step "Verification integrite du disque installe..."
    local check_result filtered_result
    check_result=$(qemu-img check -q "$disk_path" 2>&1) || true
    filtered_result=$(echo "$check_result" | grep -v \
        -e "OFLAG_COPIED" \
        -e "counting reference for region exceeding" \
        -e "refcount block.*outside image" \
        -e "ERROR refcount block" \
        || true)
    if echo "$filtered_result" | grep -q "errors were found"; then
        log_error "Disque installe corrompu: $filtered_result"
        return 5
    elif [ -n "$(echo "$filtered_result" | grep -i 'error\|warn')" ]; then
        log_warn "Avertissement disque (non bloquant): $filtered_result"
    else
        log_ok "Disque installe: integrite verifiee"
    fi
    _lyra_progress 5 5 "Verification finale" 80 0 0

    # 4. Etat de la VM
    local vm_state
    vm_state=$($VIRSH domstate "$vm_name" 2>/dev/null)
    log_info "Etat VM: $vm_state"

    # 5. Optionnel: demarrer et attendre SSH
    if [[ "$START_AFTER" == true ]]; then
        log_step "Demarrage de la VM '$vm_name'..."
        if $VIRSH start "$vm_name" &>/dev/null; then
            log_ok "VM demarree"
            log_step "Attente SSH (timeout: 120s)..."
            if wait_ssh "$vm_name" 120; then
                log_ok "SSH accessible"
            else
                log_warn "SSH non accessible apres 120s (la VM est demarree mais SSH peut prendre plus de temps)"
            fi
        else
            log_warn "Echec du demarrage (la VM est bien definie, demarrage manuel requis)"
        fi
    fi

    log_ok "[POST-TEST] Import valide avec succes"
    return 0
}

# ==============================================
# Fonction principale
# ==============================================

main() {
    parse_args "$@"

    log_info "============================================"
    log_info " VM IMPORT - $(basename "$ARCHIVE_PATH")"
    log_info "============================================"
    [[ "$DRY_RUN" == true ]] && log_warn "MODE DRY-RUN: aucune modification ne sera faite"

    # Dossier de travail temporaire dans le meme dossier que l'archive
    # (independant de $HOME - fonctionne que le script tourne en root ou non)
    local import_tmp_base
    import_tmp_base=$(dirname "$(realpath "$ARCHIVE_PATH")")
    local work_dir
    work_dir=$(mktemp -d "${import_tmp_base}/.vm-import-work-XXXXXX")

    # Nettoyage en cas d'erreur
    trap 'rc=$?; log_warn "Nettoyage du dossier temporaire..."; rm -rf "$work_dir"; exit $rc' EXIT

    # ---- Etape 1: Pre-test ----
    # (initialise aussi ARCHIVE_VM_NAME et NEW_NAME)
    _lyra_progress 1 5 "Verification archive" 10 0 0
    if ! pretest_import "$ARCHIVE_PATH"; then
        exit $?
    fi
    _lyra_progress 1 5 "Verification archive" 100 0 0

    # Chemins finaux
    local final_disk="${POOL_DIR}/${NEW_NAME}.qcow2"
    local patched_xml="${work_dir}/${NEW_NAME}-patched.xml"

    # ---- Etape 2: Extraction + check qcow2 ----
    if ! extract_archive "$ARCHIVE_PATH" "$work_dir"; then
        exit $?
    fi

    # ---- Etape 3: Installation disque ----
    if ! install_disk "${work_dir}/${ARCHIVE_VM_NAME}.qcow2" "$final_disk"; then
        exit 1
    fi

    # ---- Etape 4: Configuration VM (patch XML + define virsh) ----
    _lyra_progress 4 5 "Configuration VM" 10 0 0
    if ! patch_xml \
        "${work_dir}/${ARCHIVE_VM_NAME}.xml" \
        "$patched_xml" \
        "$NEW_NAME" \
        "$final_disk"; then
        rm -f "$final_disk"
        exit 1
    fi
    _lyra_progress 4 5 "Configuration VM" 60 0 0

    if ! define_vm "$patched_xml" "$NEW_NAME"; then
        rm -f "$final_disk"
        exit 1
    fi
    _lyra_progress 4 5 "Configuration VM" 100 0 0

    # ---- Etape 5: Verification finale ----
    _lyra_progress 5 5 "Verification finale" 10 0 0
    if ! posttest_import "$NEW_NAME" "$final_disk"; then
        log_warn "Nettoyage: suppression de la definition virsh orpheline..."
        $VIRSH undefine "$NEW_NAME" --nvram &>/dev/null 2>&1 || $VIRSH undefine "$NEW_NAME" &>/dev/null 2>&1 || true
        rm -f "$final_disk" 2>/dev/null || true
        exit 5
    fi
    _lyra_progress 5 5 "Verification finale" 100 0 0

    # Succes
    log_info "============================================"
    log_ok " IMPORT TERMINE AVEC SUCCES"
    log_info "============================================"
    log_info " VM importee    : $NEW_NAME"
    log_info " Disque         : $final_disk"
    log_info " Demarrage      : virsh start $NEW_NAME"
    if [[ "$START_AFTER" == false ]]; then
        log_info ""
        log_info " Pour demarrer  : sudo virsh start $NEW_NAME"
        log_info " Pour voir      : virt-manager ou virt-viewer"
    fi
    log_info "============================================"

    # Output MCP
    echo "VM '$NEW_NAME' importee avec succes. Disque: $final_disk"

    trap - EXIT
    rm -rf "$work_dir"
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
