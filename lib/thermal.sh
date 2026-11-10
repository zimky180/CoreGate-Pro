game_scene_select() {
    GAME_LOCK_ACTIVE=0
    GAME_LOCK_LIST=""
    [ "$GAME_ACTIVE" = 1 ] || return 0
    local c raw
    raw=$(cfg_val game_lock_cores "" | tr ',、' ' ')
    for c in $raw; do
        case "$c" in ''|0|*[!0-9]*) continue;; esac
        case " $(all_cpus) " in *" $c "*) ;; *) continue;; esac
        case " $GAME_LOCK_LIST " in *" $c "*) continue;; esac
        GAME_LOCK_LIST="$GAME_LOCK_LIST $c"
    done
    [ -n "$GAME_LOCK_LIST" ] || return 0
    [ "$NO_CHARGE" = true ] && is_charging && return 0
    [ -n "$CAPTURE_LIST" ] && is_capture "$PKGS" && return 0
    GAME_LOCK_ACTIVE=1
    want_lock=yes
}

# 短路路径下也要保证状态串字段合法（App 侧解析用）
THERMAL_MODE="lock"
THERMAL_THRESHOLD=40
THERMAL_EXTRA_CONFIG=""
_thermal_status=disabled
THERMAL_HOT=0
THERMAL_KEY=""
THERMAL_EXTRA_ACTIVE=""
THERMAL_TEMP=""
THERMAL_STATE_FILE="$CONFIG_DIR/temperature.state"

thermal_read() {
    cg_temperature | cut -f1
}

thermal_publish() {
    printf '%s|%s|%s|%s|%s|battery|%s|%s\n' "$_thermal_status" "$THERMAL_TEMP" "$THERMAL_MODE" "$THERMAL_THRESHOLD" "$(date +%s)" "$THERMAL_EXTRA_CONFIG" "$THERMAL_EXTRA_ACTIVE" > "$THERMAL_STATE_FILE.$$.tmp" &&
        mv -f "$THERMAL_STATE_FILE.$$.tmp" "$THERMAL_STATE_FILE"
}

thermal_select_extra() {
    THERMAL_EXTRA_ACTIVE=""
    _extra_raw=$(printf '%s' "$THERMAL_EXTRA_CONFIG" | tr ',、' ' ')
    for _extra_cpu in $_extra_raw; do
        case "$_extra_cpu" in ''|*[!0-9]*) continue;; esac
        [ -d "$CG_CPU_ROOT/cpu$_extra_cpu" ] || continue
        case " $THERMAL_EXTRA_ACTIVE " in *" $_extra_cpu "*) continue;; esac
        THERMAL_EXTRA_ACTIVE="$THERMAL_EXTRA_ACTIVE $_extra_cpu"
    done
}

thermal_decide() {
    THERMAL_EXTRA_ACTIVE=""
    if [ "$THERMAL_HOT" = 1 ]; then
        if [ "$THERMAL_MODE" = unlock ]; then
            want_lock=no
        elif [ "$want_lock" = yes ]; then
            thermal_select_extra
            [ -n "$THERMAL_EXTRA_ACTIVE" ] || _thermal_status=no_extra
        else
            _thermal_status=scene_skipped
        fi
    fi
    thermal_publish
}

thermal_update() {
    THERMAL_ENABLED=$(cfg_bool temperature_enabled false)
    # 温度策略未开启时立即短路：不读传感器、不做比较，只发布一次合法状态串。
    # 这是模块最主要的空闲路径，必须保证 sh 进程本身几乎零开销。
    if [ "$THERMAL_ENABLED" != "true" ]; then
        THERMAL_MODE="lock"
        THERMAL_THRESHOLD=40
        THERMAL_EXTRA_CONFIG=""
        THERMAL_EXTRA_ACTIVE=""
        THERMAL_HOT=0
        THERMAL_TEMP=""
        _thermal_status=disabled
        THERMAL_KEY=""
        thermal_publish
        return 0
    fi
    THERMAL_MODE=$(cfg_val temperature_mode lock)
    [ "$THERMAL_MODE" = "unlock" ] || THERMAL_MODE=lock
    THERMAL_THRESHOLD=$(cfg_int temperature_threshold 40)
    case "$THERMAL_THRESHOLD" in ''|*[!0-9]*) THERMAL_THRESHOLD=40;; esac
    [ "$THERMAL_THRESHOLD" -lt 35 ] && THERMAL_THRESHOLD=35
    [ "$THERMAL_THRESHOLD" -gt 60 ] && THERMAL_THRESHOLD=60
    THERMAL_EXTRA_CONFIG=$(cfg_val temperature_lock_cores "")
    THERMAL_EXTRA_ACTIVE=""
    _tk="$THERMAL_ENABLED|$THERMAL_MODE|$THERMAL_THRESHOLD|$THERMAL_EXTRA_CONFIG|$ENABLED|$SAFE_MODE"
    if [ "$THERMAL_KEY" != "$_tk" ]; then THERMAL_HOT=0; THERMAL_KEY="$_tk"; fi
    _old_hot="$THERMAL_HOT"
    THERMAL_TEMP=""
    _thermal_status=disabled
    if [ "$THERMAL_ENABLED" = "true" ] && [ "$ENABLED" = "true" ] && [ "$SAFE_MODE" != "1" ]; then
        THERMAL_TEMP=$(thermal_read)
        if [ -z "$THERMAL_TEMP" ]; then
            THERMAL_HOT=0; _thermal_status=unavailable
        else
            if [ "$THERMAL_TEMP" -ge "$((THERMAL_THRESHOLD * 1000))" ]; then
                THERMAL_HOT=1
            elif [ "$THERMAL_TEMP" -le "$(((THERMAL_THRESHOLD - 3) * 1000))" ]; then
                THERMAL_HOT=0
            fi
            _thermal_status=watching
            [ "$THERMAL_HOT" = "1" ] && _thermal_status=active
        fi
    else
        THERMAL_HOT=0
    fi
    if [ "$_old_hot" != "$THERMAL_HOT" ]; then
        log "温度策略：$_thermal_status mode=$THERMAL_MODE temp=${THERMAL_TEMP}mC threshold=${THERMAL_THRESHOLD}C"
    fi
}

