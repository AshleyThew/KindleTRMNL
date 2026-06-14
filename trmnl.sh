#!/bin/sh
# KindleTRMNL — Main daemon (single-file)
#
# Invocation modes:
#   (no args)       — called from KUAL; re-execs self with nohup to detach
#   --detached      — actual daemon loop (forked from above)
#   --autostart     — same as --detached; used by Upstart boot job
#
# Exits automatically when the power button is pressed or the screen is tapped.
#
# Install path: /mnt/us/extensions/KindleTRMNL/trmnl.sh

# ─── Paths ───────────────────────────────────────────────────────────────────
_STOP_FRAMEWORK=0   # set to 1 if --framework_stop arg or STOP_FRAMEWORK=true in config

EXT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$EXT_DIR/config.conf"
LOG_FILE="$EXT_DIR/logs/trmnl.log"
CACHE_DIR="$EXT_DIR/cache"
LOCK_FILE="/tmp/trmnl.lock"
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

wifi_enable() {
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
    local timeout="${WIFI_TIMEOUT:-30}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local iface
        iface=$(lipc-get-prop com.lab126.cmd activeInterface 2>/dev/null)
        if [ "$iface" = "wifi" ]; then
            # Interface is selected, but the connection may not be fully
            # established (no IP yet). Wait for the WiFi daemon to report a
            # CONNECTED state before proceeding.
            local cmstate
            cmstate=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
            case "$cmstate" in
                CONNECTED|'') # '' = daemon doesn't expose cmState; accept iface=wifi
                    # Some devices report "connected" before the network stack
                    # is ready for HTTP. Give it a moment to stabilize so the
                    # first fetch doesn't fail and fall back to the cached image.
                    local settle="${NETWORK_SETTLE_SECS:-2}"
                    [ "$settle" -gt 0 ] 2>/dev/null && sleep "$settle"
                    return 0
                    ;;
            esac
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    return 1
}

wifi_disable() {
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
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
    lipc-set-prop com.lab126.powerd rtcWakeup "$seconds" 2>/dev/null
}

deep_sleep() {
    for _dev in /sys/bus/usb/devices/*/power/wakeup; do
        [ -f "$_dev" ] && echo disabled > "$_dev" 2>/dev/null
    done
    echo mem > /sys/power/state 2>/dev/null
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
        _SCREEN_W="${_SCREEN_W:-758}"
        _SCREEN_H="${_SCREEN_H:-1024}"
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
    local bottom_row=$(( _SCREEN_H / 18 - 1 ))
    local status_line="Batt:${batt}%  Last:${last}  Next:${nxt}"
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

    log "DEBUG: mac=$mac batt=${batt}% w=${_SCREEN_W:-758} h=${_SCREEN_H:-1024}"

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
        log "WARN: BYOS JSON fetch returned HTTP $http_code"
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
        rm -f "$dest"
        log "WARN: Image download returned HTTP $img_code"
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
    [ "$now_s" -ge "$start_s" ] && [ "$now_s" -lt "$end_s" ]
}

seconds_until_next_active() {
    local window="${ACTIVE_HOURS:-00:00-23:59}"
    local start
    start=$(echo "$window" | cut -d- -f1)
    local now_s start_s
    now_s=$(_now_secs)
    start_s=$(_hm_to_secs "$start")
    local diff=$(( start_s - now_s ))
    if [ "$diff" -gt 0 ]; then
        echo "$diff"
    else
        echo $(( 86400 + diff ))
    fi
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
# Spawns two background processes that send SIGTERM to the daemon when the
# user presses the power button or taps the screen.
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

_start_exit_watchers() {
    local _dpid="$$"

    # Power button: fires when device is about to sleep.
    ( lipc-wait-event com.lab126.powerd goingToSleep >/dev/null 2>&1
      log "INFO: goingToSleep event -- exiting"
      kill -TERM "$_dpid" 2>/dev/null ) &

    # Screen tap: read one input event from the touchscreen device.
    local _tdev
    _tdev=$(_find_touch_dev)
    if [ -r "$_tdev" ]; then
        ( dd if="$_tdev" bs=16 count=1 >/dev/null 2>&1
          log "INFO: Touch event -- exiting"
          kill -TERM "$_dpid" 2>/dev/null ) &
    fi
}

# ─── Daemon: one fetch-and-display cycle ─────────────────────────────────────
# Returns 0 on success (fresh or cached), 1 on hard failure (no image at all).
_CONSECUTIVE_FAILURES=0

_do_refresh() {
    log "INFO: Fetching from $BYOS_URL ..."
    local result

    if wifi_enable; then
        fetch_display_image
        result=$?
    else
        log "WARN: WiFi did not associate within ${WIFI_TIMEOUT:-30}s -- using cache"
        _fetch_use_cache
        result=$?
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

    # deep_sleep mode: set RTC alarm and suspend between refreshes.
    if [ "$mode" = "deep_sleep" ] && [ "$total_secs" -gt 90 ]; then
        log "INFO: deep_sleep for ${total_secs}s (RTC wake)"
        allow_sleep
        schedule_rtc_wake "$total_secs"
        deep_sleep
        # -- resumes here after RTC wake --
        prevent_sleep
        sleep 3   # let system settle
        return
    fi

    # always_on / hybrid: sleep in 1s increments so SIGTERM interrupts promptly.
    local _i=0
    while [ "$_i" -lt "$total_secs" ]; do
        sleep 1
        _i=$(( _i + 1 ))
    done
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

    # Always display once on first start, then honour the schedule thereafter.
    local _first_run=1

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

        # ── Outside active window? (first start always displays once) ─────────
        if [ "$_first_run" != "1" ] && [ "$mode" != "always_on" ] && ! is_in_active_window; then

            log "INFO: Outside active window -- sleeping"
            wifi_disable
            allow_sleep

            if [ "${BLANK_OUTSIDE_HOURS:-false}" = "true" ]; then
                eips -c
            fi

            local sleep_secs
            sleep_secs=$(seconds_until_next_active)

            if [ "$sleep_secs" -gt 120 ]; then
                log "INFO: RTC sleep for ${sleep_secs}s -- wakes at $(next_refresh_time_str)"
                schedule_rtc_wake "$sleep_secs"
                deep_sleep
                # resumes after RTC/button wake
                log "INFO: Woke from outside-window sleep"
                prevent_sleep
                sleep 3
            else
                sleep "$sleep_secs"
            fi
            continue
        fi

        # ── Inside active window — fetch and display ──────────────────────────
        prevent_sleep
        _do_refresh

        # After fetch, turn off WiFi unless always_on AND charging.
        if [ "$mode" != "always_on" ] || ! is_charging; then
            wifi_disable
        fi

        # If this was the forced first-start refresh and we are actually
        # outside the active window, loop back so the daemon deep-sleeps
        # until the window opens instead of busy-waiting here.
        if [ "$_first_run" = "1" ]; then
            _first_run=0
            if [ "$mode" != "always_on" ] && ! is_in_active_window; then
                continue
            fi
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
