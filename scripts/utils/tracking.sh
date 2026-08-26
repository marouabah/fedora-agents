#!/usr/bin/env bash
#
# tracking.sh — Helper pour reporter la progression vers l'API tracking locale
# A sourcer depuis les scripts async : source "$(dirname "$0")/../utils/tracking.sh"
#
# API : http://127.0.0.1:8765  (tracking-api.service)
#
# Variables attendues dans le script parent :
#   TRACKING_ID    — ID de session (ex: c5e34745). Si vide, les fonctions sont no-op.
#
# Usage :
#   tracking_log   "message libre"
#   tracking_progress  <valeur> "message"       # met a jour processed + log
#   tracking_extra "cle" "valeur"               # met a jour un champ extra
#   tracking_item  "nom de l'item" <status>     # done | running | error | pending
#   tracking_done  "message final"              # status -> done
#   tracking_error "message erreur"             # status -> error
#

TRACKING_API="${TRACKING_API:-http://127.0.0.1:8765}"

# Cree une nouvelle session de tracking et exporte TRACKING_ID
# Usage: tracking_init "Nom de la tache" "template" total "unite"
# Exemple: tracking_init "Clone neutron-template" "machine" 100 " %"
tracking_init() {
    local name="$1"
    local template="${2:-machine}"
    local total="${3:-100}"
    local unit="${4:- %}"

    local payload
    payload="{\"name\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$name"), \
\"template\": \"$template\", \"total\": $total, \"unit\": \"$unit\"}"

    local response
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${TRACKING_API}/sessions" \
        --max-time 3 2>/dev/null || echo "{}")

    local sid
    sid=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" <<< "$response" 2>/dev/null || echo "")

    if [[ -n "$sid" ]]; then
        export TRACKING_ID="$sid"
        echo "$sid"
    fi
}

# Envoie un PUT silencieux, ignore les erreurs reseau pour ne pas bloquer le script
_tracking_put() {
    local payload="$1"
    [[ -z "${TRACKING_ID:-}" ]] && return 0
    curl -s -o /dev/null \
        -X PUT \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${TRACKING_API}/sessions/${TRACKING_ID}" \
        --max-time 2 \
        2>/dev/null || true
}

# Ajoute une ligne de log a la session
tracking_log() {
    local message="$1"
    _tracking_put "{\"log\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$message")}"
}

# Met a jour la progression + ajoute un log
tracking_progress() {
    local value="$1"
    local message="${2:-}"
    local payload="{\"processed\": ${value}"
    if [[ -n "$message" ]]; then
        payload+=", \"log\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$message")"
    fi
    payload+="}"
    _tracking_put "$payload"
}

# Met a jour un champ extra (ex: tracking_extra "phase" "rsync en cours")
tracking_extra() {
    local key="$1"
    local value="$2"
    _tracking_put "{\"extra\": {\"${key}\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$value")}}"
}

# Met a jour le statut d'un item par son nom
# status: done | running | error | pending
tracking_item() {
    local name="$1"
    local status="$2"
    local note="${3:-}"
    local item_payload="{\"name\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$name"), \"status\": \"${status}\""
    if [[ -n "$note" ]]; then
        item_payload+=", \"note\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$note")"
    fi
    item_payload+="}"
    _tracking_put "{\"item\": ${item_payload}}"
}

# Marque la session comme terminee avec succes
tracking_done() {
    local message="${1:-Termine}"
    _tracking_put "{\"status\": \"done\", \"log\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$message")}"
}

# Marque la session en erreur
tracking_error() {
    local message="${1:-Erreur}"
    _tracking_put "{\"status\": \"error\", \"log\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$message")}"
}
