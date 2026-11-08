#!/system/bin/sh
CG_CPU_ROOT=${CG_CPU_ROOT:-/sys/devices/system/cpu}
CG_CPUFREQ_ROOT=${CG_CPUFREQ_ROOT:-$CG_CPU_ROOT/cpufreq}

cg_positive() {
    case "$1" in ''|*[!0-9]*) return 1;; esac
    [ "$1" -gt 0 ] 2>/dev/null
}
cg_cpu_policies() {
    local d
    for d in "$CG_CPUFREQ_ROOT"/policy*; do
        [ -d "$d" ] && [ -f "$d/scaling_max_freq" ] && printf '%s\n' "$d"
    done
}
cg_cpu_frequencies() {
    local d="$1"
    if [ -s "$d/scaling_available_frequencies" ]; then
        tr ' \t' '\n\n' < "$d/scaling_available_frequencies"
    elif [ -s "$d/stats/time_in_state" ]; then
        awk '{print $1}' "$d/stats/time_in_state"
    fi | awk '/^[0-9]+$/ && $1 > 0 {print $1}' | sort -nu
}
cg_cpu_max() {
    local v
    v=$(cg_cpu_frequencies "$1" | tail -n 1)
    if ! cg_positive "$v"; then v=$(cat "$1/cpuinfo_max_freq" 2>/dev/null); fi
    cg_positive "$v" && printf '%s\n' "$v"
}
cg_cpu_target() {
    local d="$1" mhz="$2" floor minimum
    cg_positive "$mhz" || return 1
    [ "$mhz" -le 10000 ] 2>/dev/null || return 1
    floor=$(cg_cpu_frequencies "$d" | awk -v target="$((mhz * 1000))" '$1<=target {v=$1} END {if(v) print v}')
    if [ -z "$floor" ]; then floor=$(cg_cpu_frequencies "$d" | head -n 1); fi
    cg_positive "$floor" || return 1
    minimum=$(cat "$d/scaling_min_freq" 2>/dev/null)
    if cg_positive "$minimum" && [ "$floor" -lt "$minimum" ]; then
        floor=$(cg_cpu_frequencies "$d" | awk -v low="$minimum" '$1>=low {print; exit}')
    fi
    cg_positive "$floor" && printf '%s\n' "$floor"
}
cg_cpu_snapshot_value() {
    [ -f "$FREQ_SNAP_FILE" ] || return 0
    awk -F= -v node="$1" '$1==node {v=$2} END {print v}' "$FREQ_SNAP_FILE"
}
cg_cpu_save_one() {
    local d="$1" old saved
    saved=$(cg_cpu_snapshot_value "$d")
    [ -n "$saved" ] && { cg_positive "$saved"; return $?; }
    old=$(cat "$d/scaling_max_freq" 2>/dev/null)
    cg_positive "$old" || return 1
    if [ -f "$FREQ_SNAP_FILE" ]; then
        cat "$FREQ_SNAP_FILE" > "$FREQ_SNAP_FILE.$$.tmp" || return 1
    else
        : > "$FREQ_SNAP_FILE.$$.tmp" || return 1
    fi
    printf '%s=%s\n' "$d" "$old" >> "$FREQ_SNAP_FILE.$$.tmp" &&
        mv -f "$FREQ_SNAP_FILE.$$.tmp" "$FREQ_SNAP_FILE"
}
cg_cpu_apply_caps() {
    local d max target current count=0 failed=0 tier pct mhz rank m low high
    local max_list
    max_list=$(for d in $(cg_cpu_policies); do cg_cpu_max "$d"; done | sort -nu)
    m=$(printf '%s\n' "$max_list" | awk 'NF {n++} END {print n+0}')
    low=$(printf '%s\n' "$max_list" | head -n 1)
    high=$(printf '%s\n' "$max_list" | tail -n 1)
    for d in $(cg_cpu_policies); do
        max=$(cg_cpu_max "$d")
        cg_positive "$max" || { failed=1; continue; }
        tier=BIG
        if [ "$max" = "$low" ] && [ "$m" -ge 2 ]; then tier=LITTLE
        elif [ "$max" = "$high" ]; then tier=BIG
        else
            rank=$(printf '%s\n' "$max_list" | awk -v v="$max" '$1==v {print NR}')
            if [ "$m" -ge 4 ] && [ "$rank" -eq $((m - 2)) ]; then tier=MID2
            elif [ "$m" -ge 3 ] && [ "$rank" -eq $((m - 1)) ]; then tier=MID
            fi
        fi
        case "$tier" in
            BIG) pct=${CPU_PCT_BIG:-0}; legacy_mhz=${CAP_BIG_MHZ:-0};;
            MID2) pct=${CPU_PCT_MID2:-0}; legacy_mhz=${CAP_BIG_MHZ:-0};;
            MID) pct=${CPU_PCT_MID:-0}; legacy_mhz=${CAP_BIG_MHZ:-0};;
            LITTLE) pct=${CPU_PCT_LITTLE:-0}; legacy_mhz=${CAP_LITTLE_MHZ:-0};;
        esac
        case "$pct" in ''|*[!0-9]*) pct=0;; esac
        if [ "$pct" -gt 0 ] && [ "$pct" -le 100 ]; then
            mhz=$((max * pct / 100 / 1000))
        elif cg_positive "$legacy_mhz" && [ "$legacy_mhz" -le 10000 ]; then
            mhz=$legacy_mhz
        else
            continue
        fi
        target=$(cg_cpu_target "$d" "$mhz") || { failed=1; continue; }
        cg_cpu_save_one "$d" || { failed=1; continue; }
        current=$(cat "$d/scaling_max_freq" 2>/dev/null)
        if [ "$current" != "$target" ]; then
            printf '%s\n' "$target" > "$d/scaling_max_freq" 2>/dev/null || { failed=1; continue; }
        fi
        [ "$(cat "$d/scaling_max_freq" 2>/dev/null)" = "$target" ] || { failed=1; continue; }
        count=$((count + 1))
    done
    CG_CPU_APPLIED=$count
    [ "$count" -gt 0 ] && [ "$failed" = 0 ]
}
cg_cpu_restore_caps() {
    local d saved failed=0
    [ -f "$FREQ_SNAP_FILE" ] || return 0
    for d in $(cg_cpu_policies); do
        saved=$(cg_cpu_snapshot_value "$d")
        [ -n "$saved" ] || continue
        cg_positive "$saved" || { failed=1; continue; }
        if [ "$(cat "$d/scaling_max_freq" 2>/dev/null)" != "$saved" ]; then
            printf '%s\n' "$saved" > "$d/scaling_max_freq" 2>/dev/null || { failed=1; continue; }
        fi
        [ "$(cat "$d/scaling_max_freq" 2>/dev/null)" = "$saved" ] || failed=1
    done
    local recorded present
    recorded=$(awk 'END {print NR+0}' "$FREQ_SNAP_FILE")
    present=0
    for d in $(cg_cpu_policies); do
        [ -z "$(cg_cpu_snapshot_value "$d")" ] || present=$((present + 1))
    done
    [ "$recorded" = "$present" ] || failed=1
    if [ "$failed" = 0 ]; then
        rm -f "$FREQ_SNAP_FILE"
    fi
    [ "$failed" = 0 ]
}
cg_cpu_report() {
    local d max freqs control
    printf '[cpu]\n'
    for d in $(cg_cpu_policies); do
        max=$(cg_cpu_max "$d")
        freqs=$(cg_cpu_frequencies "$d" | tr '\n' ' ')
        control=unsupported
        [ -n "$freqs" ] && [ -w "$d/scaling_max_freq" ] && control=available
        printf '%s\t%s\t%s\t%s\n' "${d##*/}" "$control" "$max" "$freqs"
    done
}
CG_KGSL_ROOT=${CG_KGSL_ROOT:-/sys/class/kgsl/kgsl-3d0}
CG_DEVFREQ_ROOT=${CG_DEVFREQ_ROOT:-/sys/class/devfreq}
CG_THERMAL_ROOT=${CG_THERMAL_ROOT:-/sys/class/thermal}
CG_POWER_ROOT=${CG_POWER_ROOT:-/sys/class/power_supply}
cg_gpu_dirs() {
    local d identity
    [ ! -d "$CG_KGSL_ROOT" ] || printf '%s\n' "$CG_KGSL_ROOT"
    for d in "$CG_DEVFREQ_ROOT"/*; do
        [ -d "$d" ] || continue
        identity="$(readlink -f "$d" 2>/dev/null) $(cat "$d/name" 2>/dev/null)"
        case "$identity" in *kgsl*) continue;; esac
        case "$identity" in *gpu*|*GPU*|*mali*|*Mali*|*3d0*)
            [ ! -e "$d/max_freq" ] || printf '%s\n' "$d";;
        esac
    done
}
cg_gpu_frequencies() {
    local d="$1" file
    if [ "$d" = "$CG_KGSL_ROOT" ]; then
        file="$d/gpu_available_frequencies"
        [ -r "$file" ] || file="$d/devfreq/available_frequencies"
    else file="$d/available_frequencies"; fi
    cat "$file" 2>/dev/null | tr ' \t' '\n\n' |
        awk '/^[0-9]+$/ && $1>0 {print $1}' | sort -nu
}
cg_gpu_nodes() {
    local d="$1" node
    if [ "$d" = "$CG_KGSL_ROOT" ]; then
        for node in "$d/max_gpuclk" "$d/devfreq/max_freq" "$d/max_pwrlevel"; do
            [ ! -e "$node" ] || printf '%s\n' "$node"
        done
    else [ ! -e "$d/max_freq" ] || printf '%s\n' "$d/max_freq"; fi
}
cg_gpu_target() {
    local d="$1" mhz="$2" top scale target
    cg_positive "$mhz" && [ "$mhz" -le 10000 ] || return 1
    top=$(cg_gpu_frequencies "$d" | tail -n 1)
    cg_positive "$top" || return 1
    if [ "$d" = "$CG_KGSL_ROOT" ] || [ "$top" -gt 10000000 ]; then scale=1000000
    elif [ "$top" -ge 10000 ]; then scale=1000
    else return 1; fi
    target=$(cg_gpu_frequencies "$d" | awk -v t="$((mhz * scale))" '$1<=t {v=$1} END {if(v)print v}')
    [ -n "$target" ] || target=$(cg_gpu_frequencies "$d" | head -n 1)
    local minimum minnode="$d/min_freq"
    [ "$d" != "$CG_KGSL_ROOT" ] || minnode="$d/devfreq/min_freq"
    minimum=$(cat "$minnode" 2>/dev/null)
    if cg_positive "$minimum" && [ "$target" -lt "$minimum" ]; then
        target=$(cg_gpu_frequencies "$d" | awk -v low="$minimum" '$1>=low {print;exit}')
    fi
    cg_positive "$target" && printf '%s\n' "$target"
}
cg_gpu_saved() {
    [ -f "$GPU_SNAP_FILE" ] || return 0
    awk -F '\t' -v n="$1" '$1==n {print $2; exit}' "$GPU_SNAP_FILE"
}
cg_gpu_save() {
    local node="$1" old mode tmp="$GPU_SNAP_FILE.$$.tmp"
    [ -z "$(cg_gpu_saved "$node")" ] || return 0
    old=$(cat "$node" 2>/dev/null)
    case "$old" in ''|*[!0-9]*) return 1;; esac
    mode=$(stat -c '%a' "$node" 2>/dev/null)
    case "$mode" in ''|*[!0-7]*) return 1;; esac
    if [ -f "$GPU_SNAP_FILE" ]; then cat "$GPU_SNAP_FILE" > "$tmp" || return 1
    else : > "$tmp" || return 1; fi
    printf '%s\t%s\t%s\n' "$node" "$old" "$mode" >> "$tmp" && mv -f "$tmp" "$GPU_SNAP_FILE"
}
cg_gpu_write() {
    local node="$1" value="$2" mode actual
    cg_gpu_save "$node" || return 1
    mode=$(stat -c '%a' "$node" 2>/dev/null)
    if [ "$(cat "$node" 2>/dev/null)" != "$value" ]; then
        chmod u+w "$node" 2>/dev/null || return 1
        printf '%s\n' "$value" > "$node" 2>/dev/null
        if [ "${node#"$CG_KGSL_ROOT"/}" != "$node" ]; then
            printf '%s\n' "$value" > "$node" 2>/dev/null
            printf '%s\n' "$value" > "$node" 2>/dev/null
            printf '%s\n' "$value" > "$node" 2>/dev/null
        fi
    fi
    actual=$(cat "$node" 2>/dev/null)
    if [ "$actual" != "$value" ] && [ "${node#"$CG_KGSL_ROOT"/}" != "$node" ]; then
        case "$node" in */max_gpuclk|*/max_freq)
            printf '%s\n' "$((value + 800000))" > "$node" 2>/dev/null
            actual=$(cat "$node" 2>/dev/null);;
        esac
    fi
    if [ "${node#"$CG_KGSL_ROOT"/}" != "$node" ]; then
        chmod 444 "$node" 2>/dev/null
    else chmod "$mode" "$node" 2>/dev/null; fi
    [ "$actual" = "$value" ]
}
cg_gpu_apply_caps() {
    local d node target num count=0 failed=0 pct top mhz
    pct=${GPU_PCT:-0}
    case "$pct" in ''|*[!0-9]*) pct=0;; esac
    if [ "$pct" -gt 0 ] && [ "$pct" -le 100 ]; then
        for d in $(cg_gpu_dirs); do
            top=$(cg_gpu_frequencies "$d" | tail -n 1)
            case "$top" in ''|*[!0-9]*) failed=1; continue;; esac
            case "$d" in "$CG_KGSL_ROOT") mhz=$((top * pct / 100 / 1000000));; *)
                if [ "$top" -gt 10000000 ]; then mhz=$((top * pct / 100 / 1000000))
                elif [ "$top" -ge 10000 ]; then mhz=$((top * pct / 100 / 1000))
                else failed=1; continue; fi;;
            esac
            target=$(cg_gpu_target "$d" "$mhz") || { failed=1; continue; }
            for node in $(cg_gpu_nodes "$d"); do
                case "$node" in */max_pwrlevel) :;; *) cg_gpu_write "$node" "$target" && count=$((count+1)) || failed=1;; esac
            done
        done
    fi
    for d in $(cg_gpu_dirs); do
        target=
        if [ "${CAP_GPU_MHZ:-0}" -gt 0 ]; then
            target=$(cg_gpu_target "$d" "$CAP_GPU_MHZ") || { failed=1; continue; }
        elif [ "${GPU_PCT:-0}" -le 0 ] && [ "${CAP_GPU_PWRLEVEL:--1}" -lt 0 ]; then
            continue
        fi
        for node in $(cg_gpu_nodes "$d"); do
            case "$node" in */max_pwrlevel)
                num=$(cat "$d/num_pwrlevels" 2>/dev/null)
                case "$CAP_GPU_PWRLEVEL" in ''|*[!0-9]*) continue;; esac
                cg_positive "$num" && [ "$CAP_GPU_PWRLEVEL" -lt "$num" ] || continue
                cg_gpu_write "$node" "$CAP_GPU_PWRLEVEL" && count=$((count+1)) || failed=1;;
            *)
                if [ -n "$target" ]; then
                    cg_gpu_write "$node" "$target" && count=$((count+1)) || failed=1
                fi;;
            esac
        done
    done
    CG_GPU_APPLIED=$count
    [ "$count" -gt 0 ] && [ "$failed" = 0 ]
}
cg_gpu_restore_caps() {
    local d node value mode failed=0 count=0 records
    [ -f "$GPU_SNAP_FILE" ] || return 0
    for d in $(cg_gpu_dirs); do
        for node in $(cg_gpu_nodes "$d"); do
            value=$(cg_gpu_saved "$node")
            [ -n "$value" ] || continue
            mode=$(awk -F '\t' -v n="$node" '$1==n {print $3; exit}' "$GPU_SNAP_FILE")
            case "$mode" in ''|*[!0-7]*) failed=1; continue;; esac
            chmod u+w "$node" 2>/dev/null || { failed=1; continue; }
            if [ "$(cat "$node" 2>/dev/null)" != "$value" ]; then
                printf '%s\n' "$value" > "$node" 2>/dev/null || failed=1
            fi
            [ "$(cat "$node" 2>/dev/null)" = "$value" ] || failed=1
            chmod "$mode" "$node" 2>/dev/null || failed=1
            count=$((count+1))
        done
    done
    records=$(awk 'END {print NR+0}' "$GPU_SNAP_FILE")
    [ "$records" = "$count" ] || failed=1
    [ "$failed" != 0 ] || rm -f "$GPU_SNAP_FILE"
    [ "$failed" = 0 ]
}
cg_temperature() {
    local d type v
    for d in "$CG_POWER_ROOT/battery" "$CG_POWER_ROOT"/*; do
        [ -d "$d" ] || continue
        type=$(cat "$d/type" 2>/dev/null)
        [ "${d##*/}" = battery ] || [ "$type" = Battery ] || continue
        v=$(cat "$d/temp" 2>/dev/null)
        if printf '%s\n' "$v" | awk '/^-?[0-9]+$/ && $1>=-200 && $1<=1000 {ok=1} END {exit !ok}'; then
            printf '%s\t%s\n' "$((v * 100))" "battery:${d##*/}"; return 0
        fi
    done
    for d in "$CG_THERMAL_ROOT"/thermal_zone*; do
        type=$(cat "$d/type" 2>/dev/null)
        case "$type" in battery|battery-therm|battery_therm|batt_therm)
            v=$(cat "$d/temp" 2>/dev/null)
            if printf '%s\n' "$v" | awk '/^-?[0-9]+$/ && $1>=-20000 && $1<=100000 {ok=1} END {exit !ok}'; then
                printf '%s\t%s\n' "$v" "battery:$type"; return 0
            fi;;
        esac
    done
    v=$(dumpsys battery 2>/dev/null | awk '/^[[:space:]]*temperature:/ && $2 ~ /^-?[0-9]+$/ && $2>=-200 && $2<=1000 {printf "%.0f\n",$2*100;exit}')
    [ -z "$v" ] || { printf '%s\tbattery:dumpsys\n' "$v"; return 0; }
    return 1
}
cg_hardware_report() {
    local d f node state sample
    printf '[core]\n'
    for node in "$CG_CPU_ROOT"/cpu[0-9]*/online; do
        [ -e "$node" ] || continue
        state=read_only; [ ! -w "$node" ] || state=available
        printf '%s\t%s\t%s\n' "$node" "$state" "$(cat "$node" 2>/dev/null)"
    done
    cg_cpu_report
    printf '[gpu]\n'
    state=unsupported
    for d in $(cg_gpu_dirs); do
        f=$(cg_gpu_frequencies "$d" | tr '\n' ' ')
        state=unsupported; [ -z "$f" ] || state=detected
        printf '%s\t%s\t%s\n' "$d" "$state" "$f"
    done
    [ "$state" != unsupported ] || printf 'support\tunsupported_or_missing_frequency_table\n'
    printf '[temperature]\n'
    sample=$(cg_temperature) && printf '%s\n' "$sample" || printf 'unavailable\n'
}
# CPU write sequence ported from helloklf/vtools CpuFrequencyUtils.java,
# setCoreOnlineState(), commit d735955f723329896386ed03e0608ce1bc2082a5.
# See SCENE-UPSTREAM.txt and SCENE-LICENSE.txt.
cg_cpu_ids() {
    local d id
    for d in "$CG_CPU_ROOT"/cpu[0-9]*; do
        [ -d "$d" ] || continue
        id=${d##*/cpu}
        case "$id" in ''|*[!0-9]*) continue;; esac
        printf '%s\n' "$id"
    done | sort -nu
}
cg_cpu_is_online() {
    local id="$1" node="$CG_CPU_ROOT/cpu$1/online"
    case "$id" in ''|*[!0-9]*) return 1;; esac
    [ -d "$CG_CPU_ROOT/cpu$id" ] || return 1
    if [ -r "$node" ]; then [ "$(cat "$node" 2>/dev/null)" = 1 ]; return $?; fi
    awk -v id="$id" 'BEGIN {RS=","} {
        gsub(/[[:space:]]/, ""); n=split($0,a,"-");
        if ((n==1 && a[1]==id) || (n==2 && id>=a[1] && id<=a[2])) found=1
    } END {exit !found}' "$CG_CPU_ROOT/online" 2>/dev/null
}
cg_cpu_set_online() {
    local id="$1" value="$2" node="$CG_CPU_ROOT/cpu$1/online" other found=0
    case "$id" in ''|*[!0-9]*) return 1;; esac
    case "$value" in 0|1) :;; *) return 1;; esac
    [ -d "$CG_CPU_ROOT/cpu$id" ] || return 1
    if cg_cpu_is_online "$id"; then
        [ "$value" != 1 ] || return 0
        for other in $(cg_cpu_ids); do
            [ "$other" = "$id" ] && continue
            if cg_cpu_is_online "$other"; then found=1; break; fi
        done
        [ "$found" = 1 ] || return 1
    else [ "$value" != 0 ] || return 0; fi
    [ -e "$node" ] || return 1
    local hotplug="$CG_CPU_ROOT/cpuhotplug/enabled" current
    if [ -e "$hotplug" ]; then
        current=$(cat "$hotplug" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$current" in 1|true|enabled)
            if [ ! -f "$CONFIG_DIR/scene.hotplug.state" ]; then
                printf '%s\n' "$current" > "$CONFIG_DIR/scene.hotplug.state" || return 1
            fi
            echo 0 > "$hotplug" || return 1;;
        esac
    fi
    chmod 0755 "$node" || return 1
    printf '%s\n' "$value" > "$node" 2>/dev/null || return 1
    if [ "$value" = 1 ]; then cg_cpu_is_online "$id"
    else ! cg_cpu_is_online "$id"; fi
}