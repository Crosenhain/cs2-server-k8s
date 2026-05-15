#!/bin/bash
# Indented 8 spaces to be safe
RCON_HOST=${RCON_HOST:-"cs2-service"}
RCON_PORT=${CS2_PORT:-"27015"}
RCON_PASSWORD=${CS2_RCONPW}
SERVER_DIR="/home/steam/cs2"
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

rcon_command() {
    python3 -c "
import socket, struct
def sp(s, t, i, b):
    m = b.encode('ascii') + b'\x00\x00'
    s.send(struct.pack('<iii', len(m)+10, i, t) + m)
def gr(s):
    d = s.recv(4)
    if not d: return None
    return s.recv(struct.unpack('<i', d)[0])
with socket.create_connection(('$1', $2), timeout=5) as s:
    sp(s, 3, 1, '$3')
    gr(s)
    sp(s, 2, 2, '$4')
    r = gr(s)
    if r: print(r[8:-2].decode('ascii', 'ignore'))
" 2>/dev/null
}

echo "🚨 [Watcher] Update available!"
STATUS_OUT=$(rcon_command "$RCON_HOST" "$RCON_PORT" "$RCON_PASSWORD" "status")
PLAYER_COUNT=$(echo "$STATUS_OUT" | grep "players" | grep -oP '\d+ humans' | grep -oP '\d+' || echo "0")
echo "[Watcher] $PLAYER_COUNT players online."

if [[ "$PLAYER_COUNT" -gt 0 ]]; then
    echo "[Watcher] Server not empty. Deferring."
    exit 0
fi

echo "✅ [Watcher] Server empty. Restarting..."
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
DATE=$(date +%Y-%m-%dT%H:%M:%SZ)

curl -s -X PATCH -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/strategic-merge-patch+json" \
     --cacert "$CACERT" \
     -d "{\"spec\":{\"strategy\":{\"type\":\"Recreate\"},\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"$DATE\"}}}}}" \
     https://kubernetes.default.svc/apis/apps/v1/namespaces/__NAMESPACE__/deployments/__DEPLOYMENT__
echo "[Watcher] Restarted."
