#!/system/bin/sh
SKIPUNZIP=1

ui_print "=============================="
ui_print "  CoreGate pro 安装中"
ui_print "=============================="

ui_print "- 清理旧版本残留..."

if [ -d "/data/adb/CoreGate" ]; then
    if [ -f "/data/adb/CoreGate/daemon.pid" ]; then
        oldpid=$(cat "/data/adb/CoreGate/daemon.pid" 2>/dev/null)
        case "$oldpid" in
            ''|*[!0-9]*) : ;;
            *) kill "$oldpid" 2>/dev/null; sleep 1 ;;
        esac
    fi
    rm -f "/data/adb/CoreGate/coregate.log" \
          "/data/adb/CoreGate/coregate.log.tmp" \
          "/data/adb/CoreGate/service.log" \
          "/data/adb/CoreGate/state" \
          "/data/adb/CoreGate/daemon.pid" \
          "/data/adb/CoreGate/crash_flag" \
          "/data/adb/CoreGate/corectl.state" 2>/dev/null
    rm -f /data/adb/CoreGate/giveup_* 2>/dev/null
    rm -rf "/data/adb/CoreGate/log" 2>/dev/null
fi

rm -f "$MODPATH/coregate.log" "$MODPATH/coregate.log.tmp" 2>/dev/null
rm -rf "$MODPATH/log" 2>/dev/null

ui_print "- 解压模块文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

ui_print "- 设置脚本权限..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/hardware.sh" 0 0 0644
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
if [ -f "$MODPATH/bin/coregated" ]; then
    set_perm "$MODPATH/bin/coregated" 0 0 0755
fi

CONFIG_DIR="/data/adb/CoreGate"
mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    ui_print "- 首次安装：写入默认配置..."
    cp -f "$MODPATH/config.example.json" "$CONFIG_DIR/config.json"
    chmod 0644 "$CONFIG_DIR/config.json"
fi

if [ ! -f "$CONFIG_DIR/packages.txt" ]; then
    if [ -f "$CONFIG_DIR/config.json" ] && grep -q '"game_packages"' "$CONFIG_DIR/config.json" 2>/dev/null; then
        ui_print "- 迁移旧版游戏列表..."
        sed -n '/"game_packages"/,/]/p' "$CONFIG_DIR/config.json" 2>/dev/null \
            | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^game_packages$' > "$CONFIG_DIR/packages.txt"
    fi
    if [ ! -s "$CONFIG_DIR/packages.txt" ]; then
        ui_print "- 写入默认游戏列表..."
        cp -f "$MODPATH/packages.txt" "$CONFIG_DIR/packages.txt"
    fi
    chmod 0644 "$CONFIG_DIR/packages.txt"
fi

if [ ! -f "$CONFIG_DIR/capture.txt" ]; then
    ui_print "- 写入默认录屏/相机列表..."
    cp -f "$MODPATH/capture.txt" "$CONFIG_DIR/capture.txt"
    chmod 0644 "$CONFIG_DIR/capture.txt"
fi

if [ -f "$MODPATH/migrate-config.sh" ]; then
    . "$MODPATH/migrate-config.sh"
    if cg_migrate_config "$CONFIG_DIR/config.json" "$MODPATH/config.example.json"; then
        ui_print "- 配置迁移完成：保留有效设置并清理旧字段"
    else
        ui_print "! 配置迁移未完成，保留原配置"
    fi
fi

detect_high_cluster() {
    local maxf=0 c f out=""
    for c in $(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's/.*cpu//'); do
        f=$(cat "/sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        [ -z "$f" ] && continue
        if [ "$f" -gt "$maxf" ]; then
            maxf="$f"; out="$c"
        elif [ "$f" -eq "$maxf" ]; then
            out="$out $c"
        fi
    done
    echo "$out"
}

ui_print "- 检测核心拓扑..."
TOTAL=0
for c in $(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null); do TOTAL=$((TOTAL+1)); done
ui_print "  共 ${TOTAL} 个核心"
TOP=$(detect_high_cluster)
if [ -n "$TOP" ]; then
    ui_print "  高频大核: cpu$(echo $TOP | sed 's/ / cpu/g')"
else
    ui_print "  ⚠️ 未能读取 cpufreq 信息（不影响安装）"
fi

ui_print "✅ 安装完成！"
ui_print "  重启后打开「核心门控」App 查看与调整全部设置"
ui_print "  未装 App 时可在 KernelSU 模块页点「执行」查看状态"
ui_print "  安装「核心门控」App 后在 App 内添加游戏包名"
ui_print "  首次安装全部关闭，请在 App 内开启并配置"