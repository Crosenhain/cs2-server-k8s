#!/bin/bash
# Indented 8 spaces to be safe
export RCON_HOST=${RCON_HOST:-"cs2-service"}
export RCON_PORT=${RCON_PORT:-${CS2_PORT:-27015}}
export RCON_PASSWORD=${RCON_PASSWORD}
BLIND_RESTART_AFTER=${WATCHER_BLIND_RESTART_AFTER:-4}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# Overridable so the script can be exercised outside the pod; the defaults are
# what it always uses in-cluster.
SERVER_DIR=${SERVER_DIR:-"/home/steam/cs2"}
SA_DIR=${SA_DIR:-"/var/run/secrets/kubernetes.io/serviceaccount"}
KUBE_API=${KUBE_API:-"https://kubernetes.default.svc"}
CS2_APPID=730

echo "[Watcher] Starting check..."
echo "[Watcher] Debug: Contents of $SERVER_DIR:"
ls -F "$SERVER_DIR" | head -n 10

# Find manifest file
MANIFEST_FILE=$(find "$SERVER_DIR" -name "appmanifest_${CS2_APPID}.acf" | head -n 1)
if [ -f "$MANIFEST_FILE" ]; then
    LOCAL_BUILD_ID=$(grep 'buildid' "$MANIFEST_FILE" | grep -oP '"buildid"\s*"\K\d+' | tr -d '\r\n')
    echo "[Watcher] Found manifest: $MANIFEST_FILE (Local ID: $LOCAL_BUILD_ID)"
else
    echo "[Watcher] Warning: appmanifest_${CS2_APPID}.acf not found."
    echo "[Watcher] Debug: Contents of $SERVER_DIR/steamapps:"
    ls -F "$SERVER_DIR/steamapps" 2>/dev/null | head -n 10
fi

# Try local steamcmd
STEAMCMD_BIN=$(command -v steamcmd || echo "/home/steam/steamcmd/steamcmd.sh")
if [ -f "$STEAMCMD_BIN" ] || command -v steamcmd >/dev/null; then
    REMOTE_BUILD_ID=$("$STEAMCMD_BIN" +login anonymous +app_info_print $CS2_APPID +quit | grep -A 5 'public' | grep 'buildid' | grep -oP '\d+' | tr -d '\r\n')
fi

# Fallback to Web API with correct JSON path and User-Agent
if [ -z "$REMOTE_BUILD_ID" ]; then
    echo "[Watcher] steamcmd failed. Trying Web API..."
    REMOTE_BUILD_ID=$(python3 -c "import urllib.request, json; req = urllib.request.Request('https://api.steamcmd.net/v1/info/730', headers={'User-Agent': 'Mozilla/5.0'}); print(json.loads(urllib.request.urlopen(req).read())['data']['730']['depots']['branches']['public']['buildid'])" 2>/dev/null)
fi

if [ -z "$LOCAL_BUILD_ID" ] || [ -z "$REMOTE_BUILD_ID" ]; then
    echo "[Watcher] Build ID missing. Skipping."
    exit 0
fi

echo "[Watcher] Local: $LOCAL_BUILD_ID, Remote: $REMOTE_BUILD_ID"

if [[ "$LOCAL_BUILD_ID" == "$REMOTE_BUILD_ID" ]]; then
    echo "[Watcher] Up to date."
    exit 0
fi

echo "🚨 [Watcher] Update available!"

TOKEN=$(cat "$SA_DIR/token")
CACERT="$SA_DIR/ca.crt"
DEPLOY_URL="$KUBE_API/apis/apps/v1/namespaces/__NAMESPACE__/deployments/__DEPLOYMENT__"
BUILD_ANNOTATION="cs2-watcher/last-restart-build"
FAIL_ANNOTATION="cs2-watcher/rcon-fail-count"

# Both markers live on the Deployment's own metadata, not the pod template, so
# writing them is not itself a template change that would trigger a rollout.
patch_deployment() {
    curl -s -o /dev/null -w '%{http_code}' -X PATCH \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/strategic-merge-patch+json" \
        --cacert "$CACERT" \
        -d "$1" \
        "$DEPLOY_URL"
}

set_fail_count() {
    local code
    code=$(patch_deployment "{\"metadata\":{\"annotations\":{\"$FAIL_ANNOTATION\":\"$1\"}}}")
    if [[ "$code" != 2?? ]]; then
        echo "[Watcher] WARNING: could not record RCON failure count (HTTP $code)."
    fi
}

# restartedAt goes on the pod template - that is what actually rolls the pod.
# The build marker and the reset fail count ride along on the Deployment's own
# metadata in the same request.
restart_server() {
    local date code
    date=$(date +%Y-%m-%dT%H:%M:%SZ)
    code=$(patch_deployment "{\"metadata\":{\"annotations\":{\"$BUILD_ANNOTATION\":\"$REMOTE_BUILD_ID\",\"$FAIL_ANNOTATION\":\"0\"}},\"spec\":{\"strategy\":{\"type\":\"Recreate\"},\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"$date\"}}}}}")
    if [[ "$code" != 2?? ]]; then
        echo "[Watcher] ERROR: restart patch failed with HTTP $code."
        return 1
    fi
    echo "[Watcher] Restarted for build $REMOTE_BUILD_ID (HTTP $code)."
    return 0
}

# One GET for both annotations.
ANNOTATIONS=$(curl -s -H "Authorization: Bearer $TOKEN" --cacert "$CACERT" "$DEPLOY_URL" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    a = d.get('metadata', {}).get('annotations', {}) or {}
except Exception:
    a = {}
print(a.get('$BUILD_ANNOTATION', ''))
print(a.get('$FAIL_ANNOTATION', '0') or '0')
" 2>/dev/null)
LAST_RESTART_BUILD=$(printf '%s\n' "$ANNOTATIONS" | head -n 1)
RCON_FAIL_COUNT=$(printf '%s\n' "$ANNOTATIONS" | head -n 2 | tail -n 1)
[[ "$RCON_FAIL_COUNT" =~ ^[0-9]+$ ]] || RCON_FAIL_COUNT=0

# A restart only helps if the pod actually picks the update up on boot. If we
# already restarted for this exact remote build and the install is still behind,
# the update is failing inside the pod - restarting again every run just kicks
# players in a loop and never converges.
if [[ "$LAST_RESTART_BUILD" == "$REMOTE_BUILD_ID" ]]; then
    echo "[Watcher] Already restarted for build $REMOTE_BUILD_ID, still installed at $LOCAL_BUILD_ID."
    echo "[Watcher] The update is failing inside the pod, not for want of a restart. Not restarting again."
    echo "[Watcher] Look for \"Error! App '730' state is 0x6\" in the server pod log, and"
    echo "[Watcher] /home/steam/Steam/logs/content_log.txt inside the pod for the reason."
    exit 0
fi

RCON_ERR=$(mktemp)
STATUS_OUT=$(python3 "$SCRIPT_DIR/rcon.py" status 2>"$RCON_ERR")
RCON_RC=$?

if [[ "$RCON_RC" -ne 0 ]]; then
    case "$RCON_RC" in
        2) REASON="auth rejected" ;;
        3) REASON="unreachable" ;;
        4) REASON="timed out" ;;
        *) REASON="failed (exit $RCON_RC)" ;;
    esac
    echo "[Watcher] RCON $REASON at $RCON_HOST:$RCON_PORT - $(head -n 1 "$RCON_ERR")"
    rm -f "$RCON_ERR"

    NEW_FAIL_COUNT=$((RCON_FAIL_COUNT + 1))
    if [[ "$BLIND_RESTART_AFTER" -le 0 ]]; then
        echo "[Watcher] Blind restart disabled. Cannot tell whether anyone is playing. Deferring."
        set_fail_count "$NEW_FAIL_COUNT"
        exit 0
    fi

    if [[ "$NEW_FAIL_COUNT" -lt "$BLIND_RESTART_AFTER" ]]; then
        echo "[Watcher] Cannot tell whether anyone is playing. Deferring (RCON failure $NEW_FAIL_COUNT/$BLIND_RESTART_AFTER)."
        set_fail_count "$NEW_FAIL_COUNT"
        exit 0
    fi

    echo "[Watcher] RCON has failed $NEW_FAIL_COUNT runs in a row; restarting blind."
    restart_server || exit 1
    exit 0
fi
rm -f "$RCON_ERR"

if [[ "$RCON_FAIL_COUNT" -ne 0 ]]; then
    set_fail_count 0
fi

PLAYER_COUNT=$(printf '%s\n' "$STATUS_OUT" | grep -oP '\d+(?= humans)' | head -n 1)
if [[ -z "$PLAYER_COUNT" ]]; then
    # RCON works, so this is a parser problem, not an unreachable server - do not
    # count it towards a blind restart. Dump enough of the reply to fix the regex.
    echo "[Watcher] RCON replied but no player count could be parsed. Deferring."
    echo "[Watcher] Raw status (first 15 lines):"
    printf '%s\n' "$STATUS_OUT" | head -n 15
    exit 0
fi
echo "[Watcher] $PLAYER_COUNT players online."

if [[ "$PLAYER_COUNT" -gt 0 ]]; then
    echo "[Watcher] Server not empty. Deferring."
    exit 0
fi

echo "✅ [Watcher] Server empty. Restarting..."
restart_server || exit 1
