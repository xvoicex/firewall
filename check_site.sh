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

# 主程序开始
echo "正在进行站点配置检查..."
mysql_login

# 获取各种数据
echo -e "\n正在收集数据..."
mysql_dbs=$(get_mysql_dbs)
www_dirs=$(ls /var/www 2>/dev/null)
nginx_configs=$(ls /etc/nginx/sites-enabled/*.conf 2>/dev/null)
nginx_logs=$(ls /var/log/nginx/*.{access,error}.log 2>/dev/null | sed 's/.*\///g' | sed 's/\.\(access\|error\)\.log$//' | sort -u)

echo -e "\n${GREEN}=== 分析结果 ===${NC}"

# 1. 检查存在数据库但没有对应www目录的站点
echo -e "\n${GREEN}1. 存在数据库但没有对应www目录的站点:${NC}"
for db in $mysql_dbs; do
    found=0
    for dir in $www_dirs; do
        if [[ "$dir" == "$db"* ]]; then
            found=1
            break
        fi
    done
    if [ $found -eq 0 ]; then
        size=$(get_db_size "$db")
        echo -e "  - $db ${YELLOW}(大小: ${size}MB)${NC}"
    fi
done

# 2. 检查存在nginx配置但没有对应数据库的站点
echo -e "\n${GREEN}2. 存在nginx配置但没有对应数据库的站点:${NC}"
for conf in $nginx_configs; do
    site=$(basename "$conf" .conf)
    if ! echo "$mysql_dbs" | grep -q "^${site}$"; then
        domains=$(get_domain_names "$conf")
        echo -e "  - $site ${YELLOW}(域名: $domains)${NC}"
    fi
done

# 3. 检查被重命名的www目录
echo -e "\n${GREEN}3. 被重命名的www目录:${NC}"
for dir in $www_dirs; do
    if [[ "$dir" =~ ^([^已备旧迁]+)(已|备份|旧|迁移).* ]]; then
        original_name="${BASH_REMATCH[1]}"
        echo "  - $dir (原站点名: $original_name)"
    fi
done

# 4. 检查存在日志但站点可能已不存在的情况
echo -e "\n${GREEN}4. 存在日志但站点可能已不存在:${NC}"
for log in $nginx_logs; do
    if ! echo "$nginx_configs" | grep -q "/${log}.conf" && ! echo "$mysql_dbs" | grep -q "^${log}$"; then
        echo "  - $log"
    fi
done

# 5. 数据库大小列表
echo -e "\n${GREEN}5. 所有数据库大小:${NC}"
for db in $mysql_dbs; do
    size=$(get_db_size "$db")
    echo -e "  - $db: ${YELLOW}${size}MB${NC}"
done

# 6. Nginx配置域名列表
echo -e "\n${GREEN}6. Nginx站点域名列表:${NC}"
for conf in $nginx_configs; do
    site=$(basename "$conf" .conf)
    domains=$(get_domain_names "$conf")
    echo -e "  - $site: ${YELLOW}$domains${NC}"
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
