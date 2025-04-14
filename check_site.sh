#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then 
    echo "请使用root权限运行此脚本"
    exit 1
fi

# MySQL登录函数
mysql_login() {
    read -sp "请输入MySQL密码（直接回车表示无密码）: " mysql_pwd
    echo
    if [ -z "$mysql_pwd" ]; then
        MYSQL_CMD="mysql -u root"
    else
        MYSQL_CMD="mysql -u root -p${mysql_pwd}"
    fi

    # 测试MySQL连接
    if ! $MYSQL_CMD -e "SELECT 1" >/dev/null 2>&1; then
        echo "MySQL连接失败，请检查密码"
        exit 1
    fi
}

# 获取所有MySQL数据库（排除系统数据库）
get_mysql_dbs() {
    $MYSQL_CMD -N -e "SHOW DATABASES" | grep -Ev '^(information_schema|performance_schema|mysql|sys)$'
}

# 获取数据库大小的函数
get_db_size() {
    local db=$1
    local size=$($MYSQL_CMD -N -e "
        SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2)
        FROM information_schema.tables
        WHERE table_schema = '$db'
        GROUP BY table_schema")
    if [ -z "$size" ]; then
        echo "0.00"
    else
        echo "$size"
    fi
}

# 获取nginx配置文件中的域名
get_domain_names() {
    local conf_file=$1
    local domains=$(grep -i "server_name" "$conf_file" | sed 's/server_name//gi' | sed 's/;//g' | tr -d ';' | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    if [ -z "$domains" ]; then
        echo "无域名配置"
    else
        echo "$domains"
    fi
}

# 获取nginx配置文件中的日志路径
get_log_paths() {
    local conf_file=$1
    local access_log=$(grep -i "access_log" "$conf_file" | grep -v '#' | head -1 | awk '{print $2}' | sed 's/;//')
    local error_log=$(grep -i "error_log" "$conf_file" | grep -v '#' | head -1 | awk '{print $2}' | sed 's/;//')
    echo "$access_log|$error_log"
}

# 检查日志文件是否存在
check_log_exists() {
    local log_file=$1
    if [ -z "$log_file" ]; then
        echo "${RED}未配置${NC}"
    elif [ -f "$log_file" ]; then
        local size=$(du -h "$log_file" 2>/dev/null | cut -f1)
        echo "${GREEN}存在${NC} (${YELLOW}大小: $size${NC})"
    else
        echo "${RED}配置文件中指定但实际不存在${NC}"
    fi
}

# 主程序开始
echo "正在进行站点配置检查..."
mysql_login

# 获取各种数据
echo -e "\n正在收集数据..."
mysql_dbs=$(get_mysql_dbs)
www_dirs=$(ls /var/www 2>/dev/null)
nginx_configs=$(ls /etc/nginx/sites-enabled/*.conf 2>/dev/null)

echo -e "\n${GREEN}=== 分析结果 ===${NC}"

# [前面的代码保持不变，直到"nginx日志检查"部分]

# Nginx日志路径检查
echo -e "\n${GREEN}=== Nginx日志配置检查 ===${NC}"
for conf in $nginx_configs; do
    site=$(basename "$conf" .conf)
    echo -e "\n${YELLOW}站点: $site${NC}"
    
    # 获取配置文件中的日志路径
    log_paths=$(get_log_paths "$conf")
    access_log=$(echo "$log_paths" | cut -d'|' -f1)
    error_log=$(echo "$log_paths" | cut -d'|' -f2)
    
    # 显示access_log状态
    echo -n "  访问日志 (access_log): "
    if [ -z "$access_log" ]; then
        echo "${RED}未配置${NC}"
    else
        echo -n "$access_log - "
        check_log_exists "$access_log"
    fi
    
    # 显示error_log状态
    echo -n "  错误日志 (error_log):  "
    if [ -z "$error_log" ]; then
        echo "${RED}未配置${NC}"
    else
        echo -n "$error_log - "
        check_log_exists "$error_log"
    fi
done

# 检查/var/log/nginx/下的孤立日志文件
echo -e "\n${GREEN}=== 孤立的Nginx日志文件 ===${NC}"
for log_file in /var/log/nginx/*.{access,error}.log; do
    if [ -f "$log_file" ]; then
        log_name=$(basename "$log_file")
        site_name=$(echo "$log_name" | sed 's/\.\(access\|error\)\.log$//')
        
        # 检查是否存在对应的nginx配置
        found=0
        for conf in $nginx_configs; do
            log_paths=$(get_log_paths "$conf")
            if echo "$log_paths" | grep -q "$log_file"; then
                found=1
                break
            fi
        done
        
        if [ $found -eq 0 ]; then
            size=$(du -h "$log_file" | cut -f1)
            echo -e "  - $log_file ${YELLOW}(大小: $size)${NC} - ${RED}无对应配置文件${NC}"
        fi
    fi
done

# 7. 统计信息
echo -e "\n${GREEN}=== 统计信息 ===${NC}"
echo "数据库总数: $(echo "$mysql_dbs" | wc -l)"
echo "www目录总数: $(echo "$www_dirs" | wc -l)"
echo "nginx配置文件总数: $(echo "$nginx_configs" | wc -l)"
echo "nginx日志文件站点数: $(echo "$nginx_logs" | wc -l)"

# 检查磁盘使用情况
echo -e "\n${GREEN}=== 磁盘使用情况 ===${NC}"
echo "日志目录大小:"
du -sh /var/log/nginx 2>/dev/null
echo "网站目录大小:"
du -sh /var/www 2>/dev/null
