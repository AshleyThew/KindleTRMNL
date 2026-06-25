#!/bin/sh
# KindleTRMNL — Main daemon (single-file)
#
# Invocation modes:
#   (no args)       — called from KUAL; re-execs self with nohup to detach
#   --detached      — actual daemon loop (forked from above)
#   --autostart     — same as --detached; used by Upstart boot job
#
# Exits when the power button is pressed, or when the screen is tapped and the
# on-screen quit prompt is confirmed with a second tap.
#
# Install path: /mnt/us/extensions/KindleTRMNL/trmnl.sh

# ─── Paths ───────────────────────────────────────────────────────────────────
_STOP_FRAMEWORK=0   # set to 1 if --framework_stop arg or STOP_FRAMEWORK=true in config

EXT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$EXT_DIR/config.conf"
LOG_FILE="$EXT_DIR/logs/trmnl.log"
CACHE_DIR="$EXT_DIR/cache"
LOCK_FILE="/tmp/trmnl.lock"
PROMPT_LOCK="/tmp/trmnl_prompt.lock"  # present while a quit prompt is on screen
FETCH_TMP="/tmp/trmnl_current.png"
_FETCH_JSON="/tmp/trmnl_display.json"

# Ensure directories exist before first log write.
mkdir -p "$CACHE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null

# ═══════════════════════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════════════════════

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
    _log_rotate_if_needed
}

_log_rotate_if_needed() {
    [ -f "$LOG_FILE" ] || return
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null | awk '{print $1}')
    case "$size" in
        ''|*[!0-9]*) return ;;
    esac
    local max="${LOG_MAX_BYTES:-524288}"
    if [ "$size" -gt "$max" ]; then
        local keep=$(( max / 2 ))
        if tail -c "$keep" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null; then
            mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null \
                || printf '%s ERROR: Log rotation mv failed\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# WIFI
# ═══════════════════════════════════════════════════════════════════════════════

# Return 0 once the WiFi link is up AND has a usable IPv4 address.
# An associated interface without an IP still can't fetch over HTTP, which is
# the most common cause of a spurious "did not associate" fallback.
_wifi_has_ip() {
    local iface
    for iface in wlan0 mlan0 wlan1; do
        [ -d "/sys/class/net/$iface" ] || continue
        # ip(8) is present on modern firmware; fall back to ifconfig otherwise.
        if command -v ip >/dev/null 2>&1; then
            local _addr
            _addr=$(ip -4 addr show "$iface" 2>/dev/null)
            if echo "$_addr" | grep -q 'inet '; then
                local _ip
                _ip=$(echo "$_addr" | grep 'inet ' | awk '{print $2}' | head -1)
                log "DEBUG: _wifi_has_ip: $iface has IP $_ip"
                return 0
            fi
        else
            if ifconfig "$iface" 2>/dev/null | grep -Eq 'inet (addr:)?'; then
                log "DEBUG: _wifi_has_ip: $iface up (ifconfig)"
                return 0
            fi
        fi
    done
    log "DEBUG: _wifi_has_ip: no interface has IPv4 address"
    return 1
}

wifi_enable() {
    log "DEBUG: wifi_enable called (radio=$(wifi_radio_state))"
    # Already fully connected (e.g. screensaver kept the radio on)? Done.
    if wifi_is_connected && _wifi_has_ip; then
        log "DEBUG: wifi_enable: already connected with IP -- skip"
        return 0
    fi

    # Turn the radio on. This is idempotent: re-issuing it while already on does
    # not disrupt an in-progress association, so we can safely re-assert it
    # below without ever cutting power mid-connect.
    log "INFO: WiFi enable: asserting wirelessEnable=1"
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null

    local timeout="${WIFI_TIMEOUT:-60}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local iface
        iface=$(lipc-get-prop com.lab126.cmd activeInterface 2>/dev/null)
        if [ "$iface" = "wifi" ]; then
            # Interface is selected, but the connection may not be fully
            # established (no IP yet). Require a CONNECTED cmState (when the
            # daemon exposes it) AND a real IPv4 address before proceeding.
            local cmstate
            cmstate=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
            log "DEBUG: wifi_enable: elapsed=${elapsed}s iface=$iface cmState='${cmstate}'"
            case "$cmstate" in
                CONNECTED|[Cc][Oo][Nn][Nn][Ee][Cc][Tt][Ee][Dd]|'') # '' = daemon doesn't expose cmState; accept iface=wifi
                    if _wifi_has_ip; then
                        # Some devices report "connected" before the network
                        # stack is ready for HTTP. Give it a moment to settle so
                        # the first fetch doesn't fall back to the cached image.
                        local settle="${NETWORK_SETTLE_SECS:-2}"
                        [ "$settle" -gt 0 ] 2>/dev/null && sleep "$settle"
                        log "INFO: WiFi connected (${elapsed}s, settle=${settle}s)"
                        return 0
                    fi
                    ;;
                *)
                    log "DEBUG: wifi_enable: cmState='$cmstate' -- waiting"
                    ;;
            esac
        else
            log "DEBUG: wifi_enable: elapsed=${elapsed}s activeInterface='${iface}' (not wifi yet)"
        fi

        # Periodically re-assert the radio enable in case it was disabled
        # (e.g. by a power-save event). This does NOT power-cycle the radio, so
        # it never interrupts an association that is already underway.
        if [ $(( elapsed % 10 )) -eq 0 ] && [ "$elapsed" -gt 0 ]; then
            log "DEBUG: wifi_enable: re-asserting wirelessEnable=1 at ${elapsed}s"
            lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
        fi

        sleep 2
        elapsed=$(( elapsed + 2 ))
    done

    log "WARN: WiFi did not connect within ${timeout}s (last iface=$(lipc-get-prop com.lab126.cmd activeInterface 2>/dev/null) cmState=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null))"
    return 1
}

wifi_disable() {
    log "DEBUG: wifi_disable called"
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
}

# Report the current radio state: "1" = wireless enabled, "0" = off/airplane
# mode. Empty if the property can't be read.
wifi_radio_state() {
    lipc-get-prop com.lab126.cmd wirelessEnable 2>/dev/null
}

wifi_is_connected() {
    local iface
    iface=$(lipc-get-prop com.lab126.cmd activeInterface 2>/dev/null)
    [ "$iface" = "wifi" ]
}

get_mac_address() {
    # Most Kindles use wlan0, but auto-detect the wireless interface so the
    # extension works across models that name it differently (e.g. mlan0).
    local iface
    for iface in /sys/class/net/wlan0 /sys/class/net/mlan0 /sys/class/net/wlan*; do
        [ -r "$iface/address" ] || continue
        cat "$iface/address" 2>/dev/null | tr '[:lower:]' '[:upper:]'
        return
    done
}

# Report the actual Kindle firmware version, e.g. "5.16.2.1.1".
# Tries the lipc system property first, then the on-disk version files.
get_fw_version() {
    local v
    v=$(lipc-get-prop com.lab126.system version 2>/dev/null)
    if [ -z "$v" ] && [ -r /etc/prettyversion.txt ]; then
        v=$(grep -oE '[0-9]+(\.[0-9]+)+' /etc/prettyversion.txt 2>/dev/null | head -1)
    fi
    if [ -z "$v" ] && [ -r /etc/version.txt ]; then
        v=$(grep -oE '[0-9]+(\.[0-9]+)+' /etc/version.txt 2>/dev/null | head -1)
    fi
    echo "${v:-unknown}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# POWER
# ═══════════════════════════════════════════════════════════════════════════════

prevent_sleep() {
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
}

allow_sleep() {
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
}

# Hide the Kindle status bar.
# FW >= 5.6.5: hard-disable pillow entirely.
# FW >= 5.7.2: also SIGSTOP the window manager so KUAL can't redraw over us.
# No-op when the framework has been stopped (nothing to hide).
hide_status_bar() {
    [ "$_STOP_FRAMEWORK" = "1" ] && return
    lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null
    killall -STOP awesome 2>/dev/null
}

# Restore the Kindle status bar and window manager.
# No-op when the framework has been stopped (it will be restarted in cleanup).
show_status_bar() {
    [ "$_STOP_FRAMEWORK" = "1" ] && return
    killall -CONT awesome 2>/dev/null
    lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
}

# Stop the Kindle framework (lab126_gui) for maximum framebuffer control.
_framework_stop() {
    log "INFO: Stopping Kindle framework"
    if [ -d /etc/upstart ]; then
        # Trap SIGTERM so the framework's stop signal doesn't kill us.
        trap '' TERM
        stop lab126_gui 2>/dev/null
        # Wait for framework teardown to finish and screen to clear.
        # Without this, the framework wipes our eips output after we draw it.
        usleep 1250000 2>/dev/null || sleep 2
        # Restore our trap.
        trap '_daemon_cleanup; exit 0' TERM
    else
        /etc/init.d/framework stop 2>/dev/null
    fi
}

# Restart the Kindle framework after we exit.
_framework_start() {
    log "INFO: Restarting Kindle framework"
    if [ -d /etc/upstart ]; then
        cd / && start lab126_gui 2>/dev/null
    else
        cd / && /etc/init.d/framework start 2>/dev/null
    fi
}

get_battery_pct() {
    # Returns integer percentage, e.g. "72".
    lipc-get-prop com.lab126.powerd status 2>/dev/null \
        | grep 'Battery Level:' \
        | cut -d: -f2 \
        | tr -d '% '
}

is_charging() {
    local v
    v=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
    [ "$v" = "1" ]
}

schedule_rtc_wake() {
    local seconds="$1"
    log "DEBUG: schedule_rtc_wake: ${seconds}s from now"
    lipc-set-prop com.lab126.powerd rtcWakeup "$seconds" 2>/dev/null
}

deep_sleep() {
    log "DEBUG: deep_sleep: disabling USB wakeup sources"
    local _usb_count=0
    for _dev in /sys/bus/usb/devices/*/power/wakeup; do
        [ -f "$_dev" ] && echo disabled > "$_dev" 2>/dev/null && _usb_count=$(( _usb_count + 1 ))
    done
    log "DEBUG: deep_sleep: disabled $_usb_count USB wakeup source(s), writing mem to /sys/power/state"
    echo mem > /sys/power/state 2>/dev/null
    log "DEBUG: deep_sleep: resumed from suspend"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DISPLAY
# ═══════════════════════════════════════════════════════════════════════════════

_SCREEN_W=""
_SCREEN_H=""

get_screen_dimensions() {
    if [ -z "$_SCREEN_W" ]; then
        local info
        info=$(eips -i 2>/dev/null)
        _SCREEN_W=$(echo "$info" | grep 'xres:' | head -1 | awk '{print $2}' | sed 's/^0*//')
        # yres is the 4th field in eips -i output ("yres:  <n>")
        _SCREEN_H=$(echo "$info" | grep 'yres:' | head -1 | awk '{print $4}' | sed 's/^0*//')
        if [ -z "$_SCREEN_W" ] || [ -z "$_SCREEN_H" ]; then
            log "WARN: get_screen_dimensions: eips -i returned no xres/yres (raw: $(echo "$info" | tr '\n' ' ' | cut -c1-120)) -- using defaults 758x1024"
        fi
        _SCREEN_W="${_SCREEN_W:-758}"
        _SCREEN_H="${_SCREEN_H:-1024}"
        log "DEBUG: screen dimensions: ${_SCREEN_W}x${_SCREEN_H}"
    fi
}

display_image() {
    local path="$1"
    if [ ! -f "$path" ]; then
        display_error "No image file" "Path: $path"
        return 1
    fi
    eips -c
    if [ "${PARTIAL_REFRESH:-false}" = "true" ]; then
        eips -g "$path" -x 0 -y 0
    else
        eips -f -g "$path" -x 0 -y 0
    fi
}

# Sanitize and print a text string via eips.
# Strips non-ASCII bytes (causes garbage/errors on this Kindle font).
# Prefixes a space if text starts with '-' (eips parses it as a flag).
_eips_put() {
    local col="$1" row="$2"
    local text
    text=$(printf '%s' "$3" | tr -cd '\040-\176')
    case "$text" in -*) text=" $text" ;; esac
    eips "$col" "$row" "$text"
}

display_text() {
    eips -c
    local row=4
    for _line in "$@"; do
        [ -n "$_line" ] && _eips_put 0 "$row" "$_line"
        row=$(( row + 2 ))
    done
}

display_battery_overlay() {
    local batt="$1"
    local last="$2"
    local nxt="$3"
    get_screen_dimensions
    local bottom_row
    if [ -n "$_SCREEN_H" ] && [ "$_SCREEN_H" -gt 0 ] 2>/dev/null; then
        bottom_row=$(( _SCREEN_H / 18 - 1 ))
    else
        log "WARN: display_battery_overlay: _SCREEN_H empty or zero (eips -i failed?), using fallback row 55"
        bottom_row=55
    fi
    local status_line="Batt:${batt}%  Last:${last}  Next:${nxt}"
    log "DEBUG: battery_overlay row=${bottom_row} line='${status_line}'"
    _eips_put 0 "$bottom_row" "$status_line"
}

# Show a two-line error screen then display the last log lines below it.
display_error() {
    eips -c
    local row=2
    _eips_put 0 "$row" "KindleTRMNL Error" ; row=$(( row + 2 ))
    _eips_put 0 "$row" "$1"               ; row=$(( row + 2 ))
    _eips_put 0 "$row" "$2"               ; row=$(( row + 2 ))
    row=$(( row + 1 ))
    _eips_put 0 "$row" "recent log:"       ; row=$(( row + 1 ))
    if [ -f "$LOG_FILE" ]; then
        tail -10 "$LOG_FILE" | while IFS= read -r _ll; do
            _eips_put 0 "$row" "$(printf '%s' "$_ll" | cut -c1-65)"
            row=$(( row + 1 ))
        done
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# FETCH
# ═══════════════════════════════════════════════════════════════════════════════

# Fetch the current display image from the BYOS server.
# Exit codes:
#   0  — fresh image downloaded and cached
#   2  — fetch failed; cached image copied to FETCH_TMP (soft failure)
#   1  — fetch failed AND no cache available (hard failure)
fetch_display_image() {
    local url="${BYOS_URL%/}/api/display"
    local mac
    mac=$(get_mac_address)

    local batt
    batt=$(get_battery_pct)

    # Ensure screen dimensions are populated for png-width/png-height headers.
    get_screen_dimensions

    log "DEBUG: fetch_display_image start: url=$url mac=$mac batt=${batt}% w=${_SCREEN_W:-758} h=${_SCREEN_H:-1024}"
    [ -z "$mac" ] && log "WARN: fetch_display_image: MAC address is empty -- ID header will be blank"

    local http_code
    http_code=$(curl -s \
        -w "%{http_code}" \
        -o "$_FETCH_JSON" \
        -H "access-token: ${API_KEY}" \
        -H "ID: $mac" \
        -H "percent-charged: ${batt:-0}" \
        -H "png-width: ${_SCREEN_W:-758}" \
        -H "png-height: ${_SCREEN_H:-1024}" \
        -H "rssi: 0" \
        -A "kindle-trmnl/1.0" \
        --connect-timeout 15 \
        --max-time 30 \
        "$url" 2>/dev/null)

    if [ "$http_code" != "200" ]; then
        log "WARN: BYOS JSON fetch returned HTTP $http_code (url=$url)"
        log "DEBUG: fetch_display_image: JSON response body (truncated): $(tr -d '\n' < "$_FETCH_JSON" 2>/dev/null | cut -c1-200)"
        _fetch_use_cache ; return $?
    fi

    log "DEBUG: JSON=$(tr -d '\n' < "$_FETCH_JSON" | cut -c1-300)"

    local image_url
    image_url=$(sed -n \
        's/.*"image_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$_FETCH_JSON" | head -1 | sed 's/\\\//\//g')

    if [ -z "$image_url" ]; then
        log "WARN: No image_url in BYOS JSON response"
        _fetch_use_cache ; return $?
    fi

    if ! echo "$image_url" | grep -qE '^https?://'; then
        log "WARN: image_url value is not a valid URL: $image_url"
        _fetch_use_cache ; return $?
    fi

    # Derive filename from JSON response, then URL, then fallback.
    local filename
    filename=$(sed -n \
        's/.*"filename"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$_FETCH_JSON" | head -1)
    [ -z "$filename" ] && filename=$(echo "$image_url" | sed 's|.*/||; s|?.*||')
    [ -z "$filename" ] && filename="display"
    case "$filename" in *.png) ;; *) filename="${filename}.png" ;; esac
    local dest="$CACHE_DIR/$filename"

    # Remove old cached images (different filename) before downloading.
    for _old in "$CACHE_DIR"/*.png; do
        [ "$_old" = "$dest" ] && continue
        rm -f "$_old"
        log "INFO: Removed old image: $(basename "$_old")"
    done

    log "DEBUG: fetch_display_image: downloading image url=$image_url dest=$dest"
    local img_code
    img_code=$(curl -s \
        -w "%{http_code}" \
        -o "$dest" \
        -A "kindle-trmnl/1.0" \
        --connect-timeout 15 \
        --max-time 60 \
        "$image_url" 2>/dev/null)

    if [ "$img_code" = "200" ] && [ -s "$dest" ]; then
        cp "$dest" "$FETCH_TMP"
        local sz
        sz=$(wc -c < "$dest" 2>/dev/null | awk '{print $1}')
        log "INFO: Image fetched OK (${sz} bytes) -> $filename"
        return 0
    else
        log "WARN: Image download returned HTTP $img_code (url=$image_url)"
        local dest_sz
        dest_sz=$(wc -c < "$dest" 2>/dev/null | awk '{print $1}')
        log "DEBUG: fetch_display_image: partial/bad download size=${dest_sz:-0} bytes -- discarding"
        rm -f "$dest"
        _fetch_use_cache ; return $?
    fi
}

_fetch_use_cache() {
    # Use the most recent cached image as fallback.
    local cached
    cached=$(ls -t "$CACHE_DIR"/*.png 2>/dev/null | head -1)
    if [ -n "$cached" ] && [ -f "$cached" ]; then
        cp "$cached" "$FETCH_TMP"
        log "INFO: Using cached image as fallback: $(basename "$cached")"
        return 2
    fi
    log "ERROR: No cached image available"
    return 1
}

get_server_refresh_rate() {
    if [ ! -f "$_FETCH_JSON" ]; then echo 0; return; fi
    local rate
    rate=$(sed -n \
        's/.*"refresh_rate"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' \
        "$_FETCH_JSON" | head -1)
    echo "${rate:-0}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SCHEDULE
# ═══════════════════════════════════════════════════════════════════════════════

_hm_to_secs() {
    local hm="$1"
    local h m
    h=$(echo "$hm" | cut -d: -f1 | sed 's/^0*//')
    m=$(echo "$hm" | cut -d: -f2 | sed 's/^0*//')
    h="${h:-0}"
    m="${m:-0}"
    echo $(( h * 3600 + m * 60 ))
}

_now_secs() {
    _hm_to_secs "$(date '+%H:%M')"
}

_current_dow() {
    date '+%u'
}

_is_active_day() {
    local days="${REFRESH_DAYS:-}"
    [ -z "$days" ] && return 0
    local dow
    dow=$(_current_dow)
    echo "$days" | tr ',' '\n' | grep -qx "$dow"
}

_is_active_day_offset() {
    local offset="$1"
    local days="${REFRESH_DAYS:-}"
    [ -z "$days" ] && return 0
    local dow target_dow
    dow=$(_current_dow)
    target_dow=$(( (dow - 1 + offset) % 7 + 1 ))
    echo "$days" | tr ',' '\n' | grep -qx "$target_dow"
}

_time_in_active_window_secs() {
    local now_s="$1"
    local window="${ACTIVE_HOURS:-00:00-23:59}"
    local start end start_s end_s
    start=$(echo "$window" | cut -d- -f1)
    end=$(echo "$window"   | cut -d- -f2)
    start_s=$(_hm_to_secs "$start")
    end_s=$(_hm_to_secs "$end")
    if [ "$start_s" -lt "$end_s" ]; then
        [ "$now_s" -ge "$start_s" ] && [ "$now_s" -lt "$end_s" ]
    else
        [ "$now_s" -ge "$start_s" ] || [ "$now_s" -lt "$end_s" ]
    fi
}

is_in_active_window() {
    _is_active_day || return 1
    local window="${ACTIVE_HOURS:-00:00-23:59}"
    local start end
    start=$(echo "$window" | cut -d- -f1)
    end=$(echo "$window"   | cut -d- -f2)
    local now_s start_s end_s
    now_s=$(_now_secs)
    start_s=$(_hm_to_secs "$start")
    end_s=$(_hm_to_secs "$end")
    log "DEBUG: active_window check: now=${now_s}s start=${start_s}s end=${end_s}s window=${window}"
    if [ "$start_s" -lt "$end_s" ]; then
        # Normal window (e.g. 07:00-22:00)
        [ "$now_s" -ge "$start_s" ] && [ "$now_s" -lt "$end_s" ]
    else
        # Midnight-crossing window (e.g. 22:00-06:00)
        [ "$now_s" -ge "$start_s" ] || [ "$now_s" -lt "$end_s" ]
    fi
}

seconds_until_next_active() {
    local window="${ACTIVE_HOURS:-00:00-23:59}"
    local start end
    start=$(echo "$window" | cut -d- -f1)
    end=$(echo "$window"   | cut -d- -f2)
    local now_s start_s end_s
    now_s=$(_now_secs)
    start_s=$(_hm_to_secs "$start")
    end_s=$(_hm_to_secs "$end")
    local diff
    if [ "$start_s" -lt "$end_s" ]; then
        # Normal window: next open is tomorrow's start.
        diff=$(( start_s - now_s ))
        [ "$diff" -le 0 ] && diff=$(( 86400 + diff ))
    else
        # Midnight-crossing window: active from start→midnight→end.
        # If we're between end and start (i.e. currently inactive), sleep until start.
        diff=$(( start_s - now_s ))
        [ "$diff" -le 0 ] && diff=$(( 86400 + diff ))
    fi
    log "DEBUG: seconds_until_next_active=${diff}s (window=${window} now=${now_s}s)"
    echo "$diff"
}

_seconds_until_next_refresh_time() {
    local times="${REFRESH_TIMES:-}"
    [ -z "$times" ] && echo 0 && return
    local now_s
    now_s=$(_now_secs)
    local min_secs=999999
    local found=0
    for _t in $(echo "$times" | tr ',' ' '); do
        local t_s diff
        t_s=$(_hm_to_secs "$_t")
        diff=$(( t_s - now_s ))
        if [ "$diff" -gt 0 ] && [ "$diff" -lt "$min_secs" ]; then
            min_secs=$diff
            found=1
        fi
    done
    if [ "$found" = "0" ]; then
        for _t in $(echo "$times" | tr ',' ' '); do
            local t_s diff
            t_s=$(_hm_to_secs "$_t")
            diff=$(( 86400 - now_s + t_s ))
            if [ "$diff" -lt "$min_secs" ]; then
                min_secs=$diff
            fi
        done
    fi
    echo "$min_secs"
}

seconds_until_next_scheduled_refresh() {
    local times="${REFRESH_TIMES:-}"
    [ -z "$times" ] && echo 0 && return

    local now_s min_secs found day_offset
    now_s=$(_now_secs)
    min_secs=999999
    found=0

    for day_offset in 0 1 2 3 4 5 6 7; do
        _is_active_day_offset "$day_offset" || continue
        for _t in $(echo "$times" | tr ',' ' '); do
            local t_s diff
            t_s=$(_hm_to_secs "$_t")
            _time_in_active_window_secs "$t_s" || continue
            diff=$(( day_offset * 86400 + t_s - now_s ))
            if [ "$diff" -gt 0 ] && [ "$diff" -lt "$min_secs" ]; then
                min_secs=$diff
                found=1
            fi
        done
    done

    if [ "$found" = "1" ]; then
        echo "$min_secs"
    else
        seconds_until_next_active
    fi
}

get_next_refresh_seconds() {
    local secs
    if [ -n "${REFRESH_TIMES:-}" ]; then
        secs=$(_seconds_until_next_refresh_time)
    else
        secs="${REFRESH_INTERVAL:-900}"
    fi
    [ "$secs" -lt 60 ] && secs=60
    echo "$secs"
}

next_refresh_time_str() {
    local secs
    secs=$(get_next_refresh_seconds)
    local now_s total_s h m
    now_s=$(_now_secs)
    total_s=$(( (now_s + secs) % 86400 ))
    h=$(( total_s / 3600 ))
    m=$(( (total_s % 3600) / 60 ))
    printf '%02d:%02d' "$h" "$m"
}

# ─── Dependency check ────────────────────────────────────────────────────────
_check_dependencies() {
    # eips is the most critical — fail loudly if it's missing.
    if ! command -v eips >/dev/null 2>&1 && [ ! -x /usr/sbin/eips ]; then
        printf 'FATAL: eips not found — is this a jailbroken Kindle?\n' >&2
        exit 1
    fi
    local missing=""
    for _cmd in curl lipc-get-prop lipc-set-prop grep awk sed wc date; do
        command -v "$_cmd" >/dev/null 2>&1 || missing="$missing $_cmd"
    done
    if [ -n "$missing" ]; then
        display_error "Missing commands:" "$missing"
        exit 1
    fi
}

# ─── Helper: load + validate config ──────────────────────────────────────────
_load_config() {
    if [ ! -f "$CONFIG" ]; then
        display_error "Missing config.conf" "Copy config.conf to extension dir"
        exit 1
    fi
    # Strip Windows carriage returns so CRLF config files parse correctly.
    tr -d '\r' < "$CONFIG" > /tmp/trmnl_config.tmp
    . /tmp/trmnl_config.tmp
    rm -f /tmp/trmnl_config.tmp
    local err=""
    [ -z "${BYOS_URL:-}" ] && err="${err}BYOS_URL not set. "
    [ -z "${API_KEY:-}" ]  && err="${err}API_KEY not set. "
    if [ -n "$err" ]; then
        display_error "Config error" "$err"
        exit 1
    fi
}

# ─── Exit watchers: power button + screen tap ───────────────────────────────
# Power button exits immediately. A screen tap instead shows a confirmation
# prompt; the daemon only quits if the screen is tapped again within
# QUIT_PROMPT_TIMEOUT seconds, otherwise the dashboard resumes.
_find_touch_dev() {
    for _d in /dev/input/event*; do
        local _name
        _name=$(cat "/sys/class/input/$(basename "$_d")/device/name" 2>/dev/null)
        case "$_name" in
            *[Tt]ouch*|*[Zz][Ff]orce*|*[Mm][Xx]5*) echo "$_d"; return ;;
        esac
    done
    # Fallback — most Kindle models use event1 for touch.
    echo "/dev/input/event1"
}

# Discard any queued touch events for ~1s. A single physical tap emits a burst
# of input events; draining prevents the confirm read from firing instantly on
# leftover events from the same tap (also acts as a debounce).
_drain_touch() {
    local _tdev="$1"
    ( dd if="$_tdev" of=/dev/null bs=64 2>/dev/null ) &
    local _p=$!
    sleep 1
    kill "$_p" 2>/dev/null
    wait "$_p" 2>/dev/null
}

# Show the "tap again to quit" confirmation screen.
_display_quit_prompt() {
    local timeout="$1"
    eips -c
    _eips_put 0 4 "KindleTRMNL"
    _eips_put 0 6 "Tap again within ${timeout}s to QUIT."
    _eips_put 0 8 "Otherwise the dashboard resumes."
}

# Wait up to "timeout" seconds for a confirming tap.
# Returns 0 if the screen was tapped, 1 if it timed out.
_wait_touch_confirm() {
    local _tdev="$1" timeout="$2"
    dd if="$_tdev" bs=16 count=1 >/dev/null 2>&1 &
    local _ddpid=$!
    local _i=0
    while [ "$_i" -lt "$timeout" ]; do
        kill -0 "$_ddpid" 2>/dev/null || return 0   # dd exited => tap received
        sleep 1
        _i=$(( _i + 1 ))
    done
    kill "$_ddpid" 2>/dev/null
    wait "$_ddpid" 2>/dev/null
    return 1
}

# Background loop: on each tap, prompt for quit confirmation. Quit on a second
# tap within the timeout; otherwise redraw the dashboard and keep watching.
_touch_watcher() {
    local _dpid="$1" _tdev="$2"
    local timeout="${QUIT_PROMPT_TIMEOUT:-10}"
    while true; do
        # Block until the screen is touched.
        dd if="$_tdev" bs=16 count=1 >/dev/null 2>&1 || return
        _drain_touch "$_tdev"
        # Mark a quit prompt as active so the main loop won't deep-sleep over
        # it (which would freeze the screen on the prompt).
        : > "$PROMPT_LOCK" 2>/dev/null
        log "INFO: Screen tapped -- showing quit prompt (${timeout}s)"
        _display_quit_prompt "$timeout"
        if _wait_touch_confirm "$_tdev" "$timeout"; then
            log "INFO: Quit confirmed by tap -- exiting"
            rm -f "$PROMPT_LOCK" 2>/dev/null
            kill -TERM "$_dpid" 2>/dev/null
            return
        fi
        log "INFO: Quit prompt timed out -- resuming dashboard"
        [ -f "$FETCH_TMP" ] && display_image "$FETCH_TMP" >/dev/null 2>&1
        rm -f "$PROMPT_LOCK" 2>/dev/null
    done
}

# Block while a quit prompt is on screen, so the daemon doesn't go back to
# sleep and freeze the display on the "tap again to quit" prompt. Caps the
# wait so a stale lock can never hang the daemon indefinitely.
_wait_prompt_clear() {
    local _max="${PROMPT_WAIT_MAX:-30}" _i=0
    while [ -f "$PROMPT_LOCK" ] && [ "$_i" -lt "$_max" ]; do
        sleep 1
        _i=$(( _i + 1 ))
    done
}

_start_exit_watchers() {
    local _dpid="$$"

    # Optional power-button exit watcher. Disabled by default because in
    # deep_sleep/hybrid workflows the same sleep event can occur during normal
    # suspend cycles, which would terminate the daemon unexpectedly.
    if [ "${EXIT_ON_POWER_BUTTON:-false}" = "true" ]; then
        ( lipc-wait-event com.lab126.powerd goingToSleep >/dev/null 2>&1
          log "INFO: goingToSleep event -- exiting"
          kill -TERM "$_dpid" 2>/dev/null ) &
    fi

    # Screen tap: show a quit-confirmation prompt instead of exiting outright.
    local _tdev
    _tdev=$(_find_touch_dev)
    if [ -r "$_tdev" ]; then
        _touch_watcher "$_dpid" "$_tdev" &
    fi
}

# ─── Daemon: one fetch-and-display cycle ─────────────────────────────────────
# Returns 0 on success (fresh or cached), 1 on hard failure (no image at all).
_CONSECUTIVE_FAILURES=0

_do_refresh() {
    log "INFO: Fetching from $BYOS_URL ..."
    local result

    # Remember whether the radio was off (airplane mode) so we can restore it
    # afterwards. wifi_enable will toggle wirelessEnable on regardless.
    local _prev_radio
    _prev_radio=$(wifi_radio_state)
    local _was_airplane=0
    log "DEBUG: _do_refresh: radio_state=${_prev_radio} batt=$(get_battery_pct)% mode=${POWER_MODE:-hybrid}"
    if [ "$_prev_radio" = "0" ]; then
        _was_airplane=1
        log "INFO: Device in airplane mode -- temporarily enabling WiFi"
    fi

    if wifi_enable; then
        fetch_display_image
        result=$?
        log "DEBUG: _do_refresh: fetch_display_image exited with code $result"
    else
        log "WARN: WiFi did not associate within ${WIFI_TIMEOUT:-60}s -- using cache"
        _fetch_use_cache
        result=$?
    fi

    # Restore airplane mode immediately once the fetch is done. The image is
    # already cached locally, so display below needs no network.
    if [ "$_was_airplane" = "1" ]; then
        log "INFO: Restoring airplane mode"
        wifi_disable
    fi

    case "$result" in
        0) log "INFO: Fresh image received"
           _CONSECUTIVE_FAILURES=0 ;;
        2) log "WARN: Showing cached image (server unreachable)"
           _CONSECUTIVE_FAILURES=$(( _CONSECUTIVE_FAILURES + 1 )) ;;
        1) log "ERROR: Fetch failed and no cached image"
           _CONSECUTIVE_FAILURES=$(( _CONSECUTIVE_FAILURES + 1 ))
           display_error "Fetch failed" "Is ${BYOS_URL} reachable?"
           return 1 ;;
    esac

    # Alert user after 20 consecutive failures (≈ server has been down a long time).
    if [ "$_CONSECUTIVE_FAILURES" -ge 20 ]; then
        log "WARN: 20 consecutive fetch failures -- showing alert"
        display_error "Server unreachable" "${_CONSECUTIVE_FAILURES} failures. Check BYOS_URL."
        _CONSECUTIVE_FAILURES=0
        return 0
    fi

    display_image "$FETCH_TMP"

    if [ "${DISPLAY_BATTERY:-true}" = "true" ]; then
        local b nxt
        b=$(get_battery_pct)
        nxt=$(next_refresh_time_str)
        display_battery_overlay "${b:-?}" "$(date '+%H:%M')" "$nxt"
    fi

    return 0
}

# ─── Daemon: inter-refresh wait ─────────────────────────────────────────────
_wait_for_next_refresh() {
    local total_secs="$1"
    local mode="${POWER_MODE:-hybrid}"
    log "DEBUG: _wait_for_next_refresh: ${total_secs}s mode=$mode"

    # deep_sleep mode: set RTC alarm and suspend between refreshes.
    if [ "$mode" = "deep_sleep" ] && [ "$total_secs" -gt 90 ]; then
        log "INFO: deep_sleep for ${total_secs}s (RTC wake)"
        allow_sleep
        schedule_rtc_wake "$total_secs"
        deep_sleep
        # -- resumes here after RTC wake --
        log "INFO: Resumed from deep_sleep inter-refresh suspend"
        prevent_sleep
        sleep 3   # let system settle
        return
    fi

    # always_on / hybrid: sleep in 1s increments so SIGTERM interrupts promptly.
    log "DEBUG: _wait_for_next_refresh: polling sleep (${total_secs}s)"
    local _i=0
    while [ "$_i" -lt "$total_secs" ]; do
        sleep 1
        _i=$(( _i + 1 ))
    done
    log "DEBUG: _wait_for_next_refresh: poll complete"
}

# ─── Daemon: main loop ───────────────────────────────────────────────────────
_run_daemon() {
    _check_dependencies

    # Singleton: use tmp+mv to minimise (not eliminate) race window.
    if [ -f "$LOCK_FILE" ]; then
        local existing
        existing=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
            log "INFO: Stopping existing daemon (PID $existing)"
            kill -TERM "$existing" 2>/dev/null
            # Wait up to 5s for it to exit, then force-kill.
            local _w=0
            while kill -0 "$existing" 2>/dev/null && [ "$_w" -lt 5 ]; do
                sleep 1; _w=$(( _w + 1 ))
            done
            kill -0 "$existing" 2>/dev/null && kill -KILL "$existing" 2>/dev/null
        fi
        rm -f "$LOCK_FILE"
    fi
    printf '%s\n' "$$" > "${LOCK_FILE}.tmp" 2>/dev/null
    mv "${LOCK_FILE}.tmp" "$LOCK_FILE" 2>/dev/null || {
        log "ERROR: Could not write lock file $LOCK_FILE"
        exit 1
    }

    _load_config

    # Config-file override: STOP_FRAMEWORK=true also enables framework stop.
    if [ "${STOP_FRAMEWORK:-false}" = "true" ]; then
        _STOP_FRAMEWORK=1
    fi

    log "INFO: Daemon start (PID=$$, mode=${POWER_MODE:-hybrid}, fw=$(get_fw_version), framework_stop=${_STOP_FRAMEWORK})"
    log "INFO: Server=${BYOS_URL}, hours=${ACTIVE_HOURS:-all}, schedule=${REFRESH_TIMES:-interval ${REFRESH_INTERVAL:-900}s}"

    # Restore normal sleep on any exit.
    trap '_daemon_cleanup; exit 0' EXIT INT TERM

    # Stop the framework first if requested (must happen before hide_status_bar).
    [ "$_STOP_FRAMEWORK" = "1" ] && _framework_stop

    prevent_sleep
    hide_status_bar
    _start_exit_watchers

    # Always do one immediate refresh at daemon start so the user sees a
    # current dashboard right away, even when outside ACTIVE_HOURS.
    local _startup_refreshed=0
    log "INFO: Startup bootstrap refresh: fetching initial display"
    if _do_refresh; then
        _startup_refreshed=1
    fi

    # Match normal post-refresh WiFi policy after bootstrap fetch.
    local _startup_mode="${POWER_MODE:-hybrid}"
    if [ "$_startup_mode" != "always_on" ] || ! is_charging; then
        wifi_disable
    fi

    while true; do
        # ── Battery safety check ──────────────────────────────────────────────
        local batt
        batt=$(get_battery_pct)
        if [ -n "$batt" ] && [ "$batt" -lt "${LOW_BATTERY_THRESHOLD:-15}" ]; then
            if ! is_charging; then
                log "WARN: Battery ${batt}% below threshold -- stopping daemon"
                display_error "Low battery: ${batt}%" "Daemon stopped. Plug in to resume."
                exit 0
            fi
        fi

        local mode="${POWER_MODE:-hybrid}"

        # ── Outside active window? ────────────────────────────────────────────
        if [ "$mode" != "always_on" ] && ! is_in_active_window; then
            log "INFO: Outside active window -- sleeping"
            wifi_disable
            allow_sleep

            if [ "${BLANK_OUTSIDE_HOURS:-false}" = "true" ]; then
                eips -c
            fi

            local sleep_secs
            if [ -n "${REFRESH_TIMES:-}" ]; then
                sleep_secs=$(seconds_until_next_scheduled_refresh)
            else
                sleep_secs=$(seconds_until_next_active)
            fi

            if [ "$sleep_secs" -gt 120 ]; then
                log "INFO: RTC sleep for ${sleep_secs}s -- wakes at $(next_refresh_time_str)"
                schedule_rtc_wake "$sleep_secs"
                deep_sleep
                # resumes after RTC/button wake
                log "INFO: Woke from outside-window sleep"
                prevent_sleep
                sleep 3   # let the input subsystem settle / quit prompt appear
                # A button/tap wake may have triggered the quit prompt. Redraw
                # the dashboard so the screen returns to it (not a blanked or
                # stale screen), and wait for any in-progress quit prompt to
                # resolve before proceeding.
                [ -f "$FETCH_TMP" ] && display_image "$FETCH_TMP" >/dev/null 2>&1
                _wait_prompt_clear

                # Fetch out-of-hours only if we woke early and are STILL outside
                # the active window (typically a manual wake). If wake reached
                # active hours, normal in-window logic below handles refresh.
                if ! is_in_active_window; then
                    log "INFO: Woke outside active window -- one out-of-hours refresh"
                    _do_refresh
                    if [ "$mode" != "always_on" ] || ! is_charging; then
                        wifi_disable
                    fi
                fi
            else
                sleep "$sleep_secs"
            fi
            continue
        fi

        # ── Inside active window — fetch and display ──────────────────────────
        prevent_sleep
        if [ "$_startup_refreshed" = "1" ]; then
            log "DEBUG: Skipping duplicate immediate refresh after startup bootstrap"
            _startup_refreshed=0
        else
            _do_refresh
        fi

        # After fetch, turn off WiFi unless always_on AND charging.
        if [ "$mode" != "always_on" ] || ! is_charging; then
            wifi_disable
        fi

        # ── Wait until next refresh ───────────────────────────────────────────
        local next_secs
        # Honour server-suggested refresh rate when REFRESH_TIMES is not in use.
        local server_rate
        server_rate=$(get_server_refresh_rate)
        if [ "${server_rate:-0}" -gt 0 ] && [ -z "${REFRESH_TIMES:-}" ]; then
            next_secs="$server_rate"
            [ "$next_secs" -lt 60 ] && next_secs=60
        else
            next_secs=$(get_next_refresh_seconds)
        fi

        log "INFO: Next refresh in ${next_secs}s (~$(next_refresh_time_str))"
        _wait_for_next_refresh "$next_secs"

    done
}

_daemon_cleanup() {
    trap - EXIT INT TERM   # prevent re-entrancy
    log "INFO: Daemon exiting (PID=$$)"
    show_status_bar
    allow_sleep
    wifi_disable
    rm -f "$PROMPT_LOCK" 2>/dev/null
    rm -f "$LOCK_FILE"     # remove lock before kill 0 can cut us short
    if [ "$_STOP_FRAMEWORK" = "1" ]; then
        # Restart the framework; it will take the user back to the home screen.
        _framework_start
    else
        # Navigate to the Kindle home screen so KUAL doesn't regain focus.
        lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
    fi
    kill -- -$$ 2>/dev/null  # kill the process group without signalling this shell
}

# ─── Entry point ─────────────────────────────────────────────────────────────
case "${1:-}" in
    --detached|--autostart)
        # Parse optional flags following the mode argument.
        shift
        for _arg in "$@"; do
            case "$_arg" in
                --framework_stop) _STOP_FRAMEWORK=1 ;;
            esac
        done
        _run_daemon
        ;;
    --framework_stop)
        # Launched from KUAL with framework-stop flag; forward it to detached.
        nohup /bin/sh "$0" --detached --framework_stop >> "$LOG_FILE" 2>&1 &
        eips -c
        _eips_put 0 5 "KindleTRMNL starting (no framework)..."
        _eips_put 0 7 "Check KUAL > TRMNL if nothing appears."
        ;;
    *)
        # Launched from KUAL (no args): detach from KUAL's process tree via nohup.
        nohup /bin/sh "$0" --detached >> "$LOG_FILE" 2>&1 &
        # Show a brief "starting" message so the user sees feedback.
        eips -c
        _eips_put 0 5 "KindleTRMNL starting..."
        _eips_put 0 7 "Check KUAL > TRMNL if nothing appears."
        ;;
esac
