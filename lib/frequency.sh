FREQ_CAPPED=0
FREQ_SNAP_FILE="$CONFIG_DIR/freq_snapshot"
GPU_SNAP_FILE="$CONFIG_DIR/gpu_snapshot"
freq_cap_load_config() {
    CAP_LITTLE_MHZ=0
    CAP_BIG_MHZ=0
    CAP_GPU_MHZ=0
    CAP_GPU_PWRLEVEL=-1
    CPU_PCT_BIG=0 CPU_PCT_MID2=0 CPU_PCT_MID=0 CPU_PCT_LITTLE=0 GPU_PCT=0
    ADAPT_ENABLED=false ADAPT_PSI_ADAPT=true ADAPT_PSI_GAIN=10 ADAPT_PSI_STEP=5 ADAPT_PSI_HOLD=30 ADAPT_PSI_BACK=15
    ADAPT_TH_CAP=true ADAPT_TH_HIGH=75 ADAPT_TH_LOW=68 ADAPT_TH_STEP=5 ADAPT_TH_MAX=25 ADAPT_TH_BACK=20
    ADAPT_CHG_UNCAP=true ADAPT_CHG_PCT=100 ADAPT_UP_MAX=15 ADAPT_DOWN_MAX=30
    ADAPT_BATT_STEP=false ADAPT_BATT_LOW=20 ADAPT_BATT_LOW_CUT=5 ADAPT_BATT_CRIT=10 ADAPT_BATT_CRIT_CUT=10
    local key value
    CPU_PCT_BIG=$(cfg_int cpu_pct_big 0)
    CPU_PCT_MID2=$(cfg_int cpu_pct_mid2 0)
    CPU_PCT_MID=$(cfg_int cpu_pct_mid 0)
    CPU_PCT_LITTLE=$(cfg_int cpu_pct_little 0)
    GPU_PCT=$(cfg_int gpu_pct 0)
    ADAPT_ENABLED=$(cfg_bool adapt_enabled false)
    # Adaptive configuration is loaded from the Soc-Freqcap parameter set below.

    ADAPT_PSI_ADAPT=$(cfg_bool psi_adapt true)
    ADAPT_PSI_GAIN=$(cfg_int psi_gain 10)
    ADAPT_PSI_STEP=$(cfg_int psi_step 5)
    ADAPT_PSI_HOLD=$(cfg_int psi_hold 30)
    ADAPT_PSI_BACK=$(cfg_int psi_back 15)
    ADAPT_TH_CAP=$(cfg_bool th_cap true)
    ADAPT_TH_HIGH=$(cfg_int th_high 75)
    ADAPT_TH_LOW=$(cfg_int th_low 68)
    ADAPT_TH_STEP=$(cfg_int th_step 5)
    ADAPT_TH_MAX=$(cfg_int th_max 25)
    ADAPT_TH_BACK=$(cfg_int th_back 20)
    ADAPT_CHG_UNCAP=$(cfg_bool chg_uncap true)
    ADAPT_CHG_PCT=$(cfg_int chg_pct 100)
    ADAPT_UP_MAX=$(cfg_int adapt_up_max 15)
    ADAPT_DOWN_MAX=$(cfg_int adapt_down_max 30)
    ADAPT_BATT_STEP=$(cfg_bool batt_step false)
    ADAPT_BATT_LOW=$(cfg_int batt_low 20)
    ADAPT_BATT_LOW_CUT=$(cfg_int batt_low_cut 5)
    ADAPT_BATT_CRIT=$(cfg_int batt_crit 10)
    ADAPT_BATT_CRIT_CUT=$(cfg_int batt_crit_cut 10)

    for key in little big gpu; do
        value=$(cfg_int "cap_${key}_mhz" -1)
        if cg_positive "$value" && [ "$value" -le 10000 ]; then
            case "$key" in little) CAP_LITTLE_MHZ=$value;; big) CAP_BIG_MHZ=$value;; gpu) CAP_GPU_MHZ=$value;; esac
        fi
    done
    value=$(cfg_int cap_gpu_pwrlevel -1)
    case "$value" in ''|*[!0-9]*) :;; *) CAP_GPU_PWRLEVEL=$value;; esac
}
apply_freq_cap() {
    [ "$LIMIT_FREQ" = true ] || return 0
    freq_cap_load_config
    ADAPT_DT=${INTERVAL:-5}
    case "${GAME_ACTIVE:-0}" in 1) adapt_tick_ex 0;; *) adapt_tick_ex 1;; esac
    local cpu_ok=0 gpu_ok=0
    cg_cpu_apply_caps && cpu_ok=1
    cg_gpu_apply_caps && gpu_ok=1
    if [ "$FREQ_CAPPED" != "$cpu_ok:$gpu_ok" ]; then
        log "限频回读：CPU=${CG_CPU_APPLIED:-0}簇 GPU=${CG_GPU_APPLIED:-0}节点 完整成功=$cpu_ok:$gpu_ok（0表示缺少能力或部分失败）"
    fi
    FREQ_CAPPED="$cpu_ok:$gpu_ok"
    [ "$cpu_ok" = 1 ] || [ "$gpu_ok" = 1 ]
}
remove_freq_cap() {
    local failed=0
    cg_cpu_restore_caps || failed=1
    cg_gpu_restore_caps || failed=1
    if [ "$failed" = 0 ]; then FREQ_CAPPED=0; else FREQ_CAPPED=restore_failed; fi
    [ "$failed" = 0 ]
}


restore_performance() {
    do_unlock
    if remove_freq_cap; then
        FREQ_RESTORE_FAILED=0
    else
        [ "${FREQ_RESTORE_FAILED:-0}" = 1 ] || log "限频恢复未完成：保留失败状态，下轮重试"
        FREQ_RESTORE_FAILED=1
    fi
    # 游戏/录屏结束是解锁的唯一出口，这里再兜一次热插拔与 core_ctl，
    # 防止 do_unlock 因 already-online 提前 return 而跳过恢复。
    restore_core_ctl || log "热插拔/core_ctl 恢复未完成，下轮重试"
    local c offline=""
    for c in $(all_cpus); do
        if ! cpu_online "$c"; then offline="$offline $c"; fi
    done
    if [ -n "$offline" ]; then UNLOCK_FAILED=" $offline"; else UNLOCK_FAILED=""; fi
    if [ -z "$UNLOCK_FAILED" ] && [ "$FREQ_RESTORE_FAILED" = 0 ]; then
        state=unlocked
    else
        state=unlock_partial
    fi
}