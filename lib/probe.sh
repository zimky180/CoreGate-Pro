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

# 策略活跃掩码：返回非空表示至少有一个策略开关处于开启状态，需要完整扫描。
# 返回空字符串表示全部策略关闭，主循环可直接进入空闲快速路径，
# 不读温度、不读电池、不调 dumpsys、不扫 pm list packages，
# 避免 sh 常驻进程本身成为耗电源。
# 标记位语义：
#   cap    = 录屏/相机自动恢复（capture_boost）
#   charge = 充电时不锁核（no_lock_charging）
#   thermal= 温度策略
#   game   = 游戏检测（packages.txt 有非注释条目 或 game_lock_cores 非空）
#   freq   = 限频
#   freeze = 冻结调度（任一 freeze_grp_* 开启 或 存在手动冻结记录）
policy_active_mask() {
    _pam=""
    [ "$(cfg_bool capture_boost false)" = "true" ] && _pam="$_pam cap"
    [ "$(cfg_bool no_lock_charging false)" = "true" ] && _pam="$_pam charge"
    [ "$(cfg_bool temperature_enabled false)" = "true" ] && _pam="$_pam thermal"
    if [ -n "$(grep -v '^#' "$PACKAGES_FILE" 2>/dev/null | grep -v '^$' | head -1)" ] ||
        [ -n "$(cfg_val game_lock_cores '')" ]; then
        _pam="$_pam game"
    fi
    [ "$(cfg_bool limit_freq false)" = "true" ] && _pam="$_pam freq"
    for _grp in log media cloud diag ad self ai voice games themes search; do
        if [ "$(cfg_bool "freeze_grp_$_grp" false)" = "true" ]; then _pam="$_pam freeze"; break; fi
    done
    if [ -s "$FREEZE_MANUAL" ] || [ -s "$FREEZE_STATE" ]; then
        case " $_pam " in *" freeze "*) ;; *) _pam="$_pam freeze";; esac
    fi
    printf '%s' "$_pam"
}
