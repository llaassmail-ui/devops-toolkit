#!/usr/bin/env bash

# =========================================================
# Nginx 域名 IPv4 / IPv6 解析检查脚本
#
# 功能：
# 1. 探测服务器各个本地 IPv4 对应的公网 IPv4
# 2. 探测服务器各个本地 IPv6 对应的公网 IPv6
# 3. 从 nginx -T 中提取 server_name
# 4. 分别查询域名的 A 和 AAAA 记录
# 5. 判断域名 IPv4 / IPv6 是否指向当前服务器
# 6. 输出完整检查报告
#
# 适用：
# Rocky Linux / CentOS / RHEL / Debian / Ubuntu
# =========================================================

set -o pipefail

# ================= 配置区 =================

# Nginx 命令路径。
#
# 如果 nginx 可以直接执行：
# NGINX_BIN="nginx"
#
# 如果是源码安装：
# NGINX_BIN="/usr/local/nginx/sbin/nginx"
#
# 也可以运行脚本时临时指定：
# NGINX_BIN=/usr/local/nginx/sbin/nginx bash nginx_domain_check.sh
NGINX_BIN="${NGINX_BIN:-nginx}"

# curl 连接超时时间，单位：秒
TIMEOUT="${TIMEOUT:-3}"

# 获取公网 IP 的服务
PUBLIC_IP_SERVICE="${PUBLIC_IP_SERVICE:-https://ifconfig.me}"

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
    if [[ "$#" -eq 0 ]]; then
        echo "  无"
        return
    fi

    local item

    for item in "$@"; do
        echo "  $item"
    done
}


# =========================================================
# 检查依赖命令
# =========================================================

REQUIRED_COMMANDS=(
    ip
    curl
    nginx
    getent
    awk
    sed
    grep
    sort
    tr
    xargs
)

for command_name in "${REQUIRED_COMMANDS[@]}"; do
    if [[ "$command_name" == "nginx" ]]; then
        if ! command -v "$NGINX_BIN" >/dev/null 2>&1; then
            die "找不到 Nginx 命令：$NGINX_BIN"
        fi
    else
        if ! command -v "$command_name" >/dev/null 2>&1; then
            die "缺少命令：$command_name"
        fi
    fi
done


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
# 获取本机 IPv4 地址
# =========================================================

while IFS= read -r local_ip; do
    [[ -n "$local_ip" ]] && LOCAL_IPV4+=("$local_ip")
done < <(
    ip -o -4 addr show scope global 2>/dev/null \
        | awk '
            $2 !~ /^(lo|docker|veth|br-|virbr)/ {
                split($4, address, "/")
                print address[1]
            }
        ' \
        | sort -u
)


# =========================================================
# 获取本机全球 IPv6 地址
# =========================================================

while IFS= read -r local_ip; do
    [[ -n "$local_ip" ]] && LOCAL_IPV6+=("$local_ip")
done < <(
    ip -o -6 addr show scope global 2>/dev/null \
        | awk '
            $2 !~ /^(lo|docker|veth|br-|virbr)/ {
                split($4, address, "/")
                print address[1]
            }
        ' \
        | sort -u
)


# =========================================================
# 探测公网 IPv4
# =========================================================

echo "[INFO] 正在探测服务器公网 IPv4 / IPv6..."
echo

if [[ "${#LOCAL_IPV4[@]}" -eq 0 ]]; then
    echo "[INFO] 未检测到可用的全球 IPv4 地址"
else
    for local_ip in "${LOCAL_IPV4[@]}"; do
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
fi


# =========================================================
# 探测公网 IPv6
# =========================================================

if [[ "${#LOCAL_IPV6[@]}" -eq 0 ]]; then
    echo "[INFO] 未检测到全球单播 IPv6 地址，已跳过 IPv6 检测"
else
    for local_ip in "${LOCAL_IPV6[@]}"; do
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

            printf '[IPv6] 本地地址 %-40s -> 公网地址 %s\n' \
                "$local_ip" \
                "$public_ip"
        else
            printf '[IPv6] 本地地址 %-40s -> 获取公网地址失败\n' \
                "$local_ip"
        fi
    done
fi


echo

if [[ "${#DETECTED_IPV4[@]}" -eq 0 && "${#DETECTED_IPV6[@]}" -eq 0 ]]; then
    die "无法获取任何公网 IP，请检查网络、默认路由或公网 IP 查询服务"
fi


# =========================================================
# 输出探测到的公网 IPv4
# =========================================================

echo "[INFO] 当前检测到的公网 IPv4："

if [[ "${#DETECTED_IPV4[@]}" -eq 0 ]]; then
    echo "  无"
else
    for public_ip in "${DETECTED_IPV4[@]}"; do
        echo "  $public_ip"
    done
fi


echo

# =========================================================
# 输出探测到的公网 IPv6
# =========================================================

echo "[INFO] 当前检测到的公网 IPv6："

if [[ "${#DETECTED_IPV6[@]}" -eq 0 ]]; then
    echo "  无"
else
    for public_ip in "${DETECTED_IPV6[@]}"; do
        echo "  $public_ip"
    done
fi


# =========================================================
# 读取 Nginx 配置
# =========================================================

echo
echo "========================================================"
echo "[INFO] 正在读取 Nginx 配置并提取 server_name..."
echo "========================================================"

NGINX_CONFIG=""

# 重点：
# nginx -T 会把配置内容输出到 stderr。
# 必须使用 2>&1，不能使用 2>/dev/null。
if ! NGINX_CONFIG="$("$NGINX_BIN" -T 2>&1)"; then
    echo "$NGINX_CONFIG"
    die "Nginx 配置读取失败，请执行：$NGINX_BIN -t"
fi


# =========================================================
# 提取 Nginx server_name
# =========================================================

DOMAIN_LIST=$(
    printf '%s\n' "$NGINX_CONFIG" \
        | tr -d '\r' \
        | awk '
            # 跳过注释行
            /^[[:space:]]*#/ {
                next
            }

            # 只处理真正的 server_name 指令
            /^[[:space:]]*server_name[[:space:]]+/ {
                line = $0

                # 删除行首的 server_name
                sub(/^[[:space:]]*server_name[[:space:]]+/, "", line)

                # 删除行尾分号及其后内容
                sub(/[;].*$/, "", line)

                # 删除大括号
                gsub(/[{}]/, "", line)

                # 删除行内注释
                sub(/[[:space:]]*#.*/, "", line)

                # 按空格拆分多个域名
                count = split(line, names, /[[:space:]]+/)

                for (i = 1; i <= count; i++) {
                    domain = names[i]

                    # 清理前后空白
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", domain)

                    # 过滤空值、通配符、变量和无效内容
                    if (domain == "") {
                        continue
                    }

                    if (domain ~ /\*/) {
                        continue
                    }

                    if (domain ~ /^\$/) {
                        continue
                    }

                    if (domain == "localhost" ||
                        domain == "on" ||
                        domain == "off" ||
                        domain == "_") {
                        continue
                    }

                    if (domain ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                        continue
                    }

                    # 只保留普通域名、子域名和带连字符的域名
                    if (domain ~ /^[A-Za-z0-9._-]+$/) {
                        print domain
                    }
                }
            }
        ' \
        | sort -u
)

if [[ -z "$DOMAIN_LIST" ]]; then
    echo "[WARN] 未从 Nginx 配置中提取到有效的 server_name"
    echo
    echo "[INFO] 可以手动检查 Nginx 配置："
    echo "       $NGINX_BIN -T 2>&1 | grep -n server_name"
    exit 0
fi


# =========================================================
# 逐个域名查询 IPv4 / IPv6
# =========================================================

DOMAIN_COUNT=0

while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue

    # 清理回车符、前后空格
    domain="$(printf '%s' "$domain" | tr -d '\r' | xargs)"
    [[ -z "$domain" ]] && continue


    # -----------------------------------------------------
    # 跳过通配符域名
    # -----------------------------------------------------

    if [[ "$domain" == *"*"* ]]; then
        echo
        echo "[SKIP] $domain"
        echo "  原因：通配符域名，跳过精确 DNS 比对"

        SKIP_DOMAINS+=("$domain")
        continue
    fi


    # -----------------------------------------------------
    # 过滤异常内容
    # -----------------------------------------------------

    if ! printf '%s' "$domain" | grep -Eq '^[A-Za-z0-9._-]+$'; then
        echo
        echo "[SKIP] $domain"
        echo "  原因：域名格式异常"

        SKIP_DOMAINS+=("$domain")
        continue
    fi


    DOMAIN_COUNT=$((DOMAIN_COUNT + 1))


    # -----------------------------------------------------
    # 查询 IPv4 A 记录
    #
    # ahostsv4 只查询 IPv4，避免和 IPv6 混在一起。
    # -----------------------------------------------------

    IPV4_RECORDS=$(
        getent ahostsv4 "$domain" 2>/dev/null \
            | awk '{print $1}' \
            | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
            | sort -u
    )


    # -----------------------------------------------------
    # 查询 IPv6 AAAA 记录
    # -----------------------------------------------------

    IPV6_RECORDS=$(
        getent ahostsv6 "$domain" 2>/dev/null \
            | awk '{print $1}' \
            | grep ':' \
            | sort -u
    )


    # -----------------------------------------------------
    # 判断 IPv4 是否匹配
    # -----------------------------------------------------

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


    # -----------------------------------------------------
    # 判断 IPv6 是否匹配
    # -----------------------------------------------------

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


    # -----------------------------------------------------
    # 生成 IPv4 状态
    # -----------------------------------------------------

    if [[ -z "$IPV4_RECORDS" ]]; then
        IPV4_STATUS="无 A 记录"
    elif [[ "$IPV4_MATCH" -eq 1 ]]; then
        IPV4_STATUS="匹配当前服务器公网 IPv4"
    else
        IPV4_STATUS="不匹配当前服务器公网 IPv4"
    fi


    # -----------------------------------------------------
    # 生成 IPv6 状态
    # -----------------------------------------------------

    if [[ -z "$IPV6_RECORDS" ]]; then
        IPV6_STATUS="无 AAAA 记录"
    elif [[ "$IPV6_MATCH" -eq 1 ]]; then
        IPV6_STATUS="匹配当前服务器公网 IPv6"
    else
        IPV6_STATUS="不匹配当前服务器公网 IPv6"
    fi


    # -----------------------------------------------------
    # 判断域名总体状态
    #
    # OK：
    #   存在的 DNS 记录全部匹配。
    #
    # WARN：
    #   至少一个记录匹配，但还有记录不匹配。
    #
    # FAIL：
    #   没有任何 DNS 记录，或者所有记录都不匹配。
    # -----------------------------------------------------

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
    # 输出当前域名结果
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
echo "[OK] 所有存在的 DNS 记录均匹配：${#OK_DOMAINS[@]} 个"
print_domain_list "${OK_DOMAINS[@]}"

echo
echo "[WARN] 部分 DNS 记录匹配、部分不匹配：${#WARN_DOMAINS[@]} 个"
print_domain_list "${WARN_DOMAINS[@]}"

echo
echo "[FAIL] 无解析或全部不匹配：${#FAIL_DOMAINS[@]} 个"
print_domain_list "${FAIL_DOMAINS[@]}"

echo
echo "[SKIP] 跳过检查：${#SKIP_DOMAINS[@]} 个"
print_domain_list "${SKIP_DOMAINS[@]}"

echo
echo "========================================================"
echo "[INFO] 共检查域名：$DOMAIN_COUNT 个"
echo "[INFO] 公网 IP 查询服务：$PUBLIC_IP_SERVICE"
echo "[INFO] DNS 查询方式：服务器当前配置的 DNS"
echo "[INFO] 检测完成"
echo "========================================================"
