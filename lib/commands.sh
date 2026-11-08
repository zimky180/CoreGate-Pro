lock_once() {
    AUTO_COUNT=$(cfg_int auto_lock_count 0)
    ENABLED=$(cfg_bool enabled false)
    if [ -n "$1" ]; then
        case "$1" in
            *[!0-9]*) : ;;
            *) AUTO_COUNT="$1"; [ "$AUTO_COUNT" -lt 1 ] && AUTO_COUNT=0;
               : ;;
        esac
    fi
    LOCK_LIST=$(cfg_val lock_cores auto)
    if [ "$LOCK_LIST" = "auto" ]; then
        LOCK_LIST=$(detect_high)
    else
        LOCK_LIST=$(echo "$LOCK_LIST" | tr ',、' ' ' | tr -s ' ')
    fi
    if [ -n "$1" ]; then
        case "$1" in
            ''|*[!0-9]*) : ;;
            *)
                n="$1"
                [ "$n" -lt 1 ] && n=0
                :
                LOCK_LIST=$(echo "$LOCK_LIST" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nr | head -n "$n" | tr '\n' ' ')
                ;;
        esac
    fi
    DISABLE_CC=$(cfg_bool disable_core_ctl false)
    LIMIT_FREQ=$(cfg_bool limit_freq false)

    if [ "$ENABLED" != "true" ]; then
        echo "LOCK_ONCE: 模块已禁用，跳过封锁"
        exit 0
    fi
    if [ -z "$LOCK_LIST" ]; then
        echo "LOCK_ONCE: 无可封锁核心"
        exit 0
    fi

    rm -f "$CORE_REQUEST_FILE"
    do_lock
    _lock_rc=$?
    if [ "$LIMIT_FREQ" = "true" ]; then
        apply_freq_cap
    else
        remove_freq_cap
    fi
    oc=$(online_count)
    echo "LOCK_ONCE_DONE: 名单=[$LOCK_LIST] 结果=[${LOCK_STATE}] 在线=${oc}"
    exit "$_lock_rc"
}

unlock_once() {
    manual_clear
    rm -f "$CORE_REQUEST_FILE"
    LOCK_LIST=$(cfg_val lock_cores auto)
    if [ "$LOCK_LIST" = "auto" ]; then
        LOCK_LIST=$(detect_high)
    else
        LOCK_LIST=$(echo "$LOCK_LIST" | tr ',、' ' ' | tr -s ' ')
    fi
    restore_performance
    oc=$(online_count)
    if [ "$state" != unlocked ]; then
        echo "UNLOCK_ONCE_FAILED: 在线=${oc} 仍离线=[$UNLOCK_FAILED] 限频恢复失败=${FREQ_RESTORE_FAILED:-0}"
        exit 1
    fi
    echo "UNLOCK_ONCE_DONE: 在线=${oc}"
    echo "OK"
    exit 0
}

case "$1" in
    --lock-once)
        shift
        lock_once "$1"
        ;;
    --unlock-once)
        unlock_once
        ;;
    --core-off|--core-on)
        _action="$1"; _c="$2"
        case "$_c" in ''|*[!0-9]*) echo BADCPU; exit 1;; esac
        core_guard_enter || { echo FAIL; exit 1; }
        _result=1
        if [ "$_action" = --core-off ]; then
            if set_cpu "$_c" 0; then manual_add "$_c" && _result=0; fi
        else
            if set_cpu "$_c" 1; then manual_del "$_c" && _result=0; fi
        fi
        if [ "$_result" = 0 ]; then
            : > "$CONFIG_DIR/core.selection" || _result=1
            _manual=$(manual_list | xargs)
            printf 'locked:%s\n' "$(core_normalize "$_manual")" > "$CORE_REQUEST_FILE" || _result=1
        fi
        core_guard_leave
        if [ "$_result" = 0 ]; then echo OK; else echo FAIL; fi
        exit "$_result"
        ;;
    --core-clear)
        manual_clear
        unlock_once
        ;;
    --core-list)
        manual_list | tr '\n' ' '
        echo ""
        ;;
    --freeze-status)
        _status_actual=$(freeze_status_report)
        echo "[applied]"
        if [ -f "$FREEZE_STATE" ] && [ -s "$FREEZE_STATE" ]; then
            while IFS='	' read -r _p _st _md; do
                [ -z "$_p" ] && continue
                [ -z "$_md" ] && _md="disable"
                printf '%s\t%s\n' "$_p" "$_md"
            done < "$FREEZE_STATE"
        else
            _fb_actual=$(printf '%s\n' "$_status_actual" | cut -f1)
            echo "$FREEZE_TABLE" | while IFS= read -r _fb_line; do
                [ -z "$_fb_line" ] && continue
                _fb_key=$(printf %s "$_fb_line" | cut -d"|" -f1)
                freeze_group_on "$_fb_key" || continue
                for _fb_p in $(freeze_group_pkgs "$_fb_key"); do
                    [ -z "$_fb_p" ] && continue
                    echo "$_fb_actual" | grep -qxF "$_fb_p" || continue
                    printf "%s\t%s\n" "$_fb_p" "disable"
                done
            done
        fi
        echo "[actual]"
        printf '%s\n' "$_status_actual"
        echo "[groups]"
        echo "$FREEZE_TABLE" | while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            _k=$(printf %s "$_line" | cut -d"|" -f1)
            if freeze_group_on "$_k"; then echo "$_k	on"; else echo "$_k	off"; fi
        done
        exit 0
        ;;
    --set-freeze)
        _k="$2"
        _v="$3"
        if [ -z "$_k" ]; then echo "SET_FREEZE_FAIL: 缺组键"; exit 1; fi
        case "$_k" in
            grp_*) ;;
            *) _k="grp_$_k" ;;
        esac
        _kknown=""
        _kchk=$(echo "$FREEZE_TABLE" | while IFS= read -r _kl; do
            [ -z "$_kl" ] && continue
            [ "$(printf %s "$_kl" | cut -d"|" -f1)" = "$_k" ] && echo yes && break
        done)
        [ "$_kchk" = "yes" ] && _kknown=1
        if [ -z "$_kknown" ]; then
            echo "SET_FREEZE_FAIL: 未知组键 $_k"
            exit 1
        fi
        case "$_v" in
            true|false) ;;
            *) echo "SET_FREEZE_FAIL: 值须为 true 或 false"; exit 1 ;;
        esac
        freeze_lock || { echo SET_FREEZE_BUSY; exit 1; }
        cfg_set_bool "freeze_$_k" "$_v" || { freeze_unlock; echo "SET_FREEZE_FAIL: 写配置失败"; exit 1; }
        for _fm_member in $(freeze_group_pkgs "$_k"); do freeze_manual_del "$_fm_member"; done
        _requested_group="$_k"; _requested_value="$_v"
        _group_result=0
        for _group_pkg in $(freeze_group_pkgs "$_requested_group"); do
            pkg_exists "$_group_pkg" || continue
            if [ "$_requested_value" = true ] ||
               [ -n "$(freeze_pkg_used_by_other "$_group_pkg" "$_requested_group")" ]; then
                freeze_off_pkg "$_group_pkg" || _group_result=1
            else
                freeze_manual_set "$_group_pkg" false || _group_result=1
                freeze_on_pkg "$_group_pkg" true || _group_result=1
            fi
        done
        freeze_unlock
        if [ "$_group_result" != 0 ]; then echo "SET_FREEZE_PARTIAL: $_requested_group=$_requested_value"; exit 1; fi
        echo "SET_FREEZE_OK: $_requested_group=$_requested_value"
        exit 0
        ;;
    --freeze-add|--freeze-del)
        _action="$1"; _requested_pkg="$2"
        case "$_requested_pkg" in ''|*[!a-zA-Z0-9_.]*) echo FREEZE_FAIL; exit 1;; esac
        _known_pkgs=$(printf '%s\n' "$FREEZE_TABLE" | cut -d'|' -f3 | tr ' ' '\n')
        printf '%s\n' "$_known_pkgs" | grep -qxF "$_requested_pkg" || { echo FREEZE_FAIL; exit 1; }
        freeze_lock || { echo FREEZE_BUSY; exit 1; }
        _action_ok=1
        if [ "$_action" = --freeze-add ]; then
            freeze_manual_set "$_requested_pkg" true &&
                freeze_off_pkg "$_requested_pkg" && pkg_is_disabled "$_requested_pkg" && _action_ok=0
            _action_mark=FREEZE_ADD
        else
            if freeze_manual_set "$_requested_pkg" false; then
                freeze_on_pkg "$_requested_pkg" true && _action_ok=0
            fi
            _action_mark=FREEZE_DEL
        fi
        freeze_unlock
        if [ "$_action_ok" = 0 ]; then echo "${_action_mark}_OK: $_requested_pkg"; else echo "${_action_mark}_FAIL: $_requested_pkg"; fi
        exit "$_action_ok"
        ;;
    --freeze-sync)
        freeze_sync || { echo "FREEZE_SYNC_FAIL"; exit 1; }
        echo "FREEZE_SYNC_DONE"
        exit 0
        ;;
    --freeze-restore)
        freeze_clear_policy_and_restore || { echo "FREEZE_RESTORE_FAIL"; exit 1; }
        echo "FREEZE_RESTORE_DONE"
        exit 0
        ;;
    *)
        run
        ;;
esac