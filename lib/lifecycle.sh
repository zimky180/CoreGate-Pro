restore_all() {
    [ "$1" = "preserve" ] || manual_clear
    rm -f "$THERMAL_STATE_FILE" "$THERMAL_STATE_FILE.$$.tmp"
    LOCK_LIST=$(all_cpus)
    rm -f "$CORE_REQUEST_FILE"
    do_unlock
    remove_freq_cap
    restore_core_ctl
    freeze_restore_all
}

TRAP_DONE=0
TRAP_ARMED=0
cleanup_on_exit() {
    [ "$TRAP_ARMED" = "1" ] || return 0
    [ "$TRAP_DONE" = "1" ] && exit 0
    TRAP_DONE=1
    if [ "$(cat "$CONFIG_DIR/core.lock/pid" 2>/dev/null)" = "$$" ]; then core_guard_leave; fi
    if [ -f "$MODDIR/module.prop" ] && [ ! -f "$MODDIR/remove" ] && [ ! -f "$MODDIR/disable" ]; then
        restore_all preserve
    else
        restore_all
    fi
    rm -f "$PID_FILE" "$CONFIG_DIR/crash_flag"
    log "模块服务已退出，全部恢复原始状态"
    exit 0
}
trap cleanup_on_exit TERM INT EXIT

run() {
    TRAP_ARMED=1
    freeze_wait_pms
    echo $$ > "$PID_FILE" 2>/dev/null
    rm -f "$CONFIG_DIR/high_cores" "$CORE_REQUEST_FILE"
    state=""; pkg=""; want_lock=""; last_pkg=""; lock_logged=0; ss=""; it2=0; last_ss=""
    prev_unlocked=0; oc_now=""
    GAME_HOLD=0; GAME_MISSES=0; FREQ_RESTORE_FAILED=0

    wc=0
    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$wc" -lt 90 ]; do
        sleep 1
        wc=$((wc+1))
    done
    sleep 5
    log "系统已就绪（等待 ${wc}s），开始初始化"

    CRASH_FLAG="$CONFIG_DIR/crash_flag"
    BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -n "$BOOT_ID" ] && [ "$(cat "$CRASH_FLAG" 2>/dev/null)" = "$BOOT_ID" ]; then
        SAFE_MODE=1
        log "⚠️ 检测到上次异常退出标记，进入【安全模式】：本次不封锁任何核心（重启一次后自动恢复）"
    else
        SAFE_MODE=0
    fi
    rm -f "$CRASH_FLAG" 2>/dev/null
    rm -f "$CONFIG_DIR"/giveup_* 2>/dev/null
    restore_core_ctl

    AUTO_COUNT=$(cfg_int auto_lock_count 0)
    DISABLE_CC=$(cfg_bool disable_core_ctl false)
    LOCK_LIST=$(cfg_val lock_cores auto)
    if [ "$LOCK_LIST" = "auto" ]; then
        LOCK_LIST=$(detect_high)
    else
        LOCK_LIST=$(echo "$LOCK_LIST" | tr ',、' ' ' | tr -s ' ')
    fi

    if [ -z "$LOCK_LIST" ]; then
        log "⚠️ 未检测到可封锁的核心，模块将只做游戏检测，不封锁任何核心"
    elif [ "$lock_logged" = "0" ]; then
        log "封锁核心名单：$LOCK_LIST"
        lock_logged=1
    fi

    ENABLED=$(cfg_bool enabled false)
    thermal_update
    GAME_LIST=$(grep -v '^#' "$PACKAGES_FILE" 2>/dev/null | grep -v '^$')
    GAME_ACTIVE=0
    PKGS=$(fg_pkgs)
    if [ -n "$GAME_LIST" ] && is_game "$PKGS"; then GAME_ACTIVE=1; GAME_HOLD=1; fi
    want_lock=yes
    [ "$GAME_ACTIVE" = 1 ] && want_lock=no
    CAPTURE_BOOST=$(cfg_bool capture_boost false)
    CAPTURE_LIST=""
    if [ "$CAPTURE_BOOST" = true ]; then
        CAPTURE_LIST=$(grep -v '^#' "$CAPTURE_FILE" 2>/dev/null | grep -v '^$')
        [ -n "$CAPTURE_LIST" ] || CAPTURE_LIST="$CAPTURE_DEFAULT"
        [ -n "$CAPTURE_LIST" ] && is_capture "$PKGS" && want_lock=no
    fi
    NO_CHARGE=$(cfg_bool no_lock_charging false)
    [ "$NO_CHARGE" = true ] && is_charging && want_lock=no
    game_scene_select
    thermal_decide
    if [ "$want_lock" = no ] && [ "$ENABLED" = true ] && [ "$SAFE_MODE" = 0 ]; then
        restore_performance
        echo "$state|$(echo "$PKGS" | head -1)" > "$STATE_FILE"
    elif [ "$ENABLED" = "true" ] && [ -n "$LOCK_LIST" ] && [ "$SAFE_MODE" = "0" ] &&
        { [ "$THERMAL_HOT" != "1" ] || [ "$THERMAL_MODE" != "unlock" ]; }; then
        printf '%s\n' "$BOOT_ID" > "$CRASH_FLAG"
        do_lock
        sleep 20
        rm -f "$CRASH_FLAG"
        state="locked"
        echo "locked|boot" > "$STATE_FILE"
        log "启动完成，日常模式：大核已封锁"
    elif [ "$ENABLED" = "true" ] && [ "$SAFE_MODE" = "0" ] && [ "$THERMAL_HOT" = "1" ] && [ "$THERMAL_MODE" = "unlock" ]; then
        restore_performance
        echo "$state|boot" > "$STATE_FILE"
        log "启动完成，温度策略：恢复全部核心"
    elif [ "$SAFE_MODE" = "1" ]; then
        echo "safe|-" > "$STATE_FILE"
        log "启动完成（安全模式：未封锁任何核心）"
        state="safe"
    else
        echo "off|-" > "$STATE_FILE"
        log "启动完成（模块禁用或无可封锁核心）"
        state="off"
    fi

    while :; do
        if [ ! -f "$MODDIR/module.prop" ] || [ -f "$MODDIR/remove" ] || [ -f "$MODDIR/disable" ] || [ -f "/data/adb/modules/${MODULE_ID}.disable" ]; then
            log "检测到模块已删除/禁用，恢复全部核心并退出"
            cleanup_on_exit
        fi

        ENABLED=$(cfg_bool enabled false)
        AUTO_COUNT=$(cfg_int auto_lock_count 0)
        DISABLE_CC=$(cfg_bool disable_core_ctl false)
        LOCK_LIST=$(cfg_val lock_cores auto)
        if [ "$LOCK_LIST" = "auto" ]; then
            LOCK_LIST=$(detect_high)
        else
            LOCK_LIST=$(echo "$LOCK_LIST" | tr ',、' ' ' | tr -s ' ')
        fi
        LIMIT_FREQ=$(cfg_bool limit_freq false)
        INTERVAL=$(cfg_int poll_interval 10)
        NO_CHARGE=$(cfg_bool no_lock_charging false)
        GAME_LIST=$(grep -v '^#' "$PACKAGES_FILE" 2>/dev/null | grep -v '^$')
        CAPTURE_BOOST=$(cfg_bool capture_boost false)
        if [ "$CAPTURE_BOOST" = "true" ]; then
            CAPTURE_LIST=$(grep -v '^#' "$CAPTURE_FILE" 2>/dev/null | grep -v '^$')
            [ -z "$CAPTURE_LIST" ] && CAPTURE_LIST="$CAPTURE_DEFAULT"
        else
            CAPTURE_LIST=""
        fi

        case "$INTERVAL" in
            ''|*[!0-9]*) INTERVAL=10;;
        esac
        [ "$INTERVAL" -lt 5 ] && INTERVAL=5
        [ "$INTERVAL" -gt 600 ] && INTERVAL=600

        thermal_update

        # ---- 第一级短路：模块总开关关闭 / 安全模式 ----
        if [ "$ENABLED" != "true" ] || [ "$SAFE_MODE" = "1" ]; then
            GAME_HOLD=0; GAME_MISSES=0
            if remove_freq_cap; then FREQ_RESTORE_FAILED=0; else FREQ_RESTORE_FAILED=1; fi
            if { [ "$state" != "off" ] && [ "$state" != "safe" ]; } || [ -n "$UNLOCK_FAILED" ] ||
                [ "$(cat "$CORE_REQUEST_FILE" 2>/dev/null)" != unlocked ]; then
                do_unlock
                restore_core_ctl
                remove_freq_cap
                last_pkg=""
                if [ "$SAFE_MODE" = "1" ]; then
                    state="safe"
                    echo "safe|-" > "$STATE_FILE"
                    log "进入安全模式：核心全部恢复"
                else
                    state="off"
                    echo "off|-" > "$STATE_FILE"
                    log "模块已禁用，核心全部恢复"
                fi
            fi
            if [ "$FREQ_RESTORE_FAILED" = 1 ] || [ -n "$UNLOCK_FAILED" ]; then
                state=unlock_partial
                echo "$state|-" > "$STATE_FILE"
            fi
            sleep "$INTERVAL"
            continue
        fi

        # ---- 第二级短路：所有策略均未开启时的空闲稳态 ----
        _pam=$(policy_active_mask)
        if [ -z "$_pam" ]; then
            GAME_HOLD=0; GAME_MISSES=0; GAME_ACTIVE=0
            want_lock=yes
            state_changed=0
            [ "$state" != "locked" ] && state_changed=1
            do_lock
            if [ "$state_changed" = "1" ]; then
                oc_now=$(online_count)
                log "空闲稳态：无任何策略开启，仅保持锁核（在线 ${oc_now} 个）"
            fi
            state="locked"
            if [ "$(cat "$STATE_FILE" 2>/dev/null)" != "locked|boot" ]; then
                last_pkg=""
                echo "locked|boot" > "$STATE_FILE"
            fi
            if [ "$INTERVAL" -gt 20 ]; then _idle_sleep=$INTERVAL; else _idle_sleep=20; fi
            sleep "$_idle_sleep"
            continue
        fi

        if [ "$SAFE_MODE" = "1" ]; then
            freeze_restore_all
        else
            freeze_sync
        fi
        prev_unlocked=0
        [ "$state" = "unlocked" ] && prev_unlocked=1

        ss=$(screen_sysfs)
        if [ "$ss" = "UNKNOWN" ]; then
            it2=$((it2+1))
            if [ -z "$last_ss" ] || [ $((it2 % 5)) -eq 1 ]; then
                w=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | sed 's/.*mWakefulness=//')
                if [ "$w" = "Asleep" ] || [ "$w" = "Dozing" ]; then ss="OFF"; else ss="ON"; fi
                last_ss="$ss"
            else
                ss="$last_ss"
            fi
        else
            last_ss="$ss"
        fi

        if [ "$ss" = "OFF" ]; then
            PKGS=""
        else
            PKGS=$(fg_pkgs)
        fi
        pkg=$(echo "$PKGS" | head -1)

        want_lock=yes
        GAME_ACTIVE=0
        if [ "$ss" != "OFF" ]; then
            if [ -n "$GAME_LIST" ] && is_game "$PKGS"; then GAME_ACTIVE=1; want_lock=no; fi
            [ "$want_lock" = "yes" ] && [ -n "$CAPTURE_LIST" ] && is_capture "$PKGS" && want_lock=no
        fi
        if [ "$want_lock" = "yes" ] && [ "$NO_CHARGE" = "true" ] && is_charging; then
            want_lock=no
        fi

        game_exit_confirm

        game_scene_select
        thermal_decide

        if [ "$want_lock" = "yes" ]; then
            state_changed=0
            [ "$state" != "locked" ] && state_changed=1
            if [ "$state_changed" = "1" ]; then
                log "切换为日常模式：封锁大核（前台: $pkg）"
            fi
            do_lock
            if [ "$LIMIT_FREQ" = "true" ] && [ "$GAME_ACTIVE" != 1 ]; then
                apply_freq_cap
            else
                remove_freq_cap
            fi
            if [ "$state_changed" = "1" ]; then
                oc_now=$(online_count)
                log "封锁结果：[${LOCK_STATE}] 当前在线核心 ${oc_now} 个"
            fi
            state="locked"
            if [ "$last_pkg" != "$pkg" ] || [ "$(cat "$STATE_FILE" 2>/dev/null)" != "$state|$pkg" ]; then
                last_pkg="$pkg"
                echo "locked|$pkg" > "$STATE_FILE"
            fi
        else
            if [ "$state" != "unlocked" ]; then
                log "请求性能模式：恢复核心与频率上限（前台: $pkg）"
            fi
            restore_performance
            if [ "$last_pkg" != "$pkg" ] || [ "$(cat "$STATE_FILE" 2>/dev/null)" != "$state|$pkg" ]; then
                last_pkg="$pkg"
                echo "$state|$pkg" > "$STATE_FILE"
            fi
        fi

        if [ "$state" != "locked" ]; then
            sleep "$INTERVAL"
        elif [ "$prev_unlocked" = "1" ] || [ "$state_changed" = "1" ]; then
            sleep 5
        else
            sleep "$INTERVAL"
        fi
    done
}

