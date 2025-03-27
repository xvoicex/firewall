#!/bin/bash

# 检查是否提供了参数
if [ $# -eq 0 ]; then
    echo "使用方法: $0 <配置文件名>"
    exit 1
fi

FILE_NAME="$1"
CONFIG_FILE="$(pwd)/${FILE_NAME}"

echo "正在检查文件: $CONFIG_FILE"

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件不存在: $CONFIG_FILE"
    exit 1
fi

echo "找到配置文件，开始处理..."

# 创建临时文件用于存储新配置
TEMP_FILE=$(mktemp)

# 要检查的配置项及其值
declare -A configs=(
    ["max_connections"]="150"
    ["max_connect_errors"]="10000"
    ["wait_timeout"]="600"
    ["interactive_timeout"]="600"
    ["innodb_buffer_pool_size"]="2G"
    ["innodb_log_file_size"]="256M"
    ["innodb_log_buffer_size"]="8M"
    ["innodb_flush_log_at_trx_commit"]="2"
    ["innodb_flush_method"]="O_DIRECT"
    ["innodb_file_per_table"]="1"
    ["tmp_table_size"]="32M"
    ["max_heap_table_size"]="32M"
    ["table_open_cache"]="400"
    ["thread_cache_size"]="8"
    ["key_buffer_size"]="256M"
    ["slow_query_log"]="1"
    ["slow_query_log_file"]="/var/log/mysql/mysql-slow.log"
    ["long_query_time"]="2"
    ["innodb_read_io_threads"]="4"
    ["innodb_write_io_threads"]="4"
    ["innodb_io_capacity"]="2000"
    ["innodb_io_capacity_max"]="4000"
    ["innodb_lock_wait_timeout"]="50"
    ["innodb_print_all_deadlocks"]="1"
    ["sort_buffer_size"]="2M"
    ["read_buffer_size"]="2M"
    ["read_rnd_buffer_size"]="1M"
    ["join_buffer_size"]="1M"
    ["character-set-server"]="utf8mb4"
    ["collation-server"]="utf8mb4_general_ci"
)

# 创建关联数组来跟踪已存在的配置
declare -A existing_configs

# 首先读取现有配置文件，记录已存在的配置项
while IFS= read -r line; do
    # 跳过注释和空行
    if [[ $line =~ ^[[:space:]]*# ]] || [[ -z $line ]]; then
        echo "$line" >> "$TEMP_FILE"
        continue
    fi
    
    # 检查每个配置项
    for key in "${!configs[@]}"; do
        if [[ $line =~ ^[[:space:]]*$key[[:space:]]*= ]]; then
            existing_configs[$key]=1
            echo "$line" >> "$TEMP_FILE"
            break
        fi
    done
    
    # 如果行不匹配任何配置项，直接写入
    if [[ ! $line =~ ^[[:space:]]*[a-zA-Z_-]+[[:space:]]*= ]]; then
        echo "$line" >> "$TEMP_FILE"
    fi
done < "$CONFIG_FILE"

# 添加缺失的配置项
echo "" >> "$TEMP_FILE"  # 添加空行
echo "# 自动添加的配置项" >> "$TEMP_FILE"

for key in "${!configs[@]}"; do
    if [ -z "${existing_configs[$key]}" ]; then
        echo "$key = ${configs[$key]}" >> "$TEMP_FILE"
    fi
done

# 备份原配置文件
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"

# 将新配置写入原文件
mv "$TEMP_FILE" "$CONFIG_FILE"

# 设置正确的权限
chown mysql:mysql "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

echo "配置文件已更新，原文件已备份"
