
FREEZE_STATE="$CONFIG_DIR/freeze.state"
FREEZE_USER="${FREEZE_USER:-0}"


FREEZE_TABLE='grp_log|运行日志收集|com.oplus.logkit com.oplus.onetrace com.android.traceur
grp_media|影音附加组件|com.coloros.karaoke com.oplus.audio.effectcenter com.oplus.mediaturbo com.oplus.smartmediacontroller
grp_cloud|云端备份同步|com.heytap.cloud com.android.sharedstoragebackup com.android.wallpaperbackup
grp_diag|系统行为诊断|com.oplus.appsense com.oplus.motionsense com.oplus.audiomonitor
grp_ad|广告推送聚合|com.heytap.mcs com.heytap.openid com.heytap.tas
grp_self|作者自冻清单（C16.0.1.306 实测）|com.heytap.colorfulengine com.heytap.openid com.heytap.pictorial com.heytap.speechassist com.heytap.tas com.microsoft.appmanager com.newcall com.oplus.acc.gac com.oplus.aicall com.oplus.aimemory com.oplus.aiwidgets com.oplus.aiwriter com.oplus.apprecover com.oplus.cardigitalkey com.oplus.cast com.oplus.cellularqoe com.oplus.customize.coreapp com.oplus.deepthinker com.oplus.encryption com.oplus.keyguard.clock.base com.oplus.keyguard.clock.gallery com.oplus.keyguard.clock.graffiti com.oplus.keyguard.clock.magazine com.oplus.keyguard.personality.clocks com.oplus.keyguard.style.widgets com.oplus.logkit com.oplus.matrix com.oplus.olc com.oplus.omoji com.oplus.onetrace com.oplus.owork com.oplus.remotecontrol com.oplus.travelengine com.coloros.karaoke com.coloros.ocrscanner com.coloros.remoteguardservice com.coloros.scenemode com.coloros.sceneservice com.coloros.securepay com.coloros.securityguard com.coloros.sharescreen com.coloros.systemclone com.coloros.translate.engine com.coloros.video com.fido.fido2client com.google.android.gms com.google.android.gsf com.google.android.marvin.talkback com.google.android.projection.gearhead com.android.devicelockcontroller com.coloros.codebook com.coloros.colordirectservice
grp_ai|AI 附加功能|com.oplus.aimemory com.oplus.aiunit com.oplus.aiwidgets com.oplus.aiwriter com.oplus.metis com.oplus.obrain
grp_voice|语音助手|com.oplus.ovoicemanager com.oplus.ovoicemanager.wakeup com.heytap.speechassist
grp_games|游戏空间|com.oplus.games com.oplus.cosa
grp_themes|主题与杂志|com.oplus.themestore com.heytap.themestore com.heytap.pictorial
grp_search|桌面搜索与负一屏|com.heytap.quicksearchbox com.coloros.assistantscreen com.coloros.ocs.opencapabilityservice'

freeze_group_pkgs() {
    echo "$FREEZE_TABLE" | while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _k=$(echo "$_line" | cut -d"|" -f1)
        [ "$_k" = "$1" ] || continue
        echo "$_line" | cut -d"|" -f3-
    done
}

freeze_group_on() {
    [ "$(cfg_bool "freeze_$1" false)" = "true" ]
}

# Adapted from starlifezzz/Logd_Disabler_ColorOS16 service.sh.
# Upstream: https://github.com/starlifezzz/Logd_Disabler_ColorOS16
# Reuse authorized by the upstream author, as reported by the CoreGate maintainer.
PMX_INITIALIZED=0
PMX_USE_SU=0
pmx_init() {
    [ "$PMX_INITIALIZED" = 1 ] && return 0
    PMX_INITIALIZED=1
    if command -v su >/dev/null 2>&1 &&
       su -c id 2>/dev/null | grep -q 'uid=0'; then
        PMX_USE_SU=1
    fi
}
pmx() {
    local OLDIFS=$IFS rc
    pmx_init
    IFS=$(printf ' \t\n')
    if [ "$PMX_USE_SU" = "1" ]; then
        su -c "$*" 2>/dev/null
    else
        "$@" 2>/dev/null
    fi
    rc=$?
    IFS=$OLDIFS
    return "$rc"
}

pmx_verbose() {
    local OLDIFS=$IFS rc
    pmx_init
    IFS=$(printf ' \t\n')
    if [ "$PMX_USE_SU" = "1" ]; then
        su -c "$*" 2>&1
    else
        "$@" 2>&1
    fi
    rc=$?
    IFS=$OLDIFS
    return "$rc"
}

freeze_pms_ready() {
    pmx_init
    pmx pm list packages --user "$FREEZE_USER" | grep -q '^package:'
}
freeze_wait_pms() {
    local attempt=0
    while [ "$attempt" -lt 120 ]; do
        freeze_pms_ready && return 0
        attempt=$((attempt + 1))
        sleep 1
    done
    log "冻结：PackageManager 在 120 秒内未就绪，保留策略等待重试"
    return 1
}

pkg_exists() {
    pmx pm list packages --user "$FREEZE_USER" 2>/dev/null | grep -qxF "package:$1"
}

pkg_is_disabled() {
    pmx pm list packages -d --user "$FREEZE_USER" 2>/dev/null | grep -qxF "package:$1"
}

freeze_is_recorded() {
    [ -f "$FREEZE_STATE" ] && awk -F'\t' -v p="$1" '$1==p{found=1}END{exit !found}' "$FREEZE_STATE" 2>/dev/null
}
freeze_orig_state() {
    [ -f "$FREEZE_STATE" ] || return 1
    awk -F'\t' -v p="$1" '$1==p{print $2; exit}' "$FREEZE_STATE" 2>/dev/null
}
freeze_record_add() {
    freeze_is_recorded "$1" && return 0
    printf '%s\t%s\n' "$1" "$2" >> "$FREEZE_STATE" 2>/dev/null
}
freeze_record_del() {
    [ -f "$FREEZE_STATE" ] || return 0
    awk -F'\t' -v p="$1" '$1!=p' "$FREEZE_STATE" > "$FREEZE_STATE.tmp" 2>/dev/null
    mv "$FREEZE_STATE.tmp" "$FREEZE_STATE" 2>/dev/null
}

freeze_record_set_mode() {
    [ -f "$FREEZE_STATE" ] || return 0
    awk -F'\t' -v p="$1" -v m="$2" 'BEGIN{OFS="\t"}
        $1==p { print $1, $2, m; done=1; next }
        { print }
        END { if (!done) print p, "enabled", m }
    ' "$FREEZE_STATE" > "$FREEZE_STATE.tmp" 2>/dev/null && mv "$FREEZE_STATE.tmp" "$FREEZE_STATE" 2>/dev/null
}

kill_pkg_procs() {
    local pkg="$1"
    local i
    am force-stop "$pkg" 2>/dev/null
    for i in 1 2; do
        if pkill -f "$pkg" 2>/dev/null; then
            log "  🔪 已终止残留进程: $pkg (第${i}次)"
            sleep 2
        else
            [ "$i" = "1" ] && log "  📭 无残留进程: $pkg"
            return 0
        fi
    done
    log "  ⚠️ $pkg 持续存活（persistent），已尝试多轮强杀"
}




pkg_live_state() {
    freeze_pms_ready || { echo unavailable; return 1; }
    if ! pkg_exists "$1"; then echo missing
    elif pkg_is_disabled "$1"; then echo disabled
    else echo enabled; fi
}
record_orig() { freeze_record_add "$1" "$2"; }
get_keep() { :; }
orig_state_of() {
    if [ "${FREEZE_EXPLICIT:-false}" = true ]; then echo enabled
    else
        local original
        original=$(freeze_orig_state "$1")
        echo "$original"
    fi
}

disable_pkg() {
    local pkg="$1"
    local keep_key="$2"
    local _live _orig
    _live=$(pkg_live_state "$pkg")
    record_orig "$pkg" "$_live"
    _orig=$(orig_state_of "$pkg")
    if [ "$_orig" != "enabled" ]; then
        log "  ⏭️ 非本模块改动（基线=$_orig），跳过: $pkg"
        return 0
    fi
    if [ -n "$keep_key" ]; then
        local keep_val
        keep_val=$(get_keep "$keep_key")
        if [ -n "$keep_val" ]; then
            local k
            for k in $(echo "$keep_val" | tr ',' ' '); do
                if [ "$k" = "$pkg" ]; then
                    if pmx pm list packages -d --user 0 | grep -qF "package:$pkg"; then
                        log "  🔄 白名单包被禁用，恢复启用: $pkg"
                        result=$(pmx_verbose pm enable "$pkg")
                        log "  $result"
                    else
                        log "  ⏭️ 跳过（WebUI 白名单保留）: $pkg"
                    fi
                    return 0
                fi
            done
        fi
    fi
    if ! pmx pm list packages --user 0 | grep -qF "$pkg"; then
        log "  ⏭️ 跳过（不存在或已禁用/卸载）: $pkg"
        return 0
    fi
    result=$(pmx_verbose pm disable-user --user 0 "$pkg")
    if echo "$result" | grep -qiE "new state: disabled|Success"; then
        log "  ✅ disable-user 成功: $pkg"
        kill_pkg_procs "$pkg"
        return 0
    fi
    log "  ⚠️ disable-user 失败: $pkg ($result)"
    result2=$(pmx_verbose pm disable --user 0 "$pkg" 2>&1)
    if echo "$result2" | grep -qiE "new state: disabled|Success"; then
        log "  ✅ pm disable 成功（persistent 兜底）: $pkg"
        kill_pkg_procs "$pkg"
        sleep 2
        kill_pkg_procs "$pkg"
        return 0
    fi
    log "  ❌ 两种方法均失败: $pkg ($result2)"
    return 1
}

enable_pkg() {
    local pkg="$1"
    local orig
    orig=$(orig_state_of "$pkg")
    if [ -z "$orig" ]; then
        log "  ⏭️ 无本模块改动记录，保持现状不恢复: $pkg"
        return 0
    fi
    if [ "$orig" != "enabled" ]; then
        log "  ⏭️ 基线为 $orig（用户既存/本机无此包），不恢复: $pkg"
        return 0
    fi
    local live
    live=$(pkg_live_state "$pkg")
    case "$live" in
        enabled)
            log "  ✅ 已启用（跳过）: $pkg"
            return 0 ;;
        missing)
            log "  ⏭️ 已被用户卸载，不复活: $pkg"
            return 0 ;;
    esac
    local result
    result=$(pmx_verbose pm enable --user 0 "$pkg")
    if echo "$result" | grep -qiE "new state: enabled|Success"; then
        log "  ✅ enable 成功: $pkg"
        return 0
    fi
    log "  ⚠️ pm enable --user 0 失败: $pkg ($result)"
    local result2
    result2=$(pmx_verbose pm enable "$pkg" 2>&1)
    if echo "$result2" | grep -qiE "new state: enabled|Success"; then
        log "  ✅ pm enable 成功（persistent 恢复）: $pkg"
        return 0
    fi
    log "  ❌ 两种恢复方法均失败: $pkg ($result2)"
    return 1
}

freeze_off_pkg() {
    local _p="$1" FREEZE_EXPLICIT=false _rc
    freeze_pms_ready || return 1
    pkg_exists "$_p" || return 1
    record_orig "$_p" "$(pkg_live_state "$_p")" || return 1
    freeze_record_set_mode "$_p" disable || return 1
    disable_pkg "$_p"; _rc=$?
    [ "$_rc" = 0 ] && pkg_is_disabled "$_p"
}
freeze_on_pkg() {
    local _p="$1" FREEZE_EXPLICIT="${2:-false}"
    freeze_pms_ready || return 1
    if [ "$FREEZE_EXPLICIT" != true ]; then
        freeze_is_recorded "$_p" || return 0
        if [ "$(freeze_orig_state "$_p")" = disabled ]; then
            freeze_record_del "$_p"; return $?
        fi
    fi
    pkg_exists "$_p" || return 1
    enable_pkg "$_p" || return 1
    freeze_pms_ready && pkg_exists "$_p" || return 1
    pkg_is_disabled "$_p" && return 1
    freeze_record_del "$_p"
}

freeze_pkg_used_by_other() {
    _needle="$1"; _self_key="$2"
    echo "$FREEZE_TABLE" | while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _k=$(printf %s "$_line" | cut -d"|" -f1)
        [ "$_k" = "$_self_key" ] && continue
        _pkgs=$(printf %s "$_line" | cut -d"|" -f3-)
        :
        case " $_pkgs " in
            *" $_needle "*) freeze_group_on "$_k" && echo "$_k" ;;
        esac
    done
}

freeze_lock() {
    _fl_wait=0
    while ! mkdir "$CONFIG_DIR/freeze.lock" 2>/dev/null; do
        _fl_owner=$(cat "$CONFIG_DIR/freeze.lock/pid" 2>/dev/null)
        case "$_fl_owner" in
            ''|*[!0-9]*) : ;;
            *) if ! kill -0 "$_fl_owner" 2>/dev/null; then
                   rm -f "$CONFIG_DIR/freeze.lock/pid"
                   rmdir "$CONFIG_DIR/freeze.lock" 2>/dev/null
                   continue
               fi ;;
        esac
        _fl_wait=$((_fl_wait + 1))
        [ "$_fl_wait" -ge 30 ] && return 1
        sleep 1
    done
    echo $$ > "$CONFIG_DIR/freeze.lock/pid"
}
freeze_unlock() {
    [ "$(cat "$CONFIG_DIR/freeze.lock/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -f "$CONFIG_DIR/freeze.lock/pid"
    rmdir "$CONFIG_DIR/freeze.lock" 2>/dev/null
}

FREEZE_MANUAL="$CONFIG_DIR/freeze_manual"
freeze_manual_get() {
    [ -f "$FREEZE_MANUAL" ] || return 0
    awk -F '\t' -v p="$1" '$1==p {print $2; exit}' "$FREEZE_MANUAL"
}
freeze_manual_set() {
    _fm_pkg="$1"; _fm_value="$2"
    { [ ! -f "$FREEZE_MANUAL" ] || awk -F '\t' -v p="$_fm_pkg" '$1!=p' "$FREEZE_MANUAL";
      printf '%s\t%s\n' "$_fm_pkg" "$_fm_value";
    } > "$FREEZE_MANUAL.$$.tmp" && mv "$FREEZE_MANUAL.$$.tmp" "$FREEZE_MANUAL"
}
freeze_manual_del() {
    [ -f "$FREEZE_MANUAL" ] || return 0
    awk -F '\t' -v p="$1" '$1!=p' "$FREEZE_MANUAL" > "$FREEZE_MANUAL.$$.tmp" && mv "$FREEZE_MANUAL.$$.tmp" "$FREEZE_MANUAL"
}

freeze_sync_impl() {
    freeze_pms_ready || return 1
    _fs_packages=$({ printf '%s\n' "$FREEZE_TABLE" | cut -d'|' -f3 | tr ' ' '\n';
        [ ! -f "$FREEZE_STATE" ] || cut -f1 "$FREEZE_STATE";
    } | sort -u)
    _fs_fail=0
    for _fs_pkg in $_fs_packages; do
        if ! pkg_exists "$_fs_pkg"; then
            freeze_is_recorded "$_fs_pkg" && _fs_fail=1
            continue
        fi
        _fs_want=$(freeze_manual_get "$_fs_pkg")
        if [ -z "$_fs_want" ]; then
            _fs_want=false
            [ -n "$(freeze_pkg_used_by_other "$_fs_pkg" '')" ] && _fs_want=true
        fi
        if [ "$_fs_want" = true ]; then
            freeze_off_pkg "$_fs_pkg" || _fs_fail=1
        elif freeze_is_recorded "$_fs_pkg" || [ "$(freeze_manual_get "$_fs_pkg")" = false ]; then
            if [ "$(freeze_manual_get "$_fs_pkg")" = false ]; then
                freeze_on_pkg "$_fs_pkg" true || _fs_fail=1
            else
                freeze_on_pkg "$_fs_pkg" || _fs_fail=1
            fi
        fi
    done
    return "$_fs_fail"
}

freeze_sync() {
    freeze_lock || return 1
    freeze_sync_impl
    _fs_result=$?
    freeze_unlock
    return "$_fs_result"
}

freeze_restore_all_impl() {
    local _restore_fail=0
    if [ -f "$FREEZE_STATE" ]; then
        _restore_pkgs=$(cut -f1 "$FREEZE_STATE")
        for _restore_pkg in $_restore_pkgs; do
            freeze_on_pkg "$_restore_pkg" || _restore_fail=1
        done
    fi
    return "$_restore_fail"
}
freeze_restore_all() {
    freeze_lock || return 1
    freeze_restore_all_impl
    local _restore_rc=$?
    freeze_unlock
    return "$_restore_rc"
}
freeze_clear_policy_and_restore() {
    freeze_lock || return 1
    local _clear_key _clear_rc=0
    for _clear_key in $(printf '%s\n' "$FREEZE_TABLE" | cut -d'|' -f1); do
        cfg_set_bool "freeze_$_clear_key" false || _clear_rc=1
    done
    if [ "$_clear_rc" = 0 ]; then
        rm -f "$FREEZE_MANUAL" || _clear_rc=1
    fi
    if [ "$_clear_rc" = 0 ]; then
        freeze_restore_all_impl || _clear_rc=1
    fi
    freeze_unlock
    return "$_clear_rc"
}

freeze_status_report() {
    pmx pm list packages -d --user "$FREEZE_USER" 2>/dev/null | sed 's/^package://' | sed 's/$/\tdisabled/'
    pmx dumpsys package --all-components packages 2>/dev/null | awk -v u="User $FREEZE_USER:" '
        /^[[:space:]]*Package \[/ {
            pkg = $0
            sub(/^[[:space:]]*Package \[/, "", pkg)
            sub(/\].*$/, "", pkg)
            next
        }
        {
            if (pkg != "" && index($0, "suspended=true") > 0) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                if (index(line, u) == 1) {
                    print pkg "\tsuspended"
                    pkg = ""
                }
            }
        }
    '
}


