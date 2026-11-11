#!/system/bin/sh

MODDIR=${0%/*}

for _cg_lib in config hardware freeze cores frequency probe runtime thermal adapt lifecycle commands; do
    [ -r "$MODDIR/lib/$_cg_lib.sh" ] || { echo "CoreGate Pro: missing library $_cg_lib.sh" >&2; exit 1; }
done
unset _cg_lib
if [ ! -f "$MODDIR/hardware.sh" ]; then echo "缺少 hardware.sh" >&2; exit 1; fi
# CONFIG_DIR 必须早于 hardware.sh 被 source：热插拔 state 路径依赖它
CONFIG_DIR="/data/adb/CoreGate"
. "$MODDIR/hardware.sh"
if [ "$1" = --hardware-status ]; then cg_hardware_report; exit 0; fi
# 热插拔状态查询与自愈入口：主循环存活时也能手动核对/修复
if [ "$1" = --hotplug-status ]; then cg_hotplug_report; exit 0; fi
if [ "$1" = --hotplug-heal ]; then
    if cg_hotplug_restore; then echo "hotplug healed"; exit 0; fi
    cg_hotplug_report; echo "hotplug heal failed" >&2; exit 1
fi
MODULE_ID=$(basename "$MODDIR")
CONFIG_FILE="$CONFIG_DIR/config.json"
PACKAGES_FILE="$CONFIG_DIR/packages.txt"
CAPTURE_FILE="$CONFIG_DIR/capture.txt"
if [ -d "$MODDIR" ] && [ -w "$MODDIR" ]; then
    LOG_DIR="$MODDIR/log"
else
    LOG_DIR="$CONFIG_DIR/log"
fi
LOG_FILE="$LOG_DIR/coregate.log"
STATE_FILE="$CONFIG_DIR/state"
PID_FILE="$CONFIG_DIR/daemon.pid"
CORE_CTL_BACKUP="$CONFIG_DIR/corectl.state"
MANUAL_FILE="$CONFIG_DIR/manual_off"

CAPTURE_DEFAULT="com.oplus.screenrecorder
com.coloros.screenrecorder
com.oneplus.screenrecord
com.android.systemui.screenrecord
com.oplus.camera
com.oneplus.camera
com.coloros.camera
com.android.camera"

mkdir -p "$LOG_DIR" 2>/dev/null

log() {
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null
    sz=$(wc -c < "$LOG_FILE" 2>/dev/null)
    if [ -n "$sz" ] && [ "$sz" -gt 262144 ]; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
    fi
}
migrate_old_log() {
    for old_log in \
        "$CONFIG_DIR/coregate.log" \
        "$MODDIR/coregate.log" \
        "$CONFIG_DIR/service.log" \
        "$MODDIR/service.log"; do
        [ "$old_log" = "$LOG_FILE" ] && continue
        [ -f "$old_log" ] || continue
        {
            echo "[$(date '+%m-%d %H:%M:%S')] —— 以下为迁移前的历史日志（$old_log）——"
            cat "$old_log" 2>/dev/null
        } >> "$LOG_FILE" 2>/dev/null
        rm -f "$old_log" 2>/dev/null
    done
    rm -f "$MODDIR/coregate.log.tmp" "$CONFIG_DIR/coregate.log.tmp" 2>/dev/null
}

mkdir -p "$CONFIG_DIR"
migrate_old_log
if [ ! -f "$CONFIG_FILE" ] && [ -f "$MODDIR/config.example.json" ]; then
    cp -f "$MODDIR/config.example.json" "$CONFIG_FILE" 2>/dev/null
    chmod 0644 "$CONFIG_FILE" 2>/dev/null
fi
if [ ! -f "$PACKAGES_FILE" ]; then
    if [ -f "$CONFIG_FILE" ] && grep -q '"game_packages"' "$CONFIG_FILE" 2>/dev/null; then
        sed -n '/"game_packages"/,/]/p' "$CONFIG_FILE" 2>/dev/null \
            | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^game_packages$' > "$PACKAGES_FILE"
    fi
    if [ ! -s "$PACKAGES_FILE" ] && [ -f "$MODDIR/packages.txt" ]; then
        cp -f "$MODDIR/packages.txt" "$PACKAGES_FILE" 2>/dev/null
    fi
    chmod 0644 "$PACKAGES_FILE" 2>/dev/null
fi

. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/hardware.sh"
. "$MODDIR/lib/freeze.sh"
. "$MODDIR/lib/cores.sh"
. "$MODDIR/lib/frequency.sh"
. "$MODDIR/lib/probe.sh"
. "$MODDIR/lib/runtime.sh"
. "$MODDIR/lib/thermal.sh"
. "$MODDIR/lib/adapt.sh"
. "$MODDIR/lib/lifecycle.sh"
. "$MODDIR/lib/commands.sh"