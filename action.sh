#!/system/bin/sh

MODDIR=${0%/*}

PKG_US="com.zimky.coregateUS"
PKG_OLD="com.zimky.coregate"
ACT="${PKG_US}/com.zimky.coregateUS.MainActivity"

TARGET=""
if pm list packages 2>/dev/null | grep -qx "package:$PKG_US"; then
    TARGET="$PKG_US"
elif pm list packages 2>/dev/null | grep -qx "package:$PKG_OLD"; then
    TARGET="$PKG_OLD"
    ACT="${PKG_OLD}/com.zimky.coregate.MainActivity"
fi

if [ -z "$TARGET" ]; then
    echo "================================"
    echo " 没有找到 CoreGate App"
    echo "================================"
    echo ""
    echo "本模块的配置界面是独立的 App，需要单独安装。"
    echo "请到项目发布页下载 CoreGate-*.apk 安装后，再点一次「执行」。"
    echo ""
    echo "提示：不装 App 也能正常锁核，"
    echo "      模块会一直使用 /data/adb/CoreGate/config.json 里的配置运行。"
    echo ""
    echo "--- 当前模块运行状态（只读）---"
    if [ -f "/data/adb/CoreGate/daemon.pid" ]; then
        _p=$(cat "/data/adb/CoreGate/daemon.pid" 2>/dev/null)
        if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
            echo "守护进程：运行中 (PID $_p)"
        else
            echo "守护进程：未运行（PID 文件残留）"
        fi
    else
        echo "守护进程：未运行"
    fi
    if [ -f "/data/adb/CoreGate/state" ]; then
        echo "上次状态：$(cat /data/adb/CoreGate/state 2>/dev/null)"
    fi
    exit 0
fi

am start -n "$ACT" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    monkey -p "$TARGET" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
fi

echo "已打开 CoreGate App（$TARGET）"
echo ""
echo "App 内四页导航："
echo "  ① 锁核运行状态 / 核心状态 / 封锁核心"
echo "  ② 录屏·相机自动恢复 / 策略"
echo "  ③ 日常限频"
echo "  ④ 设置（含限频自定义、可选组件停用）"
exit 0
