all_cpus() { cg_cpu_ids; }
cpu_online() { cg_cpu_is_online "$1"; }
set_cpu() { cg_cpu_set_online "$1" "$2"; }
online_count() {
    n=0
    for c in $(all_cpus); do
        cpu_online "$c" && n=$((n+1))
    done
    echo "$n"
}
restore_core_ctl() {
    if [ -f "$CONFIG_DIR/scene.hotplug.state" ]; then
        if cat "$CONFIG_DIR/scene.hotplug.state" > "$CG_CPU_ROOT/cpuhotplug/enabled" 2>/dev/null; then
            rm -f "$CONFIG_DIR/scene.hotplug.state"
        fi
    fi
    [ -f "$CORE_CTL_BACKUP" ] || return 0
    while IFS="$(printf '\t')" read -r node val; do
        [ -z "$node" ] && continue
        echo "$val" > "$node" 2>/dev/null
    done < "$CORE_CTL_BACKUP"
    rm -f "$CORE_CTL_BACKUP"
}
detect_high() {
    _cap=${AUTO_COUNT:-0}
    case "$_cap" in ''|*[!0-9]*) _cap=0;; esac
    [ "$_cap" -gt 0 ] || return 0
    _maxf=0; _high=""
    for _policy in $(cg_cpu_policies); do
        [ -d "$_policy" ] || continue
        _freq=$(cat "$_policy/cpuinfo_max_freq" 2>/dev/null)
        _members=$(cat "$_policy/related_cpus" 2>/dev/null)
        case "$_freq" in ''|*[!0-9]*) continue;; esac
        [ -n "$_members" ] || continue
        if [ "$_freq" -gt "$_maxf" ]; then
            _maxf=$_freq; _high="$_members"
        elif [ "$_freq" -eq "$_maxf" ]; then
            _high="$_high $_members"
        fi
    done
    if [ -z "$_high" ]; then
        if [ -s "$CONFIG_DIR/high_cores" ]; then
            _high=$(cat "$CONFIG_DIR/high_cores")
        else
            for _cpu in $(all_cpus); do
                _freq=$(cat "$CG_CPU_ROOT/cpu$_cpu/cpufreq/cpuinfo_max_freq" 2>/dev/null)
                case "$_freq" in ''|*[!0-9]*) continue;; esac
                if [ "$_freq" -gt "$_maxf" ]; then
                    _maxf=$_freq; _high="$_cpu"
                elif [ "$_freq" -eq "$_maxf" ]; then
                    _high="$_high $_cpu"
                fi
            done
            [ -n "$_high" ] && printf '%s\n' "$_high" > "$CONFIG_DIR/high_cores"
        fi
    fi
    [ -n "$_high" ] || return 0
    printf '%s\n' $_high | grep -E '^[0-9]+$' | sort -nru | head -n "$_cap" | tr '\n' ' '
}
manual_list() {
    [ -f "$MANUAL_FILE" ] || return 0
    while IFS= read -r _m; do
        _m=$(echo "$_m" | tr -d ' \r\t')
        case "$_m" in
            ''|*[!0-9]*) continue;;
        esac
        [ -d "$CG_CPU_ROOT/cpu$_m" ] || continue
        echo "$_m"
    done < "$MANUAL_FILE"
}
manual_has() {
    [ -f "$MANUAL_FILE" ] || return 1
    for _h in $(manual_list); do [ "$_h" = "$1" ] && return 0; done
    return 1
}
manual_add() {
    [ -d "$CG_CPU_ROOT/cpu$1" ] || return 1
    manual_has "$1" && return 0
    echo "$1" >> "$MANUAL_FILE" 2>/dev/null
    chmod 0644 "$MANUAL_FILE" 2>/dev/null
}
manual_del() {
    [ -f "$MANUAL_FILE" ] || return 0
    _tmp="$MANUAL_FILE.tmp"
    : > "$_tmp" 2>/dev/null
    for _k in $(manual_list); do
        [ "$_k" = "$1" ] && continue
        echo "$_k" >> "$_tmp" 2>/dev/null
    done
    if [ -s "$_tmp" ]; then
        mv -f "$_tmp" "$MANUAL_FILE" 2>/dev/null
    else
        rm -f "$_tmp" "$MANUAL_FILE" 2>/dev/null
    fi
    [ ! -f "$MANUAL_FILE" ] || chmod 0644 "$MANUAL_FILE" 2>/dev/null
}
manual_clear() {
    rm -f "$MANUAL_FILE" "$MANUAL_FILE.tmp" "$CONFIG_DIR/core.selection" 2>/dev/null
}

