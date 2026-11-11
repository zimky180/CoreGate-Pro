
LOCK_STATE=""
CORE_REQUEST_FILE="$CONFIG_DIR/core.request"
core_guard_enter() {
    local _tries=0 _owner
    while ! mkdir "$CONFIG_DIR/core.lock" 2>/dev/null; do
        _owner=$(cat "$CONFIG_DIR/core.lock/pid" 2>/dev/null)
        if [ -n "$_owner" ] && ! kill -0 "$_owner" 2>/dev/null; then
            rm -f "$CONFIG_DIR/core.lock/pid"
            rmdir "$CONFIG_DIR/core.lock" 2>/dev/null
        fi
        _tries=$((_tries+1))
        [ "$_tries" -ge 15 ] && return 1
        sleep 1
    done
    echo $$ > "$CONFIG_DIR/core.lock/pid"
}
core_guard_leave() {
    rm -f "$CONFIG_DIR/core.lock/pid"
    rmdir "$CONFIG_DIR/core.lock" 2>/dev/null
}
core_restore_except() {
    local c failed=0
    for c in $(all_cpus); do
        case " $1 " in *" $c "*) continue;; esac
        set_cpu "$c" 1 || failed=1
    done
    return "$failed"
}
core_normalize() {
    local c
    for c in $1; do
        case "$c" in ''|*[!0-9]*) continue;; esac
        [ ! -d "$CG_CPU_ROOT/cpu$c" ] || printf '%s\n' "$c"
    done | sort -nu | xargs
}
do_lock() {
    local c desired manual request old failed=0
    LOCK_STATE=""
    core_guard_enter || return 1
    manual=$(manual_list | xargs)
    if [ -f "$CONFIG_DIR/core.selection" ] || { [ -n "$manual" ] && [ "$(cfg_val lock_cores auto)" = auto ]; }; then desired="$manual"
    else desired="$LOCK_LIST $manual"; fi
    [ "${GAME_LOCK_ACTIVE:-0}" = 1 ] && desired="$GAME_LOCK_LIST"
    desired=$(core_normalize "$desired $THERMAL_EXTRA_ACTIVE")
    request="locked:$desired"
    old=$(cat "$CORE_REQUEST_FILE" 2>/dev/null)
    if [ "$old" != "$request" ]; then
        case "$old" in locked:*)
            for c in ${old#locked:}; do
                case " $desired " in *" $c "*) continue;; esac
                set_cpu "$c" 1 || failed=1
            done;;
        esac
        if [ "$failed" = 0 ]; then
            printf '%s\n' "$request" > "$CORE_REQUEST_FILE" || failed=1
        fi
    fi
    for c in $desired; do
        if cpu_online "$c"; then set_cpu "$c" 0 || failed=1; fi
    done
    for c in $desired; do
        if cpu_online "$c"; then LOCK_STATE="${LOCK_STATE}${c}:fail "; failed=1
        else LOCK_STATE="${LOCK_STATE}${c}:ok "; fi
    done
    core_guard_leave
    return "$failed"
}
do_unlock() {
    local c failed=0
    UNLOCK_FAILED=""
    core_guard_enter || { UNLOCK_FAILED=busy; return 1; }
    # 锁核期间热插拔被关掉过，解锁时必须先无条件恢复，
    # 否则内核不会把大核重新拉回，表现为“已解锁但大核不参与”。
    # 恢复失败不影响解锁判定，避免 core_ctl 备份残留把解锁永久卡死。
    restore_core_ctl || true
    for c in $(all_cpus); do
        if ! cpu_online "$c"; then
            set_cpu "$c" 1 || failed=1
        fi
    done
    for c in $(all_cpus); do
        if ! cpu_online "$c"; then UNLOCK_FAILED="$UNLOCK_FAILED $c"; failed=1; fi
    done
    if [ "$failed" = 0 ]; then
        printf 'unlocked\n' > "$CORE_REQUEST_FILE" || { UNLOCK_FAILED=journal; failed=1; }
    fi
    core_guard_leave
    return "$failed"
}