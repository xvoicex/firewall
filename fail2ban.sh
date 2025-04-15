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

# 检测系统类型并安装软件
install_packages() {
    if [ -f /etc/debian_version ]; then
        apt update
        apt install -y fail2ban ufw jq
    elif [ -f /etc/redhat-release ]; then
        yum update
        yum install -y epel-release
        yum install -y fail2ban ufw jq
    else
        echo -e "${RED}不支持的系统类型${NC}"
        exit 1
    fi
}

# 配置UFW
configure_ufw() {
    # 检查并安装ss命令（如果需要）
    if ! command -v ss &> /dev/null; then
        if [ -f /etc/debian_version ]; then
            apt install -y iproute2
        elif [ -f /etc/redhat-release ]; then
            yum install -y iproute
        fi
    fi

    # 获取所有LISTEN状态的TCP端口
    echo "正在获取当前系统开放的端口..."
    local open_ports=$(ss -ltpn | awk 'NR>1 {gsub(/.*:/, "", $4); print $4}' | sort -nu)

    echo "检测到以下开放端口："
    for port in $open_ports; do
        echo "端口: $port"
    done

    # 确认是否配置这些端口
    read -p "是否要为这些端口配置UFW规则？(y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        ufw --force enable
        for port in $open_ports; do
            echo "允许端口 $port"
            ufw allow $port/tcp
        done
        echo -e "${GREEN}UFW规则配置完成${NC}"
    else
        echo "跳过UFW端口配置"
    fi

    # 显示UFW状态
    echo "当前UFW状态："
    ufw status numbered
}

# 创建fail2ban配置文件
create_fail2ban_configs() {
    # 创建filter配置
    local filter_dir="/etc/fail2ban/filter.d"
    local filters=(
        "nginx-cc"
        "nginx-scan"
        "nginx-req-limit"
        "nginx-sql"
        "nginx-xss"
        "nginx-login"
        "nginx-crawler"
        "nginx-custom1"
        "nginx-custom2"
    )

    # 创建各个filter文件
    for filter in "${filters[@]}"; do
        case $filter in
            "nginx-cc")
                cat > "$filter_dir/$filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*HTTP.*" (?:404|444|403|400|429) .*$
ignoreregex =
EOF
                ;;
            "nginx-scan")
                cat > "$filter_dir/$filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* ".*(?:\.\.\/|\/etc\/|\/usr\/|_\/|\.\.\.\/|%00|\\x00).*" (?:404|403|400) .*$
ignoreregex =
EOF
                ;;
            "nginx-req-limit")
                cat > "$filter_dir/$filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*HTTP.*" (?:404|444|403|400|429|502) .*$
ignoreregex =
EOF
                ;;
            "nginx-sql")
                cat > "$filter_dir/$filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* ".*(?:union.*select|concat.*\(|information_schema|load_file).*" (?:404|403|400) .*$
ignoreregex =
EOF
                ;;
            "nginx-xss")
                cat > "$filter_dir/$filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* ".*(?:script>|<script|alert\().*" (?:404|403|400) .*$
ignoreregex =
EOF
                ;;
            "nginx-login")
                cat > "$filter_dir/$filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* "(POST).*/(?:login|admin|wp-login).*" (?:404|403|400|401) .*$
ignoreregex =
EOF
                ;;
            "nginx-crawler")
                cat > "$filter_dir/$filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* "(?:Wget|curl|python-requests|Go-http-client|zgrab|Nmap|masscan).*" .*$
ignoreregex =
EOF
                ;;
            "nginx-custom1")
                cat > "$filter_dir/$filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> -.*- .*HTTP/1.* .* .*$
ignoreregex =
EOF
                ;;
            "nginx-custom2")
                cat > "$filter_dir/$filter.conf" << 'EOF'
[Definition]
failregex = ^<HOST> -.* /var/www/* HTTP/1\..
ignoreregex =
EOF
                ;;
        esac
    done

    # 创建ufw-comment action配置
    cat > "/etc/fail2ban/action.d/ufw-comment.conf" << 'EOF'
[Definition]
actionstart = 
actionstop = 
actioncheck = 

actionban = ufw insert 1 deny from <ip> to any port <port> proto <protocol> comment 'fail2ban: <name> - banned on <datetime>'
            /usr/local/bin/fail2ban-notify.sh <ip> <name> "封禁"

actionunban = ufw delete deny from <ip> to any port <port> proto <protocol>
              /usr/local/bin/fail2ban-notify.sh <ip> <name> "解封"

[Init]
EOF

    # 创建jail.local配置
    cat > "/etc/fail2ban/jail.local" << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = ufw-comment
banaction_allports = ufw-comment

[nginx-cc]
enabled = true
port = http,https
filter = nginx-cc
logpath = 
maxretry = 300
findtime = 60

[nginx-scan]
enabled = true
port = http,https
filter = nginx-scan
logpath = 
maxretry = 5
findtime = 300

[nginx-req-limit]
enabled = true
port = http,https
filter = nginx-req-limit
logpath = 
maxretry = 200
findtime = 60

[nginx-sql]
enabled = true
port = http,https
filter = nginx-sql
logpath = 
maxretry = 2
findtime = 600

[nginx-xss]
enabled = true
port = http,https
filter = nginx-xss
logpath = 
maxretry = 2
findtime = 600

[nginx-login]
enabled = true
port = http,https
filter = nginx-login
logpath = 
maxretry = 5
findtime = 300

[nginx-crawler]
enabled = true
port = http,https
filter = nginx-crawler
logpath = 
maxretry = 3
findtime = 60

[nginx-cc1]
enabled = true
port = http,https
filter = nginx-custom1
logpath = 
maxretry = 5
findtime = 300

[nginx-scan1]
enabled = true
port = http,https
filter = nginx-custom2
logpath = 
maxretry = 5
findtime = 300
EOF

    # 设置配置文件权限
    chmod 644 /etc/fail2ban/jail.local

    # 创建fail2ban配置目录（如果不存在）
    mkdir -p /etc/fail2ban/filter.d
    mkdir -p /etc/fail2ban/action.d

    echo -e "${GREEN}已创建所有必要的fail2ban配置文件${NC}"
}

# 更新jail.local中的logpath
update_logpath() {
    local site=$1
    local jail_local="/etc/fail2ban/jail.local"
    
    awk -v site="$site" '
    /\[nginx-.*\]/ { in_section=1 }
    /^\[.*\]/ && !/\[nginx-.*\]/ { in_section=0 }
    {
        if (in_section && $0 ~ /^logpath =\s*$/) {
            print "logpath = /var/log/nginx/" site ".access.log"
            print "         /var/log/nginx/" site ".error.log"
        } else {
            print $0
        }
    }' "$jail_local" > "$jail_local.tmp" && mv "$jail_local.tmp" "$jail_local"
}

# 一键添加所有站点
add_all_sites() {
    local log_dir="/var/log/nginx"
    local sites=$(ls $log_dir/*.access.log | sed 's/\.access\.log$//' | sed 's|.*/||')
    
    for site in $sites; do
        update_logpath $site
    done
    
    systemctl restart fail2ban
    echo -e "${GREEN}已添加所有站点${NC}"
}

# 列出可追加的站点
list_available_sites() {
    local log_dir="/var/log/nginx"
    local current_sites=$(grep -r "logpath =" /etc/fail2ban/jail.local | cut -d'/' -f5 | sort -u | sed 's/\.access\.log//')
    local all_sites=$(ls $log_dir/*.access.log | sed 's/\.access\.log$//' | sed 's|.*/||')
    
    echo "可追加的站点："
    local i=1
    for site in $all_sites; do
        if ! echo "$current_sites" | grep -q "^$site$"; then
            echo "$i.$site"
            ((i++))
        fi
    done
}

# 追加站点
append_site() {
    read -p "请输入要追加的站点名称：" site
    if [ -f "/var/log/nginx/$site.access.log" ]; then
        update_logpath $site
        systemctl restart fail2ban
        echo -e "${GREEN}已追加站点 $site${NC}"
    else
        echo -e "${RED}站点日志文件不存在${NC}"
    fi
}

# 列出封禁的IP
list_banned_ips() {
    echo "已封禁的IP列表："
    fail2ban-client status | grep "Jail list" | sed 's/^.*://g' | tr ',' '\n' | while read jail; do
        if [ ! -z "$jail" ]; then
            echo -e "\n${GREEN}[$jail]${NC}"
            fail2ban-client status $jail | grep "Banned IP list" | sed 's/^.*://g'
        fi
    done
}

# 解除IP封禁
unban_ip() {
    read -p "请输入要解封的IP地址：" ip
    fail2ban-client unban $ip
    echo -e "${GREEN}已解封IP: $ip${NC}"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${GREEN}Fail2ban管理脚本${NC}"
        echo "1. 安装和配置系统"
        echo "2. 一键添加所有站点"
        echo "3. 追加站点"
        echo "4. 列出封禁的IP"
        echo "5. 解除IP封禁"
        echo "6. 退出"
        
        read -p "请选择操作 (1-6): " choice
        
        case $choice in
            1)
                install_packages
                configure_ufw
                create_fail2ban_configs
                ;;
            2)
                add_all_sites
                ;;
            3)
                list_available_sites
                append_site
                ;;
            4)
                list_banned_ips
                ;;
            5)
                unban_ip
                ;;
            6)
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                ;;
        esac
    done
}

main_menu
