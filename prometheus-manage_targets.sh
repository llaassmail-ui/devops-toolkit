#!/bin/bash

# ==========================================================
# Prometheus Targets 交互式管理工具
# ==========================================================

# 默认配置文件路径 (可通过 export TARGET_FILE="xxx" 覆盖)
TARGET_FILE=${TARGET_FILE:-"/data_disk1/server/docker/prometheus/master/etc/targets.json"}

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 检查 jq 命令
if ! command -v jq &> /dev/null; then
    echo -e "${RED}错误: 未找到 'jq' 命令，请先安装 (yum/apt install jq)${NC}"
    exit 1
fi

# 初始化文件
init_file() {
    if [ ! -f "$TARGET_FILE" ]; then
        mkdir -p "$(dirname "$TARGET_FILE")"
        echo "[]" > "$TARGET_FILE"
        echo -e "${YELLOW}已创建新配置文件: $TARGET_FILE${NC}"
    fi
}

# 打印横线
print_line() {
    echo -e "${YELLOW}--------------------------------------------------${NC}"
}

# --- 功能函数 ---

# 1. 列出当前所有 Targets
list_targets() {
    print_line
    echo -e "当前监控任务列表:"
    printf "%-30s | %-20s\n" "Job Name (任务名)" "Targets (地址)"
    echo "--------------------------------------------------"
    
    # 提取数据并格式化输出
    count=$(jq '. | length' "$TARGET_FILE")
    if [ "$count" -eq 0 ]; then
        echo -e "${RED}  (列表为空)${NC}"
    else
        jq -r '.[] | "\(.labels.job) \(.targets | join(","))"' "$TARGET_FILE" | while read -r job target; do
            printf "%-30s | %-20s\n" "$job" "$target"
        done
    fi
    print_line
}

# 2. 添加或修改 Target
add_target() {
    read -p "请输入 Job 名称 (例如: My_Service): " job_name
    if [[ -z "$job_name" ]]; then echo "不能为空"; return; fi
    
    read -p "请输入 IP:Port (例如: 1.1.1.1:20003): " target_addr
    if [[ -z "$target_addr" ]]; then echo "不能为空"; return; fi

    # 如果 Job 已存在，先删除旧的
    tmp_json=$(jq --arg job "$job_name" --arg target "$target_addr" \
        'del(.[] | select(.labels.job == $job)) | . += [{"targets": [$target], "labels": {"job": $job}}]' \
        "$TARGET_FILE")
    
    echo "$tmp_json" > "$TARGET_FILE"
    echo -e "${GREEN}成功: 已添加/更新任务 [$job_name]${NC}"
}

# 3. 删除 Target
delete_target() {
    read -p "请输入要删除的 Job 名称: " job_name
    if [[ -z "$job_name" ]]; then return; fi

    # 检查是否存在
    exists=$(jq --arg job "$job_name" 'any(.[] ; .labels.job == $job)' "$TARGET_FILE")
    if [ "$exists" == "false" ]; then
        echo -e "${RED}错误: 未找到名为 [$job_name] 的任务${NC}"
        return
    fi

    tmp_json=$(jq --arg job "$job_name" 'del(.[] | select(.labels.job == $job))' "$TARGET_FILE")
    echo "$tmp_json" > "$TARGET_FILE"
    echo -e "${GREEN}成功: 已删除任务 [$job_name]${NC}"
}

# --- 主循环菜单 ---

init_file

while true; do
    echo -e "\n${GREEN}=== Prometheus Targets 管理系统 ===${NC}"
    echo "1) 列出所有监控点 (List)"
    echo "2) 添加/修改监控点 (Add/Update)"
    echo "3) 删除监控点 (Delete)"
    echo "4) 查看原始 JSON (Show Raw)"
    echo "q) 退出 (Quit)"
    read -p "请选择操作 [1-4/q]: " choice

    case $choice in
        1)
            list_targets
            ;;
        2)
            add_target
            ;;
        3)
            delete_target
            ;;
        4)
            jq . "$TARGET_FILE"
            ;;
        q|Q)
            echo "退出程序。"
            exit 0
            ;;
        *)
            echo -e "${RED}输入错误，请重试。${NC}"
            ;;
    esac
done
