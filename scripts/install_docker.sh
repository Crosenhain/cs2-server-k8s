#!/usr/bin/env bash

# Variables
user="steam"
BRANCH="main"

# Check if MOD_BRANCH is set and not empty
if [ -n "$MOD_BRANCH" ]; then
    BRANCH="$MOD_BRANCH"
fi

CUSTOM_FILES="${CUSTOM_FOLDER:-custom_files}"

# 32 or 64 bit Operating System
# If BITS environment variable is not set, try determine it
if [ -z "$BITS" ]; then
    # Determine the operating system architecture
    architecture=$(uname -m)

    # Set OS_BITS based on the architecture
    if [[ $architecture == *"64"* ]]; then
        export BITS=64
    elif [[ $architecture == *"i386"* ]] || [[ $architecture == *"i686"* ]]; then
        export BITS=32
    else
        echo "Unknown architecture: $architecture"
        exit 1
    fi
fi

if [[ -z $IP ]]; then
    IP_ARGS=""
else
    IP_ARGS="-ip ${IP}"
fi

# Workshop collection -> mapgroup generation happens later (after the CS2 base
# download creates the game dir). See the "Workshop collection" block below.


if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    DISTRO_OS=$NAME
    DISTRO_VERSION=$VERSION_ID
elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    DISTRO_OS=$(lsb_release -si)
    DISTRO_VERSION=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    DISTRO_OS=$DISTRIB_ID
    DISTRO_VERSION=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    DISTRO_OS=Debian
    DISTRO_VERSION=$(cat /etc/debian_version)
else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    DISTRO_OS=$(uname -s)
    DISTRO_VERSION=$(uname -r)
fi

echo "Starting on $DISTRO_OS: $DISTRO_VERSION..."

# Get the free space on the root filesystem in GB
FREE_SPACE=$(df / --output=avail -BG | tail -n 1 | tr -d 'G')

echo "With $FREE_SPACE Gb free space..."

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run this script as root..."
    exit 1
fi

PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)

if [ -z "$PUBLIC_IP" ]; then
    echo "ERROR: Cannot retrieve your public IP address..."
    exit 1
fi

# Update DuckDNS with our current IP
if [ ! -z "$DUCK_TOKEN" ]; then
    echo url="http://www.duckdns.org/update?domains=$DUCK_DOMAIN&token=$DUCK_TOKEN&ip=$PUBLIC_IP" | curl -k -o /duck.log -K -
fi

echo "Checking $user user exists..."
getent passwd ${user} >/dev/null 2>&1
if [ "$?" -ne "0" ]; then
    echo "Adding $user user..."
    addgroup ${user} &&
        adduser --system --home /home/${user} --shell /bin/false --ingroup ${user} ${user} &&
        usermod -a -G tty ${user} &&
        mkdir -m 777 /home/${user}/cs2 &&
        chown -R ${user}:${user} /home/${user}/cs2
    if [ "$?" -ne "0" ]; then
        echo "ERROR: Cannot add user $user..."
        exit 1
    fi
fi

chmod 777 /home/${user}/cs2
chown -R ${user}:${user} /home/${user}

echo "Checking steamcmd exists..."
if [ ! -d "/steamcmd" ]; then
    mkdir /steamcmd && cd /steamcmd || exit
    wget -q https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
    tar -xvzf steamcmd_linux.tar.gz
fi

chown -R ${user}:${user} /steamcmd
chown -R ${user}:${user} /home/${user}

# Add steamcmd to PATH for -autoupdate to work
export PATH=$PATH:/steamcmd

if $REMOVE_APP_MANIFEST_ON_START; then 
    echo "Removing appmanifest_730.acf in case it is corrupt"
    rm -f /home/steam/cs2/steamapps/appmanifest_730.acf
fi

if $VALIDATE_ON_START; then
    APP_UPDATE="+app_update 730 validate"
else
    APP_UPDATE="+app_update 730"
fi

echo "Downloading any updates for CS2..."
# https://developer.valvesoftware.com/wiki/Command_line_options
sudo -u $user /steamcmd/steamcmd.sh \
    +api_logging 1 1 \
    +@sSteamCmdForcePlatformType linux \
    +@sSteamCmdForcePlatformBitness "$BITS" \
    +force_install_dir /home/${user}/cs2 \
    +login anonymous \
    $APP_UPDATE \
    +quit

cd /home/${user} || exit

# Set up steam client libraries
# 32-bit
mkdir -p /home/${user}/.steam/sdk32/
rm /home/${user}/.steam/sdk32/steamclient.so
cp -v /steamcmd/linux32/steamclient.so /home/${user}/.steam/sdk32/steamclient.so || {
        echo "ERROR: Failed to copy 32-bit libraries"
}
# 64-bit
mkdir -p /home/${user}/.steam/sdk64/
rm /home/${user}/.steam/sdk64/steamclient.so
cp -v /steamcmd/linux64/steamclient.so /home/${user}/.steam/sdk64/steamclient.so || {
        echo "ERROR: Failed to copy 64-bit libraries"
}

# Copy .so files needed after 16.9.2025 update
# https://discord.com/channels/1160907911501991946/1160907912445710479/1417806634503372851
cp -v /home/${user}/cs2/game/bin/linuxsteamrt64/*.so  /home/${user}/cs2/game/csgo/bin/linuxsteamrt64/

echo "Merging in custom files"
cp -RT /home/custom_files/ /home/${user}/cs2/game/csgo/

chown -R ${user}:${user} /home/${user}

# --- Workshop collection -> mapgroup generation --------------------------------
# The CS2 end-of-match "vote next map" screen is populated from the ACTIVE
# mapgroup's "maps" list in gamemodes_server.txt, NOT from the downloaded
# workshop collection. So when a collection is set we resolve its member maps,
# pre-download them to read their .bsp names, and write a gamemodes_server.txt
# mapgroup listing them as workshop/<id>/<bsp> entries. This mapgroup is then
# the source of truth for the vote; +host_workshop_collection is kept only to
# keep the engine subscription current.
WORKSHOP_ARGS=()
GEN_MAP_GROUP=""
GEN_MAP=""

if [[ -n "$CS2_WORKSHOP_COLLECTION" ]]; then
    MAPGROUP_NAME="${MAPGROUP_NAME:-mg_workshop}"
    echo "Resolving workshop collection ${CS2_WORKSHOP_COLLECTION} -> map ids..."

    COLLECTION_JSON=$(curl -s \
        "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/" \
        -d collectioncount=1 \
        -d "publishedfileids[0]=${CS2_WORKSHOP_COLLECTION}")

    # Extract child publishedfileids (jq -> python3 -> grep fallback)
    if command -v jq >/dev/null 2>&1; then
        MAP_IDS=$(echo "$COLLECTION_JSON" | jq -r \
            '.response.collectiondetails[0].children[]?.publishedfileid')
    elif command -v python3 >/dev/null 2>&1; then
        MAP_IDS=$(echo "$COLLECTION_JSON" | python3 -c \
            'import sys,json;d=json.load(sys.stdin);print("\n".join(c["publishedfileid"] for c in d["response"]["collectiondetails"][0].get("children",[])))')
    else
        # Fallback: first "publishedfileid" is the collection itself, drop it.
        MAP_IDS=$(echo "$COLLECTION_JSON" | grep -o '"publishedfileid":"[0-9]*"' \
            | grep -o '[0-9]*' | tail -n +2)
    fi

    if [[ -z "$MAP_IDS" ]]; then
        echo "WARNING: could not resolve collection ${CS2_WORKSHOP_COLLECTION}; falling back to MAP_GROUP='${MAP_GROUP-mg_active}'"
    else
        # Pre-download each member so its .bsp is on disk for name derivation
        # (the engine otherwise only fetches at runtime, too late for config-gen).
        DL_ARGS=(+force_install_dir "/home/${user}/cs2" +login anonymous)
        for id in $MAP_IDS; do
            DL_ARGS+=(+workshop_download_item 730 "$id")
        done
        DL_ARGS+=(+quit)
        echo "Downloading ${CS2_WORKSHOP_COLLECTION} member maps..."
        sudo -u "$user" /steamcmd/steamcmd.sh "${DL_ARGS[@]}"

        GM_FILE="/home/${user}/cs2/game/csgo/gamemodes_server.txt"
        ENTRIES=""
        for id in $MAP_IDS; do
            bsp=$(basename "$(ls /home/${user}/cs2/steamapps/workshop/content/730/${id}/*.bsp 2>/dev/null | head -n1)" .bsp 2>/dev/null)
            if [[ -z "$bsp" ]]; then
                echo "WARNING: no .bsp found for workshop item ${id}; skipping"
                continue
            fi
            ENTRIES+=$'\t\t\t\t"'"workshop/${id}/${bsp}"$'"\t\t""\n'
            [[ -z "$GEN_MAP" ]] && GEN_MAP="workshop/${id}/${bsp}"
        done

        if [[ -z "$ENTRIES" ]]; then
            echo "WARNING: no workshop maps resolved to .bsp; falling back to MAP_GROUP='${MAP_GROUP-mg_active}'"
        else
            cat > "$GM_FILE" <<EOF
"GameModes.txt"
{
	"mapgroups"
	{
		"${MAPGROUP_NAME}"
		{
			"name"		"${MAPGROUP_NAME}"
			"maps"
			{
${ENTRIES}			}
		}
	}
}
EOF
            chown ${user}:${user} "$GM_FILE"
            GEN_MAP_GROUP="$MAPGROUP_NAME"
            echo "Wrote ${GM_FILE} with mapgroup ${MAPGROUP_NAME}"
            # Bug A fix: separate argv tokens, not one quoted string.
            WORKSHOP_ARGS=(+host_workshop_collection "$CS2_WORKSHOP_COLLECTION")
            # Bug B fix: derived/optional start map, not a hardcoded id.
            if [[ -n "$WORKSHOP_START_MAP" ]]; then
                WORKSHOP_ARGS+=(+host_workshop_map "$WORKSHOP_START_MAP")
            fi
        fi
    fi
fi

# Generated mapgroup wins; otherwise fall back to the env-provided mapgroup.
EFFECTIVE_MAP_GROUP="${GEN_MAP_GROUP:-${MAP_GROUP-mg_active}}"
# Boot map: an explicit workshop/<id>/<bsp> in MAP pins the start map; else the
# first resolved collection member; else the env MAP; else de_dust2.
if [[ "$MAP" == workshop/* ]]; then
    EFFECTIVE_MAP="$MAP"
else
    EFFECTIVE_MAP="${GEN_MAP:-${MAP-de_dust2}}"
fi
# --- end workshop generation ---------------------------------------------------

cd /home/${user}/cs2 || exit

echo "Starting server on $PUBLIC_IP:$PORT"
# https://developer.valvesoftware.com/wiki/Counter-Strike_2/Dedicated_Servers#Command-Line_Parameters
CS2_ARGS=(
    -dedicated
    -console
    -usercon
    -disable_workshop_command_filtering
    -autoupdate
    -tickrate "$TICKRATE"
)
# $IP_ARGS is "-ip <addr>" or empty; append unquoted so it splits into tokens.
[[ -n "$IP_ARGS" ]] && CS2_ARGS+=($IP_ARGS)
CS2_ARGS+=(
    -port "$PORT"
    +map "$EFFECTIVE_MAP"
    +sv_visiblemaxplayers "$MAXPLAYERS"
    -authkey "$API_KEY"
    +sv_setsteamaccount "$STEAM_ACCOUNT"
    +game_type "${GAME_TYPE-0}"
    +game_mode "${GAME_MODE-0}"
    +mapgroup "$EFFECTIVE_MAP_GROUP"
    +sv_lan "$LAN"
    +sv_password "$SERVER_PASSWORD"
    +rcon_password "$RCON_PASSWORD"
    "${WORKSHOP_ARGS[@]}"
    +exec "$EXEC"
)

echo ./game/bin/linuxsteamrt64/cs2 "${CS2_ARGS[@]}"
sudo -u $user ./game/bin/linuxsteamrt64/cs2 "${CS2_ARGS[@]}"

