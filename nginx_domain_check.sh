#!/bin/bash

# ================= 配置区 =================
# 你的 Nginx 配置目录
NGINX_ROOT="/usr/local/nginx/conf/conf.d/"
TIMEOUT=3
# =========================================

echo "🔍 正在探测服务器的多路公网 IP..."

DETECTED_IPS_STRING=""
# 1. 获取物理接口 IP (排除 docker/veth 等)
INTERNAL_IPS=$(ip -o -4 addr show | grep -vE " lo |docker|veth|br-|virbr" | awk '{print $4}' | cut -d/ -f1)

if [ -z "$INTERNAL_IPS" ]; then
    echo "❌ 未检测到有效的物理/内网 IP，请检查网络配置。"
    exit 1
fi

echo "----------------------------------------------------"
for INT_IP in $INTERNAL_IPS; do
    PUB_IP=$(curl --interface "$INT_IP" --connect-timeout $TIMEOUT -s4 ifconfig.me)
    if [ ! -z "$PUB_IP" ]; then
        echo -e "内网 $INT_IP \t--> 公网 \033[32m$PUB_IP\033[0m"
        DETECTED_IPS_STRING="$DETECTED_IPS_STRING $PUB_IP"
    fi
done

if [ -z "$DETECTED_IPS_STRING" ]; then
    echo "❌ 无法获取任何公网 IP。"
    exit 1
fi

echo "----------------------------------------------------"
echo "正在提取 Nginx 域名并比对 DNS..."

# 精准提取域名
DOMAIN_LIST=$(nginx -T 2>/dev/null \
    | grep -E "^\s*server_name\s+" \
    | sed 's/server_name//g; s/;//g; s/{//g' \
    | tr ' ' '\n' \
    | sort -u \
    | grep -vE "^$|localhost|on|off|_|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")

# 定义两个变量存储最终结果
LIST_OK=""
LIST_FAIL=""

# 开始逐个检测
for DOMAIN in $DOMAIN_LIST; do
    # 跳过通配符
    if echo "$DOMAIN" | grep -q "\*"; then
        continue
    fi

    # 使用 getent hosts 获取解析 IP
    RESOLVED_IP=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -n 1)

    # 判断逻辑
    if [ -z "$RESOLVED_IP" ]; then
        # 情况1：无解析
        echo -e "❌ $DOMAIN \t(无解析记录)"
        LIST_FAIL="${LIST_FAIL}${DOMAIN}|(无解析)\n"
    elif echo "$DETECTED_IPS_STRING" | grep -q "$RESOLVED_IP"; then
        # 情况2：解析正确
        echo -e "✅ $DOMAIN \t-> $RESOLVED_IP"
        LIST_OK="${LIST_OK}${DOMAIN}\n"
    else
        # 情况3：解析不匹配
        echo -e "⚠️ $DOMAIN \t-> $RESOLVED_IP (不匹配)"
        LIST_FAIL="${LIST_FAIL}${DOMAIN}|(IP:_${RESOLVED_IP})\n"
    fi
done

# ==========================================================
# 最终汇总输出 (User Requested)
# ==========================================================
echo ""
echo "####################################################"
echo "                 最终检测报告汇总"
echo "####################################################"

echo -e "\n✅ 【正常域名】 (已解析到本机，建议保留):"
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
    # 简单的格式化输出：域名 (原因)
    echo -e "$LIST_FAIL" | sed '/^$/d' | awk -F'|' '{printf "%-30s %s\n", $1, $2}'
fi

echo "####################################################"