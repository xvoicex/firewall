#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用root权限运行此脚本${NC}"
    exit 1
fi

install_packages() {
    # 检查是否已安装所需软件
    local packages_to_install=()
    
    # 检查fail2ban
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        packages_to_install+=("fail2ban")
    fi
    
    # 检查ufw
    if ! command -v ufw >/dev/null 2>&1; then
        packages_to_install+=("ufw")
    fi
    
    # 检查jq
    if ! command -v jq >/dev/null 2>&1; then
        packages_to_install+=("jq")
    fi
    
    # 如果所有软件都已安装，直接返回
    if [ ${#packages_to_install[@]} -eq 0 ]; then
        echo -e "${GREEN}所有必需的软件包已安装${NC}"
        return 0
    fi
    
    # 根据系统类型安装缺失的软件包
    if command -v apt-get >/dev/null 2>&1; then
        echo -e "${GREEN}使用apt安装缺失的软件包: ${packages_to_install[*]}${NC}"
        apt-get update
        apt-get install -y "${packages_to_install[@]}"
    elif command -v yum >/dev/null 2>&1; then
        echo -e "${GREEN}使用yum安装缺失的软件包: ${packages_to_install[*]}${NC}"
        yum install -y epel-release
        yum install -y "${packages_to_install[@]}"
    else
        echo -e "${RED}不支持的系统类型${NC}"
        exit 1
    fi
}

# 配置UFW
configure_ufw() {
    # 检查UFW是否已安装
    if ! command -v ufw >/dev/null 2>&1; then
        echo -e "${RED}UFW未安装，请先安装UFW${NC}"
        return 1
	fi
    
    
    # 重置UFW规则
    echo -e "${GREEN}重置UFW规则...${NC}"
    ufw --force reset
    
    # 启用UFW
    echo -e "${GREEN}启用UFW...${NC}"
    ufw --force enable
    
    # 默认规则：拒绝入站，允许出站
    ufw default deny incoming
    ufw default allow outgoing
    
    # 允许SSH（如果正在使用）
    if netstat -tuln | grep ":22 " >/dev/null; then
        ufw allow 22/tcp comment 'SSH'
    fi
    
    # 获取所有非本地监听端口
    echo -e "${GREEN}配置防火墙规则...${NC}"
    PORTS=$(ss -tulpn | grep LISTEN | grep -v "127.0.0.1" | grep -v "::1" | awk '{print $5}' | awk -F: '{print $NF}' | sort -u)
    
    # 为每个外部端口添加规则
    for PORT in $PORTS; do
        # 检查端口是否为数字
        if [[ $PORT =~ ^[0-9]+$ ]]; then
            # 检查是TCP还是UDP
            if ss -tulpn | grep ":$PORT " | grep "tcp" >/dev/null; then
                ufw allow $PORT/tcp comment "Port $PORT TCP"
            fi
            if ss -tulpn | grep ":$PORT " | grep "udp" >/dev/null; then
                ufw allow $PORT/udp comment "Port $PORT UDP"
            fi
        fi
    done
    
    # 显示当前规则
    echo -e "${GREEN}当前UFW规则:${NC}"
    ufw status numbered
}

# 创建fail2ban过滤器配置
create_filters() {
    # nginx-cc.conf
    cat > /etc/fail2ban/filter.d/nginx-cc.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*HTTP.*" (?:404|444|403|400|429) .*$
ignoreregex =
EOF

    # nginx-scan.conf 修改这里，增加%的转义
    cat > /etc/fail2ban/filter.d/nginx-scan.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* ".*(?:\.\.\/|\/etc\/|\/usr\/|_\/|\.\.\.\/|%%00|\\x00).*" (?:404|403|400) .*$
ignoreregex =
EOF

    # nginx-req-limit.conf
    cat > /etc/fail2ban/filter.d/nginx-req-limit.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*HTTP.*" (?:404|444|403|400|429|502) .*$
ignoreregex =
EOF

    # nginx-sql.conf
    cat > /etc/fail2ban/filter.d/nginx-sql.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* ".*(?:union.*select|concat.*\(|information_schema|load_file).*" (?:404|403|400) .*$
ignoreregex =
EOF

    # nginx-xss.conf
    cat > /etc/fail2ban/filter.d/nginx-xss.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* ".*(?:script>|<script|alert\().*" (?:404|403|400) .*$
ignoreregex =
EOF

    # nginx-login.conf
    cat > /etc/fail2ban/filter.d/nginx-login.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* "(POST).*/(?:login|admin|wp-login).*" (?:404|403|400|401) .*$
ignoreregex =
EOF

    # nginx-crawler.conf
    cat > /etc/fail2ban/filter.d/nginx-crawler.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* "(?:Wget|curl|python-requests|Go-http-client|zgrab|Nmap|masscan).*" .*$
ignoreregex =
EOF

    # nginx-cca.conf
    cat > /etc/fail2ban/filter.d/nginx-cca.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*- .*HTTP/1.* .* .*$
ignoreregex =
EOF

    # nginx-scana.conf
    cat > /etc/fail2ban/filter.d/nginx-scana.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.* /var/www/* HTTP/1\..
ignoreregex =
EOF

    # ufw-comment.conf
    cat > /etc/fail2ban/action.d/ufw-comment.conf << 'EOF'
[Definition]
actionstart = 
actionstop = 
actioncheck = 

actionban = ufw insert 1 deny from <ip> to any port <port> proto <protocol> comment 'fail2ban: <name> - banned on <datetime>' && /usr/local/bin/fail2ban-notify.sh <ip> <name> "封禁"
            
actionunban = ufw delete deny from <ip> to any port <port> proto <protocol> && /usr/local/bin/fail2ban-notify.sh <ip> <name> "解封" 

[Init]
EOF
}

# 创建基础jail.local配置
create_base_jail() {
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 15
banaction = ufw-comment
banaction_allports = ufw-comment

#sshd-START
[sshd]
enabled = true
filter = sshd
port = 22
maxretry = 5
findtime = 300
bantime = 86400
action = %(action_mwl)s
logpath = /var/log/auth.log
#sshd-END
EOF
}

# 添加站点配置
add_site_config() {
    local site_prefix=$1
    local access_log="/var/log/nginx/${site_prefix}.access.log"
    local error_log="/var/log/nginx/${site_prefix}.error.log"
    
    if [ ! -f "$access_log" ] && [ ! -f "$error_log" ]; then
        echo -e "${RED}找不到站点 ${site_prefix} 的日志文件${NC}"
        return 1
    fi

    echo -e "\n#${site_prefix}_start" >> /etc/fail2ban/jail.local
    cat >> /etc/fail2ban/jail.local << EOF

[nginx-cc-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-cc
logpath = $access_log
maxretry = 60
findtime = 60

[nginx-scan-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-scan
logpath = $access_log
maxretry = 60
findtime = 300

[nginx-req-limit-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-req-limit
logpath = $access_log
maxretry = 60
findtime = 60

[nginx-sql-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-sql
logpath = $access_log
maxretry = 20
findtime = 600

[nginx-xss-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-xss
logpath = $access_log
maxretry = 20
findtime = 60

[nginx-login-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-login
logpath = $access_log
maxretry = 10
findtime = 10

[nginx-crawler-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-crawler
logpath = $access_log
maxretry = 3
findtime = 60

[nginx-cca-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-cca
logpath = $access_log
maxretry = 60
findtime = 60

[nginx-scana-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-scana
logpath = $access_log
maxretry = 60
findtime = 60
EOF
    echo "#${site_prefix}_end" >> /etc/fail2ban/jail.local
}

# 添加所有站点
add_all_sites() {
    create_base_jail
    for log_file in /var/log/nginx/*.access.log; do
        if [ -f "$log_file" ]; then
            site_prefix=$(basename "$log_file" .access.log)
            add_site_config "$site_prefix"
        fi
    done
    systemctl restart fail2ban
}

# 删除站点配置
remove_site() {
    local site_prefix=$1
    local temp_file=$(mktemp)
    sed "/#${site_prefix}_start/,/#${site_prefix}_end/d" /etc/fail2ban/jail.local > "$temp_file"
    mv "$temp_file" /etc/fail2ban/jail.local
    systemctl restart fail2ban
}

# 列出封禁的IP
list_banned_ips() {
    fail2ban-client status | grep "Jail list:" | sed "s/^.*:[ ]*//g" | tr ',' '\n' | while read -r jail; do
        if [ ! -z "$jail" ]; then
            echo -e "${GREEN}Jail: $jail${NC}"
            fail2ban-client status "$jail" | grep "Banned IP list:"
        fi
    done
}

# 解除IP封禁
unban_ip() {
    local ip=$1
    fail2ban-client unban "$ip"
    echo -e "${GREEN}已解除IP ${ip} 的封禁${NC}"
}

# 列出已配置的站点
list_configured_sites() {
    echo -e "${GREEN}已配置的站点:${NC}"
    grep -n "#.*_start" /etc/fail2ban/jail.local | cut -d'#' -f2 | cut -d'_' -f1
}

# 添加默认日志监控
add_default_logs() {
    local access_log="/var/log/nginx/access.log"
    local error_log="/var/log/nginx/error.log"
    
    # 检查日志文件是否存在
    if [ ! -f "$access_log" ]; then
        echo -e "${RED}默认访问日志文件 $access_log 不存在${NC}"
        return 1
    fi

    # 检查是否已经在监控中
    if grep -q "^logpath = $access_log" /etc/fail2ban/jail.local; then
        echo -e "${RED}默认日志已在监控列表中${NC}"
        return 1
    fi

    echo -e "\n#default_logs_start" >> /etc/fail2ban/jail.local
    cat >> /etc/fail2ban/jail.local << EOF

[nginx-cc-default]
enabled = true
port = 80,443
filter = nginx-cc
logpath = $access_log
maxretry = 60
findtime = 60

[nginx-scan-default]
enabled = true
port = 80,443
filter = nginx-scan
logpath = $access_log
maxretry = 60
findtime = 300

[nginx-req-limit-default]
enabled = true
port = 80,443
filter = nginx-req-limit
logpath = $access_log
maxretry = 60
findtime = 60

[nginx-sql-default]
enabled = true
port = 80,443
filter = nginx-sql
logpath = $access_log
maxretry = 20
findtime = 600

[nginx-xss-default]
enabled = true
port = 80,443
filter = nginx-xss
logpath = $access_log
maxretry = 20
findtime = 60

[nginx-login-default]
enabled = true
port = 80,443
filter = nginx-login
logpath = $access_log
maxretry = 10
findtime = 10

[nginx-crawler-default]
enabled = true
port = 80,443
filter = nginx-crawler
logpath = $access_log
maxretry = 3
findtime = 60

[nginx-cca-default]
enabled = true
port = 80,443
filter = nginx-cca
logpath = $access_log
maxretry = 60
findtime = 60

[nginx-scana-default]
enabled = true
port = 80,443
filter = nginx-scana
logpath = $access_log
maxretry = 60
findtime = 60
#default_logs_end
EOF

    # 重启 fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}已添加默认日志到监控列表并重启服务${NC}"
}

# 删除默认日志监控
remove_default_logs() {
    local temp_file=$(mktemp)
    
    # 检查是否在监控中
    if ! grep -q "#default_logs_start" /etc/fail2ban/jail.local; then
        echo -e "${RED}默认日志不在监控列表中${NC}"
        return 1
    fi
    
    # 删除配置
    sed "/#default_logs_start/,/#default_logs_end/d" /etc/fail2ban/jail.local > "$temp_file"
    mv "$temp_file" /etc/fail2ban/jail.local
    
    # 重启 fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}已从监控列表中移除默认日志并重启服务${NC}"
}

# 修改主菜单
show_menu() {
    echo -e "\n${GREEN}Fail2Ban 管理脚本${NC}"
    echo "1. 安装和配置 fail2ban/ufw/jq"
    echo "2. 添加所有站点"
    echo "3. 追加站点"
    echo "4. 删除站点"
    echo "5. 列出封禁的IP"
    echo "6. 解除IP封禁"
    echo "7. 列出已配置的站点"
    echo "8. 添加默认日志监控"
    echo "9. 删除默认日志监控"
    echo "0. 退出"
    echo -n "请选择: "
}

# 修改主程序的 case 语句
while true; do
    show_menu
    read -r choice
    case $choice in
        1)
            install_packages
            configure_ufw
            create_filters
            echo -e "${GREEN}安装和配置完成${NC}"
            ;;
        2)
            add_all_sites
            echo -e "${GREEN}所有站点已添加${NC}"
            ;;
        3)
            echo -n "请输入站点前缀: "
            read -r site_prefix
            add_site_config "$site_prefix"
            echo -e "${GREEN}站点 ${site_prefix} 已添加${NC}"
            ;;
        4)
            echo -n "请输入要删除的站点前缀: "
            read -r site_prefix
            remove_site "$site_prefix"
            echo -e "${GREEN}站点 ${site_prefix} 已删除${NC}"
            ;;
        5)
            list_banned_ips
            ;;
        6)
            echo -n "请输入要解封的IP: "
            read -r ip
            unban_ip "$ip"
            ;;
        7)
            list_configured_sites
            ;;
        8)
            add_default_logs
            ;;
        9)
            remove_default_logs
            ;;
        0)
            echo -e "${GREEN}再见！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            ;;
    esac
done
