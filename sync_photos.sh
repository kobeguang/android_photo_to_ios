#!/bin/zsh

# ==========================================
# --- 环境变量与配置区 ---
# ==========================================
# ADB 的绝对路径 (请确保该路径正确，可通过 `which adb` 查看)
ADB_PATH="/opt/homebrew/bin/adb"

# Android 设备的无线调试端口 (我们之前固化的 5566 端口)
PHONE_PORT="5566"

# 需要同步的 Android 远程目录
REMOTE_DIRS=("/sdcard/DCIM/Camera/" "/sdcard/DCIM/Screenshots/")

# 本地临时缓存目录与同步记录日志
LOCAL_TEMP_DIR="/tmp/samsung_photos_sync/"
LOG_FILE="$HOME/Scripts/synced_photos.log"
CACHE_FILE="$HOME/Scripts/.android_ip_cache"

# 初始化本地环境
mkdir -p "$LOCAL_TEMP_DIR"
touch "$LOG_FILE"
touch "$CACHE_FILE"

echo "=== 开始执行 Android to iOS 照片无感同步流水线 ==="

ACTIVE_IP=""

# ==========================================
# --- 阶段一：动态端口嗅探与智能缓存路由 ---
# ==========================================

# 1. 动态获取当前激活的网卡和网段
DEFAULT_IF=$(route -n get default 2>/dev/null | awk '/interface: / {print $2}')
if [[ -z "$DEFAULT_IF" ]]; then
    echo "❌ 错误: 未检测到活动的网络连接。"
    exit 1
fi

MY_IP=$(ifconfig "$DEFAULT_IF" | awk '/inet / {print $2}')
CURRENT_SUBNET=$(echo "$MY_IP" | awk -F. '{print $1"."$2"."$3}')

echo "🌐 当前所在网段: $CURRENT_SUBNET.x"

# 2. 尝试命中缓存 (Cache Hit)
CACHED_IP=$(grep "^${CURRENT_SUBNET}=" "$CACHE_FILE" | cut -d= -f2)

if [[ -n "$CACHED_IP" ]]; then
    echo "💡 发现该网段的缓存 IP: $CACHED_IP，正在尝试快速探测..."
    # 【修复1】: macOS 必须用 -G 1 才能真正限制 TCP 连接超时为 1 秒
    if nc -z -G 1 "$CACHED_IP" "$PHONE_PORT" >/dev/null 2>&1; then
        echo "✅ 缓存命中！手机已就绪。"
        ACTIVE_IP="$CACHED_IP"
    else
        echo "⚠️ 缓存失效 (IP 可能已重新分配或服务未启动)，降级进入全网扫描..."
    fi
fi

# 3. 缓存未命中或失效，执行全网段并发扫描 (Cache Miss)
if [[ -z "$ACTIVE_IP" ]]; then
    echo "🔍 启动全网段并发探测 (预计 1-2 秒内完成)..."
    
    BROADCAST_IP=$(ifconfig "$DEFAULT_IF" | grep broadcast | awk '{print $6}')
    if [[ -n "$BROADCAST_IP" ]]; then
        # 强制局域网内设备暴露自己，刷新 Mac 的 ARP 缓存表
        ping -c 2 -t 1 "$BROADCAST_IP" >/dev/null 2>&1
    fi
    
    # 提取 ARP 表中同网段的有效 IP
    ARP_IPS=$(arp -a | grep "($CURRENT_SUBNET." | awk -F '[()]' '{print $2}')
    
    # 使用临时文件跨子进程传递找到的 IP
    TMP_IP_FILE="$LOCAL_TEMP_DIR/found_ip.tmp"
    rm -f "$TMP_IP_FILE"
    
    # 【修复2】: 核心并发扫描引擎！将所有 nc 探测放入后台 (&) 同步执行
    for IP in $ARP_IPS; do
        (
            if nc -z -G 1 "$IP" "$PHONE_PORT" >/dev/null 2>&1; then
                echo "$IP" > "$TMP_IP_FILE"
            fi
        ) &
    done
    
    # 等待所有并发的后台探针任务结束 (因为加了 -G 1，最多只会等 1 秒)
    wait
    
    # 检查是否有探针成功返回了 IP
    if [[ -f "$TMP_IP_FILE" ]]; then
        ACTIVE_IP=$(head -n 1 "$TMP_IP_FILE")
        rm -f "$TMP_IP_FILE"
        
        echo "✅ 寻址成功：找到设备 $ACTIVE_IP"
        
        # 【回写缓存】: 删除当前网段的旧记录，写入新记录
        sed -i '' "/^${CURRENT_SUBNET}=/d" "$CACHE_FILE"
        echo "${CURRENT_SUBNET}=${ACTIVE_IP}" >> "$CACHE_FILE"
        echo "💾 已将该 IP 写入本地缓存，下次执行将直接秒连。"
    fi
fi

if [[ -z "$ACTIVE_IP" ]]; then
    echo "❌ 扫描结束，未在局域网内找到开放 $PHONE_PORT 端口的设备。"
    exit 1
fi

# ==========================================
# --- 阶段二：建立连接与增量拉取 ---
# ==========================================
echo "🔗 正在连接设备 $ACTIVE_IP:$PHONE_PORT..."
$ADB_PATH connect "$ACTIVE_IP:$PHONE_PORT" >/dev/null 2>&1

# 检查连接是否成功
ADB_STATE=$($ADB_PATH devices | grep "$ACTIVE_IP:$PHONE_PORT" | awk '{print $2}')
if [[ "$ADB_STATE" != "device" ]]; then
    echo "❌ 连接失败，请检查手机是否开启了端口为 $PHONE_PORT 的无线调试或 ADB tcpip。"
    exit 1
fi

echo "✅ 设备连接成功，准备同步照片..."

for REMOTE_DIR in "${REMOTE_DIRS[@]}"; do
    echo "📂 正在检查目录: $REMOTE_DIR"
    
    # 列出远程目录下的所有文件 (排除子目录)
    REMOTE_FILES=$($ADB_PATH shell ls -p "$REMOTE_DIR" | grep -v / | tr -d '\r')
    
    if [[ -z "$REMOTE_FILES" ]]; then
        echo "  -> 目录为空或未找到。"
        continue
    fi
    
    SYNC_COUNT=0
    
    # 逐行读取远程文件名并进行增量比对
    echo "$REMOTE_FILES" | while IFS= read -r FILENAME; do
        if [[ -z "$FILENAME" ]]; then continue; fi
        
        FULL_REMOTE_PATH="${REMOTE_DIR}${FILENAME}"
        
        # 如果日志里没有记录过这个文件的绝对路径，说明是新拍摄的照片
        if ! grep -Fxq "$FULL_REMOTE_PATH" "$LOG_FILE"; then
            LOCAL_PATH="${LOCAL_TEMP_DIR}${FILENAME}"
            echo "     📥 拉取新照片: $FILENAME"
            
            # 从 Android 拉取到 Mac 临时目录
            $ADB_PATH pull "$FULL_REMOTE_PATH" "$LOCAL_PATH" >/dev/null 2>&1
            
            # 校验文件是否拉取成功，并调用 AppleScript 导入 Mac 照片 App
            if [[ -f "$LOCAL_PATH" ]]; then
                osascript -e "tell application \"Photos\" to import POSIX file \"$LOCAL_PATH\" skip check duplicates yes"
                
                # 导入成功后，记录日志并删除本地临时缓存，释放 Mac 硬盘空间
                echo "$FULL_REMOTE_PATH" >> "$LOG_FILE"
                rm "$LOCAL_PATH"
                ((SYNC_COUNT++))
            fi
        fi
    done
    
    if [[ $SYNC_COUNT -eq 0 ]]; then
        echo "  -> 没有发现新照片。"
    else
        echo "  -> 🎉 本次成功同步 $SYNC_COUNT 张照片。"
    fi
done

# 断开连接 (保持整洁)
$ADB_PATH disconnect "$ACTIVE_IP:$PHONE_PORT" >/dev/null 2>&1
echo "=== 同步任务结束 ==="
