# Soc-Freqcap adapt.c adaptation: runtime-only PSI/thermal/charging/battery cap offsets.
ADAPT_BASE=0 ADAPT_BASE_WARM=0 ADAPT_BASE_MIN=0 ADAPT_PSI_STEPS=0 ADAPT_TH_STEPS=0
ADAPT_LEND_UNTIL=0 ADAPT_BACK_UNTIL=0 ADAPT_COOL_UNTIL=0 ADAPT_DELTA=0 ADAPT_PREV_TOTAL=0 ADAPT_PREV_MONO=0
adapt_tick_ex() {
    [ "$ADAPT_ENABLED" = true ] || return 0
    local advance=${1:-1}
    local now dt stall=-1 total avg line temp=0 charging=0 capacity=-1 d
    now=$(date +%s); case "$now" in ''|*[!0-9]*) return 0;; esac
    dt=${ADAPT_DT:-5}; case "$dt" in ''|*[!0-9]*) dt=5;; esac; [ "$dt" -gt 600 ] && dt=600
    line=$(head -n 1 /proc/pressure/cpu 2>/dev/null)
    total=$(printf '%s\n' "$line" | sed -nE 's/.*total=([0-9]+).*/\1/p')
    avg=$(printf '%s\n' "$line" | sed -nE 's/.*avg10=([0-9.]+).*/\1/p')
    if [ -n "$total" ] && [ -n "$ADAPT_PREV_TOTAL" ] && [ "$ADAPT_PREV_TOTAL" -gt 0 ] && [ "$ADAPT_PREV_MONO" -gt 0 ]; then
        local dw=$((now-ADAPT_PREV_MONO)) diff
        diff=$((total-ADAPT_PREV_TOTAL))
        if [ "$dw" -gt 0 ] && [ "$dw" -le 120 ] && [ "$diff" -ge 0 ]; then stall=$(((diff/1000)/dw)); fi
    fi
    if [ -n "$total" ]; then ADAPT_PREV_TOTAL=$total; ADAPT_PREV_MONO=$now; else ADAPT_PSI_STEPS=0; ADAPT_LEND_UNTIL=0; fi
    if [ "$advance" != 1 ]; then
        ADAPT_PSI_STEPS=0; ADAPT_TH_STEPS=0; ADAPT_LEND_UNTIL=0; ADAPT_BACK_UNTIL=0; ADAPT_COOL_UNTIL=0
        ADAPT_DELTA=0; ADAPT_CHG_ACTIVE=0; ADAPT_CHG_FLOOR=0
        return 0
    fi
    # Highest valid cpu/gpu/soc thermal-zone temperature; ignore trip-point zones.
    local z type v
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "$z/type" ] && [ -r "$z/temp" ] || continue
        type=$(tr '[:upper:]' '[:lower:]' < "$z/type")
        case "$type" in *trip*) continue;; *cpu*|*gpu*|*soc*) ;; *) continue;; esac
        v=$(cat "$z/temp" 2>/dev/null); case "$v" in ''|*[!0-9]*) continue;; esac
        [ "$v" -gt 0 ] && [ "$v" -le 200000 ] && [ "$v" -gt "$temp" ] && temp=$v
    done
    is_charging && charging=1
    capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null); case "$capacity" in ''|*[!0-9]*) capacity=-1;; esac
    local batt=0 max steps budget down
    if [ "$ADAPT_BATT_STEP" = true ] && [ "$charging" = 0 ] && [ "$capacity" -ge 0 ]; then
        [ "$capacity" -lt "$ADAPT_BATT_LOW" ] && batt=$((batt+ADAPT_BATT_LOW_CUT))
        [ "$capacity" -lt "$ADAPT_BATT_CRIT" ] && batt=$((batt+ADAPT_BATT_CRIT_CUT))
    fi
    if [ "$ADAPT_TH_CAP" = true ] && [ "$ADAPT_TH_MAX" -ge "$ADAPT_TH_STEP" ] && [ "$ADAPT_TH_STEP" -gt 0 ]; then
        max=$((ADAPT_TH_MAX/ADAPT_TH_STEP))
        if [ "$temp" -gt 0 ] && [ "$temp" -ge $((ADAPT_TH_HIGH*1000)) ]; then [ "$ADAPT_TH_STEPS" -lt "$max" ] && ADAPT_TH_STEPS=$((ADAPT_TH_STEPS+1)); ADAPT_COOL_UNTIL=0
        elif [ "$temp" -gt 0 ] && [ "$temp" -gt $((ADAPT_TH_LOW*1000)) ]; then ADAPT_COOL_UNTIL=0
        else
            [ "$ADAPT_COOL_UNTIL" -gt 0 ] || ADAPT_COOL_UNTIL=$((now+ADAPT_TH_BACK))
            if [ "$now" -ge "$ADAPT_COOL_UNTIL" ]; then
                if [ "$ADAPT_TH_STEPS" -gt 0 ]; then ADAPT_TH_STEPS=$((ADAPT_TH_STEPS-1)); ADAPT_COOL_UNTIL=$((now+ADAPT_TH_BACK)); else ADAPT_COOL_UNTIL=0; fi
            fi
        fi
    else ADAPT_TH_STEPS=0; fi
    if [ "$ADAPT_PSI_ADAPT" = true ] && [ "$ADAPT_PSI_GAIN" -gt 0 ] && [ "$ADAPT_PSI_STEP" -gt 0 ] && [ "$stall" -ge 0 ]; then
        if [ "$ADAPT_PSI_STEPS" -eq 0 ]; then
            if [ "$ADAPT_BASE" -le 0 ]; then
                [ "$stall" -gt 0 ] && { [ "$ADAPT_BASE_WARM" -eq 0 ] || [ "$stall" -lt "$ADAPT_BASE_MIN" ]; } && ADAPT_BASE_MIN=$stall
                ADAPT_BASE_WARM=$((ADAPT_BASE_WARM+1)); [ "$ADAPT_BASE_WARM" -ge 2 ] && ADAPT_BASE=$ADAPT_BASE_MIN
            else ADAPT_BASE=$(((ADAPT_BASE*(600-dt)+stall*dt+300)/600)); fi
        fi
        if [ "$ADAPT_BASE" -gt 0 ] && { [ "$ADAPT_TH_STEPS" -eq 0 ] || [ "$temp" -le 0 ]; }; then
            budget=$ADAPT_PSI_GAIN; down=$((ADAPT_TH_STEPS*ADAPT_TH_STEP+batt))
            [ "$ADAPT_DOWN_MAX" -gt 0 ] && { local avail=$((ADAPT_DOWN_MAX-down)); [ "$avail" -lt 0 ] && avail=0; [ "$budget" -gt "$avail" ] && budget=$avail; }
            max=$((budget/ADAPT_PSI_STEP))
            if [ "$max" -gt 0 ]; then
                if [ "$stall" -gt $((ADAPT_BASE*2+30)) ]; then [ "$ADAPT_PSI_STEPS" -lt "$max" ] && ADAPT_PSI_STEPS=$((ADAPT_PSI_STEPS+1)); ADAPT_LEND_UNTIL=$((now+ADAPT_PSI_HOLD))
                elif [ "$now" -ge "$ADAPT_LEND_UNTIL" ] && [ "$ADAPT_PSI_STEPS" -gt 0 ] && [ $((now-ADAPT_BACK_UNTIL)) -ge "$ADAPT_PSI_BACK" ]; then ADAPT_BACK_UNTIL=$now; ADAPT_PSI_STEPS=$((ADAPT_PSI_STEPS-1)); fi
            else ADAPT_PSI_STEPS=0; fi
        fi
    elif [ "$ADAPT_PSI_ADAPT" != true ] || [ "$ADAPT_PSI_GAIN" -le 0 ] || [ "$ADAPT_PSI_STEP" -le 0 ]; then ADAPT_PSI_STEPS=0; fi
    d=$((ADAPT_PSI_STEPS*ADAPT_PSI_STEP-ADAPT_TH_STEPS*ADAPT_TH_STEP-batt))
    [ "$d" -gt "$ADAPT_UP_MAX" ] && d=$ADAPT_UP_MAX
[ "$d" -lt $((-ADAPT_DOWN_MAX)) ] && d=$((-ADAPT_DOWN_MAX))

    ADAPT_DELTA=$d
    if [ "$charging" = 1 ] && [ "$ADAPT_CHG_UNCAP" = true ]; then ADAPT_CHG_ACTIVE=1; ADAPT_CHG_FLOOR=$ADAPT_CHG_PCT; else ADAPT_CHG_ACTIVE=0; ADAPT_CHG_FLOOR=0; fi
    # Offsets affect effective percentages only; config values remain untouched.
    for _adapt_var in CPU_PCT_BIG CPU_PCT_MID2 CPU_PCT_MID CPU_PCT_LITTLE GPU_PCT; do
        eval "_adapt_val=\${$_adapt_var:-0}"
        case "$_adapt_val" in ''|*[!0-9]*) continue;; esac
        [ "$_adapt_val" -gt 0 ] || continue
        if [ "$charging" = 1 ] && [ "$ADAPT_CHG_ACTIVE" = 1 ] && [ "$batt" -eq 0 ] && [ "$ADAPT_TH_STEPS" -eq 0 ] && [ "$_adapt_val" -lt "$ADAPT_CHG_FLOOR" ]; then _adapt_val=$ADAPT_CHG_FLOOR; fi
        _adapt_val=$((_adapt_val+d))
        [ "$_adapt_val" -lt 1 ] && _adapt_val=1
        [ "$_adapt_val" -gt 100 ] && _adapt_val=100
        eval "$_adapt_var=\$_adapt_val"
    done
}