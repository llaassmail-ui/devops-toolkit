#!/bin/bash

# ================= 配置区 =================
# 你的 Nginx 配置目录
NGINX_ROOT="/usr/local/nginx/conf/conf.d/"
TIMEOUT=3
# =========================================

echo "🔍 正在探测服务器的多路公网 IP (IPv4 & IPv6)..."

# 存储所有检测到的 IP (用于白名单比对)
DETECTED_IPS_STRING=""

# ---------------------------------------------------------
# 1. 探测 IPv4
# ---------------------------------------------------------
# 排除 lo, docker, veth 等虚拟网卡
INTERNAL_IPS_V4=$(ip -o -4 addr show | grep -vE " lo |docker|veth|br-|virbr" | awk '{print $4}' | cut -d/ -f1)

if [ ! -z "$INTERNAL_IPS_V4" ]; then
    for INT_IP in $INTERNAL_IPS_V4; do
        # -4 强制使用 IPv4
        PUB_IP=$(curl --interface "$INT_IP" --connect-timeout $TIMEOUT -s -4 ifconfig.me)
        if [ ! -z "$PUB_IP" ]; then
            echo -e "[IPv4] 内网 $INT_IP \t--> 公网 \033[32m$PUB_IP\033[0m"
            DETECTED_IPS_STRING="$DETECTED_IPS_STRING $PUB_IP"
        fi
    done
fi

# ---------------------------------------------------------
# 2. 探测 IPv6 (新增功能)
# ---------------------------------------------------------
# 排除 lo, docker, veth
# 关键：排除 scope host (::1) 和 scope link (fe80开头)，只保留 scope global
INTERNAL_IPS_V6=$(ip -o -6 addr show | grep "scope global" | grep -vE " lo |docker|veth|br-|virbr" | awk '{print $4}' | cut -d/ -f1)

if [ ! -z "$INTERNAL_IPS_V6" ]; then
    for INT_IP in $INTERNAL_IPS_V6; do
        # -6 强制使用 IPv6，且 ifconfig.me 支持返回 IPv6 地址
        # 注意：这里需要给 curl 加 [] 包裹 IPv6 地址吗？--interface 不需要，但在 URL 里需要。这里作为 bind address 不需要。
        PUB_IP=$(curl --interface "$INT_IP" --connect-timeout $TIMEOUT -s -6 ifconfig.me)
        
        if [ ! -z "$PUB_IP" ]; then
            echo -e "[IPv6] 内网 ...$(echo $INT_IP | awk -F: '{print $NF}') \t--> 公网 \033[36m$PUB_IP\033[0m"
            DETECTED_IPS_STRING="$DETECTED_IPS_STRING $PUB_IP"
        fi
    done
else
    echo "⚠️ 未检测到全球单播 IPv6 地址 (已跳过 IPv6 检测)"
fi

if [ -z "$DETECTED_IPS_STRING" ]; then
    echo "❌ 无法获取任何公网 IP (v4 或 v6)。"
    exit 1
fi

echo "----------------------------------------------------"
echo "正在提取 Nginx 域名并比对 DNS (A + AAAA)..."

# 精准提取域名
DOMAIN_LIST=$(nginx -T 2>/dev/null \
    | grep -E "^\s*server_name\s+" \
    | sed 's/server_name//g; s/;//g; s/{//g' \
    | tr ' ' '\n' \
    | sort -u \
    | grep -vE "^$|localhost|on|off|_|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")

LIST_OK=""
LIST_FAIL=""

# 开始逐个检测
for DOMAIN in $DOMAIN_LIST; do
    # 跳过通配符
    if echo "$DOMAIN" | grep -q "\*"; then
        continue
    fi

    # =========================================================
    # 解析逻辑升级：同时获取 IPv4 和 IPv6
    # getent ahosts 会返回该域名的所有 IP (包括 v4 和 v6)
    # awk '{print $1}' 提取 IP, sort -u 去重
    # =========================================================
    RESOLVED_IPS=$(getent ahosts "$DOMAIN" | awk '{print $1}' | sort -u)

    if [ -z "$RESOLVED_IPS" ]; then
        # 情况1：无解析
        echo -e "❌ $DOMAIN \t(无解析记录)"
        LIST_FAIL="${LIST_FAIL}${DOMAIN}|(无解析)\n"
        continue
    fi

    # 检查是否有任意一个 IP 匹配本机
    IS_MATCH=0
    MATCHED_IP=""
    
    # 遍历该域名解析出的所有 IP (可能是多条 v4 和 v6)
    for R_IP in $RESOLVED_IPS; do
        # 使用 grep 精确匹配 (防止 IP 前缀相似造成的误判)
        if echo "$DETECTED_IPS_STRING" | grep -F -q "$R_IP"; then
            IS_MATCH=1
            MATCHED_IP="$R_IP"
            break # 只要有一个 IP 对上了，就算通过
        fi
    done

    if [ $IS_MATCH -eq 1 ]; then
        # 情况2：解析正确
        echo -e "✅ $DOMAIN \t-> $MATCHED_IP"
        LIST_OK="${LIST_OK}${DOMAIN}\n"
    else
        # 情况3：所有 IP 都不匹配
        # 取第一个 IP 用于展示错误信息
        FIRST_IP=$(echo "$RESOLVED_IPS" | head -n 1)
        echo -e "⚠️ $DOMAIN \t-> $FIRST_IP (不匹配)"
        LIST_FAIL="${LIST_FAIL}${DOMAIN}|(IP:_${FIRST_IP}_等)\n"
    fi
done

# ==========================================================
# 最终汇总输出
# ==========================================================
echo ""
echo "####################################################"
echo "                 最终检测报告汇总"
echo "####################################################"

echo -e "\n✅ 【正常域名】 (已解析到本机 v4/v6，建议保留):"
echo "----------------------------------------"
if [ -z "$LIST_OK" ]; then
    echo "(无)"
else
    echo -e "$LIST_OK" | sed '/^$/d'
fi

echo -e "\n❌ 【异常域名】 (未解析或IP不符，建议清理):"
echo "----------------------------------------"
if [ -z "$LIST_FAIL" ]; then
    echo "(无)"
else
    echo -e "$LIST_FAIL" | sed '/^$/d' | awk -F'|' '{printf "%-30s %s\n", $1, $2}'
fi

echo "####################################################"