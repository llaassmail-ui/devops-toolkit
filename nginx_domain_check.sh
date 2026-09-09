#!/usr/bin/env bash

# =========================================================
# Nginx 域名与公网 IPv4 / IPv6 DNS 解析检查脚本
#
# 功能：
# 1. 探测服务器公网 IPv4 和 IPv6
# 2. 提取 Nginx 配置中的 server_name
# 3. 查询域名的 A 和 AAAA 记录
# 4. 分别判断 IPv4 / IPv6 是否匹配当前服务器
# 5. 输出完整检查报告
#
# 适用系统：
# Rocky Linux / CentOS / RHEL / Debian / Ubuntu
# =========================================================

# 不使用 set -u。
# 因为空数组、空 DNS 结果在本脚本中属于正常情况。
set -o pipefail

# ================= 配置区 =================

# Nginx 可执行文件路径。
# 如果 nginx 命令已经在 PATH 中，保持 nginx 即可。
#
# 源码安装的 Nginx 可以改成：
# NGINX_BIN="/usr/local/nginx/sbin/nginx"
NGINX_BIN="${NGINX_BIN:-nginx}"

# curl 连接超时时间，单位：秒
TIMEOUT="${TIMEOUT:-3}"

# 公共 DNS 查询服务器。
# 使用 IPv4 DNS 地址查询 A 和 AAAA，避免本机没有 IPv6
# 时无法访问 IPv6 DNS 服务器。
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"

# 获取公网 IP 的服务
PUBLIC_IP_SERVICE="${PUBLIC_IP_SERVICE:-https://api.ipify.org}"

# =========================================


# =========================================================
# 通用函数
# =========================================================

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

contains_value() {
    local needle="$1"
    shift

    local item

    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done

    return 1
}

print_records() {
    local records="$1"

    if [[ -z "$records" ]]; then
        echo "    无记录"
        return
    fi

    while IFS= read -r record; do
        [[ -n "$record" ]] && echo "    $record"
    done <<< "$records"
}

print_domain_list() {
    local item

    if [[ "$#" -eq 0 ]]; then
        echo "  无"
        return
    fi

    for item in "$@"; do
        echo "  $item"
    done
}


# =========================================================
# 检查依赖命令
# =========================================================

for command_name in \
    ip \
    curl \
    dig \
    awk \
    sed \
    grep \
    sort \
    tr \
    xargs
do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "缺少命令：$command_name"
    fi
done

if ! command -v "$NGINX_BIN" >/dev/null 2>&1; then
    die "找不到 Nginx 命令：$NGINX_BIN"
fi


# =========================================================
# 初始化数组
# =========================================================

DETECTED_IPV4=()
DETECTED_IPV6=()

LOCAL_IPV4=()
LOCAL_IPV6=()

OK_DOMAINS=()
WARN_DOMAINS=()
FAIL_DOMAINS=()
SKIP_DOMAINS=()


# =========================================================
# 探测本机公网 IPv4 / IPv6
# =========================================================

echo "[INFO] 正在探测服务器公网 IPv4 / IPv6..."
echo

# 获取非虚拟网卡的 IPv4 地址
while IFS= read -r local_ip; do
    [[ -n "$local_ip" ]] && LOCAL_IPV4+=("$local_ip")
done < <(
    ip -o -4 addr show scope global 2>/dev/null \
        | awk '
            $2 !~ /^(docker|veth|br-|virbr|lo)/ {
                split($4, addr, "/")
                print addr[1]
            }
        ' \
        | sort -u
)

# 获取非虚拟网卡的 IPv6 地址
while IFS= read -r local_ip; do
    [[ -n "$local_ip" ]] && LOCAL_IPV6+=("$local_ip")
done < <(
    ip -o -6 addr show scope global 2>/dev/null \
        | awk '
            $2 !~ /^(docker|veth|br-|virbr|lo)/ {
                split($4, addr, "/")
                print addr[1]
            }
        ' \
        | sort -u
)


# -------------------------
# 探测 IPv4 公网地址
# -------------------------

for local_ip in "${LOCAL_IPV4[@]}"; do
    [[ -z "$local_ip" ]] && continue

    public_ip=$(
        curl \
            --interface "$local_ip" \
            --connect-timeout "$TIMEOUT" \
            --max-time 8 \
            --fail \
            --silent \
            --show-error \
            -4 \
            "$PUBLIC_IP_SERVICE" 2>/dev/null \
        | tr -d '[:space:]'
    )

    if [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if ! contains_value "$public_ip" "${DETECTED_IPV4[@]}"; then
            DETECTED_IPV4+=("$public_ip")
        fi

        printf '[IPv4] 本地地址 %-18s -> 公网地址 %s\n' \
            "$local_ip" \
            "$public_ip"
    else
        printf '[IPv4] 本地地址 %-18s -> 获取公网地址失败\n' \
            "$local_ip"
    fi
done


# -------------------------
# 探测 IPv6 公网地址
# -------------------------

for local_ip in "${LOCAL_IPV6[@]}"; do
    [[ -z "$local_ip" ]] && continue

    public_ip=$(
        curl \
            --interface "$local_ip" \
            --connect-timeout "$TIMEOUT" \
            --max-time 8 \
            --fail \
            --silent \
            --show-error \
            -6 \
            "$PUBLIC_IP_SERVICE" 2>/dev/null \
        | tr -d '[:space:]'
    )

    if [[ "$public_ip" == *:* ]]; then
        if ! contains_value "$public_ip" "${DETECTED_IPV6[@]}"; then
            DETECTED_IPV6+=("$public_ip")
        fi

        short_ipv6="${local_ip:0:18}"

        printf '[IPv6] 本地地址 %-18s -> 公网地址 %s\n' \
            "${short_ipv6}..." \
            "$public_ip"
    else
        short_ipv6="${local_ip:0:18}"

        printf '[IPv6] 本地地址 %-18s -> 获取公网地址失败\n' \
            "${short_ipv6}..."
    fi
done


echo

if [[ "${#DETECTED_IPV4[@]}" -eq 0 && "${#DETECTED_IPV6[@]}" -eq 0 ]]; then
    die "无法获取任何公网 IP，请检查服务器网络、默认路由或公网 IP 查询服务"
fi


# -------------------------
# 输出当前探测到的公网 IPv4
# -------------------------

echo "[INFO] 当前检测到的公网 IPv4："

if [[ "${#DETECTED_IPV4[@]}" -eq 0 ]]; then
    echo "  无"
else
    for public_ip in "${DETECTED_IPV4[@]}"; do
        echo "  $public_ip"
    done
fi


echo

# -------------------------
# 输出当前探测到的公网 IPv6
# -------------------------

echo "[INFO] 当前检测到的公网 IPv6："

if [[ "${#DETECTED_IPV6[@]}" -eq 0 ]]; then
    echo "  无"
else
    for public_ip in "${DETECTED_IPV6[@]}"; do
        echo "  $public_ip"
    done
fi


echo
echo "========================================================"
echo "[INFO] 正在读取 Nginx server_name..."
echo "========================================================"


# =========================================================
# 读取 Nginx 配置
# =========================================================

NGINX_CONFIG=""

if ! NGINX_CONFIG="$("$NGINX_BIN" -T 2>/dev/null)"; then
    die "Nginx 配置检查失败，请执行：$NGINX_BIN -t"
fi


# =========================================================
# 提取 Nginx 中所有 server_name
# =========================================================

DOMAIN_LIST=$(
    printf '%s\n' "$NGINX_CONFIG" \
        | tr -d '\r' \
        | grep -E '^[[:space:]]*server_name[[:space:]]+' \
        | sed -E '
            s/^[[:space:]]*server_name[[:space:]]+//
            s/;//g
            s/\{//g
        ' \
        | tr '[:space:]' '\n' \
        | sed '/^$/d' \
        | sort -u \
        | grep -vE '
            ^localhost$|
            ^on$|
            ^off$|
            ^_$|
            ^\*$|
            ^\$|
            ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$
        '
)

if [[ -z "$DOMAIN_LIST" ]]; then
    echo "[WARN] 未从 Nginx 配置中提取到 server_name"
    exit 0
fi


# =========================================================
# 逐个域名查询 A / AAAA 记录
# =========================================================

DOMAIN_COUNT=0

while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue

    # 清理回车符和前后空格
    domain="$(printf '%s' "$domain" | tr -d '\r' | xargs)"
    [[ -z "$domain" ]] && continue


    # -------------------------
    # 跳过通配符域名
    # -------------------------

    if [[ "$domain" == *"*"* ]]; then
        echo "[SKIP] $domain"
        echo "    原因：通配符域名，无法直接进行精确 DNS 比对"
        echo

        SKIP_DOMAINS+=("$domain")
        continue
    fi


    # -------------------------
    # 过滤异常域名
    # -------------------------

    if ! printf '%s' "$domain" | grep -Eq '^[A-Za-z0-9._-]+$'; then
        echo "[SKIP] $domain"
        echo "    原因：域名格式异常"
        echo

        SKIP_DOMAINS+=("$domain")
        continue
    fi


    DOMAIN_COUNT=$((DOMAIN_COUNT + 1))


    # -------------------------
    # 查询 IPv4 A 记录
    # -------------------------

    IPV4_RECORDS=$(
        dig \
            +short \
            A \
            "$domain" \
            @"$DNS_SERVER" \
            2>/dev/null \
        | awk '
            /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
                print
            }
        ' \
        | sort -u
    )


    # -------------------------
    # 查询 IPv6 AAAA 记录
    # -------------------------

    IPV6_RECORDS=$(
        dig \
            +short \
            AAAA \
            "$domain" \
            @"$DNS_SERVER" \
            2>/dev/null \
        | awk '
            /^[0-9A-Fa-f:]+$/ && /:/ {
                print
            }
        ' \
        | sort -u
    )


    # -------------------------
    # 判断 IPv4 是否匹配
    # -------------------------

    IPV4_MATCH=0

    if [[ -n "$IPV4_RECORDS" ]]; then
        while IFS= read -r resolved_ip; do
            [[ -z "$resolved_ip" ]] && continue

            if contains_value "$resolved_ip" "${DETECTED_IPV4[@]}"; then
                IPV4_MATCH=1
                break
            fi
        done <<< "$IPV4_RECORDS"
    fi


    # -------------------------
    # 判断 IPv6 是否匹配
    # -------------------------

    IPV6_MATCH=0

    if [[ -n "$IPV6_RECORDS" ]]; then
        while IFS= read -r resolved_ip; do
            [[ -z "$resolved_ip" ]] && continue

            if contains_value "$resolved_ip" "${DETECTED_IPV6[@]}"; then
                IPV6_MATCH=1
                break
            fi
        done <<< "$IPV6_RECORDS"
    fi


    # -------------------------
    # 生成 IPv4 状态
    # -------------------------

    if [[ -z "$IPV4_RECORDS" ]]; then
        IPV4_STATUS="无 A 记录"
    elif [[ "$IPV4_MATCH" -eq 1 ]]; then
        IPV4_STATUS="匹配当前服务器公网 IPv4"
    else
        IPV4_STATUS="不匹配当前服务器公网 IPv4"
    fi


    # -------------------------
    # 生成 IPv6 状态
    # -------------------------

    if [[ -z "$IPV6_RECORDS" ]]; then
        IPV6_STATUS="无 AAAA 记录"
    elif [[ "$IPV6_MATCH" -eq 1 ]]; then
        IPV6_STATUS="匹配当前服务器公网 IPv6"
    else
        IPV6_STATUS="不匹配当前服务器公网 IPv6"
    fi


    # -------------------------
    # 判断域名总体状态
    #
    # OK：
    #   有解析记录，并且所有存在的记录都匹配
    #
    # WARN：
    #   至少有一个记录匹配，但还有记录不匹配
    #
    # FAIL：
    #   没有解析记录，或者所有记录都不匹配
    # -------------------------

    HAS_DNS_RECORD=0
    HAS_MATCH=0
    HAS_MISMATCH=0

    if [[ -n "$IPV4_RECORDS" ]]; then
        HAS_DNS_RECORD=1

        if [[ "$IPV4_MATCH" -eq 1 ]]; then
            HAS_MATCH=1
        else
            HAS_MISMATCH=1
        fi
    fi

    if [[ -n "$IPV6_RECORDS" ]]; then
        HAS_DNS_RECORD=1

        if [[ "$IPV6_MATCH" -eq 1 ]]; then
            HAS_MATCH=1
        else
            HAS_MISMATCH=1
        fi
    fi


    if [[ "$HAS_DNS_RECORD" -eq 0 ]]; then
        DOMAIN_STATUS="FAIL"
        FAIL_DOMAINS+=("$domain")
    elif [[ "$HAS_MISMATCH" -eq 0 ]]; then
        DOMAIN_STATUS="OK"
        OK_DOMAINS+=("$domain")
    elif [[ "$HAS_MATCH" -eq 1 ]]; then
        DOMAIN_STATUS="WARN"
        WARN_DOMAINS+=("$domain")
    else
        DOMAIN_STATUS="FAIL"
        FAIL_DOMAINS+=("$domain")
    fi


    # =====================================================
    # 输出当前域名完整结果
    # =====================================================

    echo
    echo "--------------------------------------------------------"
    echo "[$DOMAIN_STATUS] $domain"
    echo "--------------------------------------------------------"

    echo "  IPv4 A 记录："
    print_records "$IPV4_RECORDS"
    echo "  IPv4 状态：$IPV4_STATUS"

    echo

    echo "  IPv6 AAAA 记录："
    print_records "$IPV6_RECORDS"
    echo "  IPv6 状态：$IPV6_STATUS"

done <<< "$DOMAIN_LIST"


# =========================================================
# 最终汇总
# =========================================================

echo
echo "========================================================"
echo "                    最终检测报告"
echo "========================================================"

echo
echo "[OK] IPv4 / IPv6 解析均匹配：${#OK_DOMAINS[@]} 个"
print_domain_list "${OK_DOMAINS[@]}"

echo
echo "[WARN] 部分解析匹配、部分解析不匹配：${#WARN_DOMAINS[@]} 个"
print_domain_list "${WARN_DOMAINS[@]}"

echo
echo "[FAIL] 没有任何解析匹配或无解析：${#FAIL_DOMAINS[@]} 个"
print_domain_list "${FAIL_DOMAINS[@]}"

echo
echo "[SKIP] 跳过检查：${#SKIP_DOMAINS[@]} 个"
print_domain_list "${SKIP_DOMAINS[@]}"

echo
echo "========================================================"
echo "[INFO] 共检查域名：$DOMAIN_COUNT 个"
echo "[INFO] DNS 查询服务器：$DNS_SERVER"
echo "[INFO] 公网 IP 查询服务：$PUBLIC_IP_SERVICE"
echo "[INFO] 检测完成"
echo "========================================================"
