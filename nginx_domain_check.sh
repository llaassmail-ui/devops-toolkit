#!/bin/bash

# ================= 配置区 =================
# Nginx 配置目录，仅用于提示；实际域名通过 nginx -T 读取
NGINX_ROOT="/usr/local/nginx/conf/"
TIMEOUT=3
# =========================================

echo "[INFO] 正在探测服务器的多路公网 IP (IPv4 & IPv6)..."

# 存储所有检测到的公网 IP，用于 DNS 比对
DETECTED_IPS_STRING=""

# ---------------------------------------------------------
# 1. 探测 IPv4
# ---------------------------------------------------------
# 排除 lo、docker、veth、br、virbr 等虚拟网卡
INTERNAL_IPS_V4=$(ip -o -4 addr show \
    | grep -vE " lo |docker|veth|br-|virbr" \
    | awk '{print $4}' \
    | cut -d/ -f1)

if [ -n "$INTERNAL_IPS_V4" ]; then
    for INT_IP in $INTERNAL_IPS_V4; do
        PUB_IP=$(curl --interface "$INT_IP" --connect-timeout "$TIMEOUT" -s -4 ifconfig.me)

        if [ -n "$PUB_IP" ]; then
            echo -e "[IPv4] 内网 $INT_IP \t--> 公网 $PUB_IP"
            DETECTED_IPS_STRING="$DETECTED_IPS_STRING $PUB_IP"
        fi
    done
fi

# ---------------------------------------------------------
# 2. 探测 IPv6
# ---------------------------------------------------------
# 只保留 scope global，排除 ::1、fe80 等本地地址
INTERNAL_IPS_V6=$(ip -o -6 addr show \
    | grep "scope global" \
    | grep -vE " lo |docker|veth|br-|virbr" \
    | awk '{print $4}' \
    | cut -d/ -f1)

if [ -n "$INTERNAL_IPS_V6" ]; then
    for INT_IP in $INTERNAL_IPS_V6; do
        PUB_IP=$(curl --interface "$INT_IP" --connect-timeout "$TIMEOUT" -s -6 ifconfig.me)

        if [ -n "$PUB_IP" ]; then
            SHORT_V6=$(echo "$INT_IP" | awk -F: '{print $NF}')
            echo -e "[IPv6] 内网 ...$SHORT_V6 \t--> 公网 $PUB_IP"
            DETECTED_IPS_STRING="$DETECTED_IPS_STRING $PUB_IP"
        fi
    done
else
    echo "[INFO] 未检测到全球单播 IPv6 地址，已跳过 IPv6 检测"
fi

if [ -z "$DETECTED_IPS_STRING" ]; then
    echo "[ERROR] 无法获取任何公网 IP，检查服务器网络或 ifconfig.me 访问情况"
    exit 1
fi

echo "----------------------------------------------------"
echo "[INFO] 正在提取 Nginx 域名并比对 DNS 解析记录 (A + AAAA)..."

# ---------------------------------------------------------
# 3. 提取 Nginx server_name
# ---------------------------------------------------------
# 重点：
# 1. tr -d '\r' 用于兼容 Windows CRLF，解决 ^M 导致输出错位问题
# 2. 使用 [[:space:]] 兼容空格和 Tab
# 3. tr '[:space:]' '\n' 可拆分一行多个 server_name
# ---------------------------------------------------------
DOMAIN_LIST=$(nginx -T 2>/dev/null \
    | tr -d '\r' \
    | grep -E "^[[:space:]]*server_name[[:space:]]+" \
    | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;//g; s/\{//g' \
    | tr '[:space:]' '\n' \
    | sed '/^$/d' \
    | sort -u \
    | grep -vE "^localhost$|^on$|^off$|^_$|^\*$|^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$")

if [ -z "$DOMAIN_LIST" ]; then
    echo "[WARN] 未从 nginx -T 中提取到 server_name"
    exit 0
fi

LIST_OK=""
LIST_FAIL=""
LIST_SKIP=""

# ---------------------------------------------------------
# 4. 逐个域名检测 DNS
# ---------------------------------------------------------
for DOMAIN in $DOMAIN_LIST; do
    # 二次兜底：清理隐藏 \r 和前后空格
    DOMAIN=$(printf '%s' "$DOMAIN" | tr -d '\r' | xargs)

    [ -z "$DOMAIN" ] && continue

    # 跳过通配符域名
    if echo "$DOMAIN" | grep -q "\*"; then
        LIST_SKIP="${LIST_SKIP}${DOMAIN}|通配符域名，已跳过\n"
        continue
    fi

    # 基础域名格式过滤，避免误把奇怪字符拿去 DNS 查询
    if ! echo "$DOMAIN" | grep -Eq '^[A-Za-z0-9._-]+$'; then
        echo -e "[SKIP] $DOMAIN \t域名格式异常，已跳过"
        LIST_SKIP="${LIST_SKIP}${DOMAIN}|域名格式异常\n"
        continue
    fi

    # 同时获取 A / AAAA 解析
    RESOLVED_IPS=$(getent ahosts "$DOMAIN" \
        | awk '{print $1}' \
        | sort -u)

    if [ -z "$RESOLVED_IPS" ]; then
        echo -e "[FAIL] $DOMAIN \t(无解析记录)"
        LIST_FAIL="${LIST_FAIL}${DOMAIN}|(无解析)\n"
        continue
    fi

    IS_MATCH=0
    MATCHED_IP=""

    for R_IP in $RESOLVED_IPS; do
        # 精确匹配本机检测到的公网 IP
        if echo " $DETECTED_IPS_STRING " | grep -F -q " $R_IP "; then
            IS_MATCH=1
            MATCHED_IP="$R_IP"
            break
        fi
    done

    if [ "$IS_MATCH" -eq 1 ]; then
        echo -e "[OK]   $DOMAIN \t-> $MATCHED_IP"
        LIST_OK="${LIST_OK}${DOMAIN}|${MATCHED_IP}\n"
    else
        FIRST_IP=$(echo "$RESOLVED_IPS" | head -n 1)
        ALL_IPS=$(echo "$RESOLVED_IPS" | tr '\n' ',' | sed 's/,$//')
        echo -e "[FAIL] $DOMAIN \t-> $FIRST_IP (不匹配)"
        LIST_FAIL="${LIST_FAIL}${DOMAIN}|(IP:${ALL_IPS})\n"
    fi
done

# ---------------------------------------------------------
# 5. 最终汇总输出
# ---------------------------------------------------------
echo ""
echo "####################################################"
echo "                 最终检测报告汇总"
echo "####################################################"

echo ""
echo "[OK] 正常域名：已解析到本机 IPv4 / IPv6，建议保留"
echo "----------------------------------------"
if [ -z "$LIST_OK" ]; then
    echo "(无)"
else
    echo -e "$LIST_OK" \
        | sed '/^$/d' \
        | awk -F'|' '{printf "%-35s %s\n", $1, $2}'
fi

echo ""
echo "[FAIL] 异常域名：未解析或 IP 不符，建议检查"
echo "----------------------------------------"
if [ -z "$LIST_FAIL" ]; then
    echo "(无)"
else
    echo -e "$LIST_FAIL" \
        | sed '/^$/d' \
        | awk -F'|' '{printf "%-35s %s\n", $1, $2}'
fi

echo ""
echo "[SKIP] 已跳过项目"
echo "----------------------------------------"
if [ -z "$LIST_SKIP" ]; then
    echo "(无)"
else
    echo -e "$LIST_SKIP" \
        | sed '/^$/d' \
        | awk -F'|' '{printf "%-35s %s\n", $1, $2}'
fi

echo "####################################################"
echo "[INFO] 检测完成"
