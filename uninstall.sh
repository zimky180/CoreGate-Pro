#!/system/bin/sh
MODDIR=${0%/*}
CONFIG_DIR="/data/adb/CoreGate"
PID_FILE="$CONFIG_DIR/daemon.pid"
CORE_CTL_BACKUP="$CONFIG_DIR/corectl.state"

ui_print "- 停止模块服务进程..."
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$OLD_PID" ] && kill -15 "$OLD_PID" 2>/dev/null
    sleep 1
    [ -n "$OLD_PID" ] && kill -9 "$OLD_PID" 2>/dev/null
fi

ui_print "- 恢复全部 CPU 核心..."
for c in $(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's/.*cpu//'); do
    echo 1 > "/sys/devices/system/cpu/cpu$c/online" 2>/dev/null
done

ui_print "- 按原始快照恢复 CPU / GPU 上限与权限..."
if [ ! -f "$MODDIR/hardware.sh" ]; then
    ui_print "! 缺少硬件恢复脚本，保留数据，请重启恢复后处理"
    exit 1
fi
. "$MODDIR/hardware.sh"
FREQ_SNAP_FILE="$CONFIG_DIR/freq_snapshot"
GPU_SNAP_FILE="$CONFIG_DIR/gpu_snapshot"
freq_restore_failed=0
cg_cpu_restore_caps || freq_restore_failed=1
cg_gpu_restore_caps || freq_restore_failed=1
if [ "$freq_restore_failed" != 0 ] || [ -s "$FREQ_SNAP_FILE" ] || [ -s "$GPU_SNAP_FILE" ]; then
    ui_print "! 频率恢复尚未完成，保留快照和配置供重试"
    exit 1
fi
ui_print "- 恢复 core_ctl 原始状态..."
# 与运行时共用 cg_hotplug_restore：含“没有 state 却仍是关闭态”的兜底自愈分支
if ! cg_hotplug_restore; then
    ui_print "! 热插拔状态恢复失败，保留数据供重试"
    exit 1
fi

if [ -f "$CORE_CTL_BACKUP" ]; then
    while IFS="$(printf '\t')" read -r node val; do
        [ -z "$node" ] && continue
        echo "$val" > "$node" 2>/dev/null
    done < "$CORE_CTL_BACKUP"
fi

ui_print "- 恢复被停用的系统组件..."
FREEZE_STATE="$CONFIG_DIR/freeze.state"
if [ -f "$MODDIR/service.sh" ] && [ -f "$FREEZE_STATE" ]; then
    if ! sh "$MODDIR/service.sh" --freeze-restore; then
        ui_print "  · 组件恢复未完成，保留数据，请在 App 中重试解冻"
        exit 1
    fi
fi
if [ -s "$FREEZE_STATE" ]; then
    TAB="$(printf '\t')"
    while IFS="$TAB" read -r _p _st _mode; do
        [ -z "$_p" ] && continue
        if [ "$_st" = "enabled" ]; then
            if [ "$_mode" = suspend ]; then
                pm unsuspend --user 0 "$_p" >/dev/null 2>&1
            else
                pm enable --user 0 "$_p" >/dev/null 2>&1
            fi
            if [ $? != 0 ]; then
                ui_print "  · 恢复失败 $_p，保留记录，请先在 App 中重试解冻"
                exit 1
            fi
            ui_print "  · 已恢复 $_p"
        else
            ui_print "  · 保持停用 $_p（原本就是您手动停用的）"
        fi
    done < "$FREEZE_STATE"
fi

ui_print "- 清理数据文件..."
rm -rf "$CONFIG_DIR"
rm -rf /data/local/tmp/CoreGate
rm -rf "$MODDIR/log" 2>/dev/null
rm -f "$MODDIR/coregate.log" "$MODDIR/coregate.log.tmp" \
      "$MODDIR/coregate.log.old" "$MODDIR/service.log" 2>/dev/null

ui_print "✅ 已卸载，全部恢复原始状态（无需重启）"