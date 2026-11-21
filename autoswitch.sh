#!/bin/sh
# ==============================================================================
# KeeneticAutoSwitchDNS (Pure Shell / BusyBox Edition)
# Automated DNS profile failover switch for Keenetic routers
#
# Usage:
#   ./autoswitch.sh [home|guest|both] [target_profile_name]
#   Example:
#   ./autoswitch.sh both AutoSwitchDNS
# ==============================================================================

MODE="both"
TARGET_NAME="autoswitchdns"
LOOP_INTERVAL=0

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --loop|-l)
            LOOP_INTERVAL="$2"
            shift 2
            ;;
        --daemon|-d)
            LOOP_INTERVAL="${2:-60}"
            shift 2
            ;;
        home|guest|both)
            MODE="$1"
            shift
            ;;
        *)
            TARGET_NAME="$1"
            shift
            ;;
    esac
done

RCI_BASE="http://127.0.0.1:79/rci"

log() {
    # Print to console only if running interactively in terminal (TTY) or VERBOSE=1
    # When executed by cron, stdout is not a TTY, preventing syslog pollution
    if [ -t 1 ] || [ "${VERBOSE:-0}" = "1" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

syslog_event() {
    # Send ONLY important failover events to Keenetic system log (avoids spam)
    log "$1"
    if command -v logger >/dev/null 2>&1; then
        logger -t "AutoSwitchDNS" "$1"
    fi
}

# 1. Check required tools
if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: 'jq' utility not found. Please run: opkg update && opkg install jq"
    exit 1
fi

http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -s "$1"
    else
        wget -qO- "$1"
    fi
}

http_post_batch() {
    local data="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s -X POST -H "Content-Type: application/json" -d "$data" "$RCI_BASE/"
    else
        wget -qO- --post-data="$data" --header="Content-Type: application/json" "$RCI_BASE/"
    fi
}

# 2. Check if content filter is enabled
run_check() {
    FILTER_STATUS=$(http_get "$RCI_BASE/show/rc/dns-proxy/filter")
    FILTER_ENGINE=$(echo "$FILTER_STATUS" | jq -r '.engine // empty')
    FILTER_ENABLE=$(echo "$FILTER_STATUS" | jq -r '.enable // true')

    if [ "$FILTER_ENGINE" = "none" ] || [ "$FILTER_ENABLE" = "false" ]; then
        log "Content filtering is disabled (engine='$FILTER_ENGINE'). Doing nothing."
        return 0
    fi

    # 3. Fetch all custom DNS profiles
    PROFILES_DATA=$(http_get "$RCI_BASE/show/rc/dns-proxy/filter/profile")

    if [ -z "$PROFILES_DATA" ] || [ "$PROFILES_DATA" = "null" ]; then
        log "No profiles found in show/rc/dns-proxy/filter/profile. Doing nothing."
        return 0
    fi

    TARGET_LOWER=$(echo "$TARGET_NAME" | tr '[:upper:]' '[:lower:]')

    # Find profile by description or key id case-insensitively
    MATCHED_ENTRY=$(echo "$PROFILES_DATA" | jq -c --arg target "$TARGET_LOWER" '
        to_entries[] | select((.value.description // "" | ascii_downcase) == $target or (.key | ascii_downcase) == $target)
    ' | head -n 1)

    if [ -z "$MATCHED_ENTRY" ] || [ "$MATCHED_ENTRY" = "null" ]; then
        AVAILABLE_DESCRIPTIONS=$(echo "$PROFILES_DATA" | jq -r 'to_entries[] | "\(.value.description // .key) (\(.key))"' | tr '\n' ', ' | sed 's/, $//')
        log "Profile '$TARGET_NAME' not found!"
        log "Available profiles on router: [ $AVAILABLE_DESCRIPTIONS ]"
        return 0
    fi

    PROFILE_KEY=$(echo "$MATCHED_ENTRY" | jq -r '.key')
    PROFILE_DESC=$(echo "$MATCHED_ENTRY" | jq -r '.value.description // .key')

    log "Found profile: '$PROFILE_DESC' (ID: $PROFILE_KEY)"

    # 4. Extract upstream servers (dns53, tls, https)
    SERVERS=$(echo "$MATCHED_ENTRY" | jq -r '
        [
            (.value.dns53.upstream // [])[]?.address,
            (.value.tls.upstream // [])[]?.address,
            (.value.https.upstream // [])[]?.url,
            (.value.upstream // [])[]?.address
        ] | map(select(. != null and . != "")) | .[]
    ' | sed 's|https\?://||' | awk -F'[/:]' '{print $1}' | sort -u)

    # Resolve local hostnames if any
    RESOLVED_SERVERS=""
    HOTSPOT_CACHE=""

    for item in $SERVERS; do
        if echo "$item" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            RESOLVED_SERVERS="$RESOLVED_SERVERS $item"
        else
            clean_name=$(echo "$item" | sed -E 's/\.(home|lan|local|keenetic\.pro)$//' | tr '[:upper:]' '[:lower:]')
            if [ -z "$HOTSPOT_CACHE" ]; then
                HOTSPOT_CACHE=$(http_get "$RCI_BASE/show/ip/hotspot")
            fi
            found_ip=$(echo "$HOTSPOT_CACHE" | jq -r --arg name "$clean_name" '
                (.host // [])[]? | select((.hostname // "" | ascii_downcase) == $name or (.name // "" | ascii_downcase) == $name) | .ip // empty
            ' | head -n 1)

            if [ -n "$found_ip" ]; then
                log "Local domain '$item' resolved via hotspot to: $found_ip"
                RESOLVED_SERVERS="$RESOLVED_SERVERS $found_ip"
            else
                RESOLVED_SERVERS="$RESOLVED_SERVERS $item"
            fi
        fi
    done

    log "Servers to probe: $RESOLVED_SERVERS"

    # 5. Check server availability via ICMP ping
    ANY_ALIVE=0
    for srv in $RESOLVED_SERVERS; do
        if [ -n "$srv" ]; then
            if ping -c 1 -W 1 "$srv" >/dev/null 2>&1; then
                log "Server $srv is ALIVE (ping OK)."
                ANY_ALIVE=1
                break
            else
                log "Server $srv is unreachable (ping failed)."
            fi
        fi
    done

    # 6. Determine target state
    if [ "$ANY_ALIVE" -eq 1 ]; then
        TARGET_PROFILE_ID="$PROFILE_KEY"
        log "Decision: server is UP -> activate profile [$PROFILE_DESC ($TARGET_PROFILE_ID)]"
    else
        TARGET_PROFILE_ID=""
        log "Decision: server is DOWN -> fallback to [System profile]"
    fi

    # 7. Determine target network interfaces (Bridge0 = Home, Bridge1 = Guest)
    TARGET_IFACES=""
    case "$MODE" in
        home)
            TARGET_IFACES="Bridge0"
            ;;
        guest)
            TARGET_IFACES="Bridge1"
            ;;
        both|*)
            TARGET_IFACES="Bridge0 Bridge1"
            ;;
    esac

    # 8. Check current assignments
    ASSIGN_DATA=$(http_get "$RCI_BASE/show/rc/dns-proxy/filter/assign")
    BATCH_PAYLOAD="["
    NEEDS_UPDATE=0

    for iface in $TARGET_IFACES; do
        CURR_PROF=$(echo "$ASSIGN_DATA" | jq -r --arg iface "$iface" '
            (.interface.profile // [])[]? | select(.interface == $iface) | .profile // empty
        ')

        if [ -n "$TARGET_PROFILE_ID" ]; then
            # Need to assign profile
            if [ "$CURR_PROF" = "$TARGET_PROFILE_ID" ]; then
                log "Interface '$iface' is already set to '$CURR_PROF'. Skipping."
            else
                syslog_event "Interface '$iface': assigning profile '$CURR_PROF' -> '$TARGET_PROFILE_ID'"
                BATCH_PAYLOAD="$BATCH_PAYLOAD{\"dns-proxy\":{\"filter\":{\"assign\":{\"interface\":{\"profile\":{\"interface\":\"$iface\",\"profile\":\"$TARGET_PROFILE_ID\"}}}}}},{\"dns-proxy\":{\"filter\":{\"assign\":{\"interface\":{\"preset\":{\"interface\":\"$iface\",\"no\":true}}}}}},"
                NEEDS_UPDATE=1
            fi
        else
            # Need to switch to System (remove profile and preset)
            if [ -z "$CURR_PROF" ]; then
                log "Interface '$iface' is already System profile. Skipping."
            else
                syslog_event "Interface '$iface': removing profile '$CURR_PROF' -> System profile"
                BATCH_PAYLOAD="$BATCH_PAYLOAD{\"dns-proxy\":{\"filter\":{\"assign\":{\"interface\":{\"profile\":{\"interface\":\"$iface\",\"no\":true}}}}}},{\"dns-proxy\":{\"filter\":{\"assign\":{\"interface\":{\"preset\":{\"interface\":\"$iface\",\"no\":true}}}}}},"
                NEEDS_UPDATE=1
            fi
        fi
    done

    if [ "$NEEDS_UPDATE" -eq 0 ]; then
        log "All selected segments are already in the target state. No changes required."
        return 0
    fi

    # Append configuration save command and close array
    BATCH_PAYLOAD="$BATCH_PAYLOAD{\"system\":{\"configuration\":{\"save\":{}}}}]"

    log "Sending update batch to Keenetic..."
    http_post_batch "$BATCH_PAYLOAD" >/dev/null 2>&1
    syslog_event "Profiles updated and saved successfully."
}

if [ "$LOOP_INTERVAL" -gt 0 ] 2>/dev/null; then
    syslog_event "Daemon started (interval: ${LOOP_INTERVAL}s, mode: $MODE, target: $TARGET_NAME)"
    while true; do
        run_check
        sleep "$LOOP_INTERVAL"
    done
else
    run_check
fi
