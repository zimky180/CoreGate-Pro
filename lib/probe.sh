screen_sysfs() {
    for b in /sys/class/backlight/*/bl_power; do
        [ -e "$b" ] || continue
        v=$(cat "$b" 2>/dev/null)
        case "$v" in 0) echo ON; return;; *) echo OFF; return;; esac
    done
    for b in /sys/class/backlight/*/actual_brightness /sys/class/backlight/*/brightness; do
        [ -e "$b" ] || continue
        v=$(cat "$b" 2>/dev/null)
        [ -n "$v" ] && [ "$v" = "0" ] && { echo OFF; return; }
        [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && { echo ON; return; }
    done
    echo UNKNOWN
}

_fg_extract() {
    sed -nE 's/.*[ {]([a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+)\/[^ ]*.*/\1/p'
}
fg_pkgs() {
    window_pkgs=$(dumpsys window 2>/dev/null \
        | grep -E 'mCurrentFocus|mFocusedApp|mHoldScreenWindow|mTopFullscreenOpaque|mObscuringWindow|mFocusedWindow' \
        | _fg_extract)
    active_pkgs=$(dumpsys activity activities 2>/dev/null \
        | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity' \
        | _fg_extract)
    if [ -z "$active_pkgs" ]; then
        active_pkgs=$(dumpsys activity 2>/dev/null \
            | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity' \
            | _fg_extract)
    fi
    printf '%s\n' "$window_pkgs" "$active_pkgs" | sed '/^$/d' | sort -u
}
is_game() {
    local pkg line
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        case "$pkg" in null) continue;; esac
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in \#*) continue;; esac
            [ "$pkg" = "$line" ] && return 0
        done <<LIST
$GAME_LIST
LIST
    done <<PKGS
$1
PKGS
    return 1
}
is_capture() {
    local pkg line
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        case "$pkg" in null) continue;; esac
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in \#*) continue;; esac
            [ "$pkg" = "$line" ] && return 0
        done <<LIST
$CAPTURE_LIST
LIST
    done <<PKGS
$1
PKGS
    return 1
}

is_charging() {
    s=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    if [ "$s" = "Charging" ] || [ "$s" = "Full" ]; then return 0; fi
    dumpsys battery 2>/dev/null | grep -qE 'AC powered: true|USB powered: true|Wireless powered: true'
}

game_exit_confirm() {
    local wake retry_pkgs
    if [ "$GAME_ACTIVE" = 1 ]; then
        GAME_HOLD=1; GAME_MISSES=0; return 0
    fi
    [ "${GAME_HOLD:-0}" = 1 ] || return 0
    if [ "$ss" = OFF ]; then
        wake=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)
        case "$wake" in
            Asleep|Dozing) GAME_HOLD=0; GAME_MISSES=0; return 0;;
            Awake|Dreaming) ss=ON;;
            *) want_lock=no; GAME_ACTIVE=1; return 0;;
        esac
    fi
    sleep 1
    retry_pkgs=$(fg_pkgs)
    if [ -n "$GAME_LIST" ] && is_game "$retry_pkgs"; then
        PKGS="$retry_pkgs"; pkg=$(printf '%s\n' "$PKGS" | head -1)
        GAME_ACTIVE=1; want_lock=no; GAME_MISSES=0
        return 0
    fi
    GAME_MISSES=$((${GAME_MISSES:-0} + 1))
    log "游戏退出复核：screen=$ss miss=$GAME_MISSES candidates=$(printf '%s' "$PKGS" | tr '\n' ',') retry=$(printf '%s' "$retry_pkgs" | tr '\n' ',')"
    if [ "$GAME_MISSES" -lt 2 ]; then
        GAME_ACTIVE=1; want_lock=no
    else
        GAME_HOLD=0; GAME_MISSES=0
    fi
}
