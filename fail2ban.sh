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

# 检查命令是否已安装
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# 检测系统类型并安装软件
install_packages() {
    local packages_to_install=()
    
    # 检查每个必需的命令
    if ! check_command fail2ban-client; then
        packages_to_install+=("fail2ban")
    fi
    
    if ! check_command ufw; then
        packages_to_install+=("ufw")
    fi
    
    if ! check_command jq; then
        packages_to_install+=("jq")
    fi
    
    # 如果所有命令都已安装，则退出
    if [ ${#packages_to_install[@]} -eq 0 ]; then
        echo -e "${GREEN}所有必需的软件包都已安装${NC}"
        return 0
    fi
    
    echo -e "需要安装以下软件包：${packages_to_install[*]}"
    read -p "是否继续安装？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消安装"
        return 1
    fi

    # 根据系统类型安装软件包
    if [ -f /etc/debian_version ]; then
        echo "检测到 Debian/Ubuntu 系统"
        apt update
        for package in "${packages_to_install[@]}"; do
            echo "正在安装 $package..."
            apt install -y "$package"
            if [ $? -ne 0 ]; then
                echo -e "${RED}安装 $package 失败${NC}"
                return 1
            fi
        done
    elif [ -f /etc/redhat-release ]; then
        echo "检测到 RHEL/CentOS 系统"
        if ! check_command epel-release && [[ " ${packages_to_install[@]} " =~ " fail2ban " ]]; then
            echo "正在安装 EPEL 仓库..."
            yum install -y epel-release
        fi
        yum update
        for package in "${packages_to_install[@]}"; do
            echo "正在安装 $package..."
            yum install -y "$package"
            if [ $? -ne 0 ]; then
                echo -e "${RED}安装 $package 失败${NC}"
                return 1
            fi
        done
    else
        echo -e "${RED}不支持的系统类型${NC}"
        return 1
    fi

    echo -e "${GREEN}所有软件包安装完成${NC}"
    return 0
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
failregex = ^<HOST> .* ".*(?:\.\.\/|\/etc\/|\/usr\/|_\/|\.\.\.\/|%%00|\\x00).*" (?:404|403|400) .*$
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
create_fail2ban_configs() {
    # ... 前面的 filter 配置保持不变 ...

    # 创建jail.local配置
    cat > "/etc/fail2ban/jail.local" << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = ufw-comment
banaction_allports = ufw-comment

[nginx-cc]
enabled = false
port = http,https
filter = nginx-cc
logpath = 
maxretry = 300
findtime = 60

[nginx-scan]
enabled = false
port = http,https
filter = nginx-scan
logpath = 
maxretry = 5
findtime = 300

[nginx-req-limit]
enabled = false
port = http,https
filter = nginx-req-limit
logpath = 
maxretry = 200
findtime = 60

[nginx-sql]
enabled = false
port = http,https
filter = nginx-sql
logpath = 
maxretry = 2
findtime = 600

[nginx-xss]
enabled = false
port = http,https
filter = nginx-xss
logpath = 
maxretry = 2
findtime = 600

[nginx-login]
enabled = false
port = http,https
filter = nginx-login
logpath = 
maxretry = 5
findtime = 300

[nginx-crawler]
enabled = false
port = http,https
filter = nginx-crawler
logpath = 
maxretry = 3
findtime = 60

[nginx-cc1]
enabled = false
port = http,https
filter = nginx-custom1
logpath = 
maxretry = 5
findtime = 300

[nginx-scan1]
enabled = false
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


# 更新jail.local中的logpath和enabled状态
update_logpath() {
    local site=$1
    local jail_local="/etc/fail2ban/jail.local"
    
    # 检查是否有日志文件
    if [ -f "/var/log/nginx/$site.access.log" ]; then
        # 更新所有nginx相关规则
        awk '
        /\[nginx-.*\]/ { 
            in_section=1
            print $0
            next
        }
        /^\[.*\]/ { 
            in_section=0
            print $0
            next
        }
        in_section && /^enabled\s*=\s*false/ {
            print "enabled = true"
            next
        }
        in_section && /^logpath\s*=\s*$/ {
            print "logpath = /var/log/nginx/'"$site"'.access.log"
            print "         /var/log/nginx/'"$site"'.error.log"
            next
        }
        {
            print $0
        }
        ' "$jail_local" > "$jail_local.tmp" && mv "$jail_local.tmp" "$jail_local"
    fi
}

# 一键添加所有站点
add_all_sites() {
    local log_dir="/var/log/nginx"
    # 获取所有access和error日志
    local access_logs=$(find "$log_dir" -name "*.access.log" | sort)
    
    if [ -z "$access_logs" ]; then
        echo -e "${RED}未找到任何nginx访问日志文件${NC}"
        return
    fi

    # 准备所有日志路径
    local all_logs=""
    while IFS= read -r access_log; do
        local error_log="${access_log/access.log/error.log}"
        if [ -f "$error_log" ]; then
            if [ -z "$all_logs" ]; then
                all_logs="$access_log $error_log"
            else
                all_logs="$all_logs $access_log $error_log"
            fi
        fi
    done <<< "$access_logs"

    echo "找到以下日志文件："
    echo "$all_logs" | tr ' ' '\n'

    # 更新jail.local中的所有logpath和enabled状态
    sed -i -e '/^logpath = /c\logpath = '"$all_logs"'' \
           -e '/\[nginx-.*\]/,/\[.*\]/ s/^enabled = false/enabled = true/' \
           /etc/fail2ban/jail.local
    
    systemctl restart fail2ban
    echo -e "${GREEN}已添加所有站点日志${NC}"
}

# 列出可追加的站点
list_available_sites() {
    local log_dir="/var/log/nginx"
    # 获取当前配置中的站点
    local current_logs=$(grep "^logpath = " /etc/fail2ban/jail.local | cut -d'=' -f2- | tr ' ' '\n' | sort -u)
    
    # 获取所有可用的日志文件
    local all_logs=$(find "$log_dir" -name "*.access.log" -o -name "*.error.log" | sort)
    
    if [ -z "$all_logs" ]; then
        echo -e "${RED}未找到任何nginx日志文件${NC}"
        return
    fi

    echo "可追加的日志文件："
    local i=1
    local found=0
    while IFS= read -r log; do
        if ! echo "$current_logs" | grep -Fxq "$log"; then
            echo "$i.$(basename "$log")"
            ((i++))
            found=1
        fi
    done <<< "$all_logs"

    if [ $found -eq 0 ]; then
        echo -e "${RED}没有可追加的日志文件${NC}"
    fi
}

# 追加站点
append_site() {
    local log_dir="/var/log/nginx"
    # 首先列出可用的站点
    list_available_sites
    
    echo -e "\n请输入要追加的站点名称（不包含.access.log或.error.log后缀）："
    read -p "站点名称: " site
    
    local access_log="/var/log/nginx/$site.access.log"
    local error_log="/var/log/nginx/$site.error.log"
    
    if [ ! -f "$access_log" ]; then
        echo -e "${RED}访问日志文件不存在: $access_log${NC}"
        return
    fi
    
    if [ ! -f "$error_log" ]; then
        echo -e "${RED}错误日志文件不存在: $error_log${NC}"
        return
    fi

    # 检查是否已存在
    if grep -q "$access_log" /etc/fail2ban/jail.local; then
        echo -e "${RED}该站点已经存在于配置中${NC}"
        return
    fi

    # 追加日志路径到所有规则
    sed -i "/^logpath = / s/$/ $access_log $error_log/" /etc/fail2ban/jail.local
    
    systemctl restart fail2ban
    echo -e "${GREEN}已追加站点 $site${NC}"
}


# 列出已配置的站点
list_configured_sites() {
    local log_dir="/var/log/nginx"
    echo "当前已配置的站点："
    
    # 获取当前配置中的站点
    local current_logs=$(grep "^logpath = " /etc/fail2ban/jail.local | head -n 1 | cut -d'=' -f2- | tr ' ' '\n' | grep "\.access\.log$" | sort)
    
    if [ -z "$current_logs" ]; then
        echo -e "${RED}没有找到已配置的站点${NC}"
        return 1
    fi

    local i=1
    while IFS= read -r log; do
        local site=$(basename "$log" .access.log)
        echo "$i.$site"
        ((i++))
    done <<< "$current_logs"
    
    return 0
}

# 删除站点
remove_site() {
    if ! list_configured_sites; then
        return
    fi
    
    echo -e "\n请输入要删除的站点名称（不包含.access.log或.error.log后缀）："
    read -p "站点名称: " site
    
    local access_log="/var/log/nginx/$site.access.log"
    local error_log="/var/log/nginx/$site.error.log"
    
    # 检查站点是否在配置中
    if ! grep -q "$access_log" /etc/fail2ban/jail.local; then
        echo -e "${RED}该站点不在配置中${NC}"
        return
    fi

    # 从所有规则中删除该站点的日志路径
    sed -i "s| $access_log||g" /etc/fail2ban/jail.local
    sed -i "s| $error_log||g" /etc/fail2ban/jail.local
    
    # 清理可能的前导空格
    sed -i 's/logpath =  */logpath = /' /etc/fail2ban/jail.local
    
    systemctl restart fail2ban
    echo -e "${GREEN}已删除站点 $site${NC}"
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
        echo "4. 删除站点"
        echo "5. 列出已配置站点"
        echo "6. 列出封禁的IP"
        echo "7. 解除IP封禁"
        echo "8. 退出"
        
        read -p "请选择操作 (1-8): " choice
        
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
                remove_site
                ;;
            5)
                list_configured_sites
                ;;
            6)
                list_banned_ips
                ;;
            7)
                unban_ip
                ;;
            8)
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                ;;
        esac
    done
}

main_menu
