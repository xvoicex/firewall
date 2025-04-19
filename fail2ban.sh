#!/bin/bash
#
# Fail2Ban 管理脚本 - 轻量级版本
# 功能：安装配置fail2ban，管理站点配置，监控IP封禁
#

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置文件
CONFIG_FILE="/etc/fail2ban/jail.local"
FILTER_DIR="/etc/fail2ban/filter.d"
ACTION_DIR="/etc/fail2ban/action.d"
LOG_DIR="/var/log/nginx"
UFW_LOG="/root/ufw.log"

# 系统信息和防火墙类型
OS_TYPE=""
FIREWALL_TYPE=""

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用root权限运行此脚本${NC}"
    exit 1
fi

# 检测系统类型（简化版）
detect_os() {
    # 尝试从os-release获取信息
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE="${ID,,}" # 转为小写
        OS_VERSION="$VERSION_ID"
        echo -e "${BLUE}检测到系统: $NAME $VERSION${NC}"
        return 0
    fi
    
    # 尝试lsb-release
    if [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS_TYPE="${DISTRIB_ID,,}" # 转为小写
        OS_VERSION="$DISTRIB_RELEASE"
        echo -e "${BLUE}检测到系统: $DISTRIB_DESCRIPTION${NC}"
        return 0
    fi
    
    # 尝试根据发行版特定文件判断
    if [ -f /etc/redhat-release ]; then
        OS_TYPE="rhel"
        echo -e "${BLUE}检测到Red Hat系统${NC}"
        return 0
    fi
    
    # 默认情况
    OS_TYPE="unknown"
    echo -e "${YELLOW}无法确定系统类型，尝试通用配置${NC}"
    return 1
}

# 检测防火墙类型（简化版）
detect_firewall() {
    # 检查各类防火墙
    local firewalls=("ufw" "firewalld" "iptables")
    
    for fw in "${firewalls[@]}"; do
        if command_exists "$fw"; then
            FIREWALL_TYPE="$fw"
            echo -e "${BLUE}检测到防火墙: ${fw^}${NC}" # 首字母大写
            return 0
        fi
    done
    
    # 默认情况
    FIREWALL_TYPE="none"
    echo -e "${YELLOW}未检测到支持的防火墙，部分功能可能受限${NC}"
    return 1
}

# 调整配置基于系统类型（简化版）
adjust_config() {
    # 根据系统类型设置日志路径
    case "$OS_TYPE" in
        ubuntu|debian|kali)
            LOG_DIR="/var/log/nginx"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            LOG_DIR="/var/log/nginx"
            # 检查SELinux
            [ "$(command -v getenforce && getenforce)" = "Enforcing" ] && \
                echo -e "${YELLOW}检测到SELinux启用状态，可能需要额外配置${NC}"
            ;;
        *)
            # 尝试查找nginx日志目录
            for dir in "/var/log/nginx" "/usr/local/nginx/logs"; do
                [ -d "$dir" ] && LOG_DIR="$dir" && break
            done
            ;;
    esac
    
    echo -e "${BLUE}使用日志目录: $LOG_DIR${NC}"
}

# 检查目录存在
check_directories() {
    for dir in "$FILTER_DIR" "$ACTION_DIR" "$LOG_DIR"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            echo -e "${YELLOW}已创建目录: $dir${NC}"
        fi
    done
}

# 判断命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查包是否已安装
package_installed() {
    local pkg=$1
    
    if command_exists apt-get; then
        dpkg -l | grep -q "ii  $pkg " && return 0
    elif command_exists yum || command_exists dnf; then
        rpm -q "$pkg" >/dev/null 2>&1 && return 0
    fi
    
    return 1
}

# 安装软件包
install_packages() {
    local required_packages=("fail2ban")
    local firewall_pkg=""
    
    # 确定合适的防火墙软件包
    case "$FIREWALL_TYPE" in
        "ufw")
            firewall_pkg="ufw"
            required_packages+=("ufw")
            ;;
        "firewalld")
            firewall_pkg="firewalld"
            required_packages+=("firewalld")
            ;;
        "iptables")
            firewall_pkg="iptables"
            required_packages+=("iptables")
            ;;
        "none")
            # 根据系统选择默认防火墙
            case "$OS_TYPE" in
                "ubuntu"|"debian"|"kali")
                    firewall_pkg="ufw"
                    required_packages+=("ufw")
                    ;;
                "centos"|"rhel"|"fedora"|"rocky"|"almalinux")
                    firewall_pkg="firewalld"
                    required_packages+=("firewalld")
                    ;;
                *)
                    firewall_pkg="ufw"
                    required_packages+=("ufw")
                    ;;
            esac
            ;;
    esac
    
    # 添加jq包
    required_packages+=("jq")
    
    # 检查是否已安装所需软件
    local packages_to_install=()
    for pkg in "${required_packages[@]}"; do
        if ! package_installed "$pkg"; then
            packages_to_install+=("$pkg")
        fi
    done
    
    # 如果所有软件都已安装，直接返回
    if [ ${#packages_to_install[@]} -eq 0 ]; then
        echo -e "${GREEN}所有必需的软件包已安装${NC}"
        return 0
    fi
    
    # 根据系统类型安装缺失的软件包
    if command_exists apt-get; then
        echo -e "${GREEN}使用apt安装缺失的软件包: ${packages_to_install[*]}${NC}"
        apt-get update
        apt-get install -y "${packages_to_install[@]}"
    elif command_exists dnf; then
        echo -e "${GREEN}使用dnf安装缺失的软件包: ${packages_to_install[*]}${NC}"
        dnf install -y epel-release
        dnf install -y "${packages_to_install[@]}"
    elif command_exists yum; then
        echo -e "${GREEN}使用yum安装缺失的软件包: ${packages_to_install[*]}${NC}"
        yum install -y epel-release
        yum install -y "${packages_to_install[@]}"
    else
        echo -e "${RED}不支持的系统类型${NC}"
        exit 1
    fi

    # 验证安装
    local install_failed=0
    for pkg in "${packages_to_install[@]}"; do
        if ! package_installed "$pkg"; then
            echo -e "${RED}安装 $pkg 失败${NC}"
            install_failed=1
        fi
    done
    
    if [ $install_failed -eq 1 ]; then
        echo -e "${YELLOW}警告: 某些软件包安装失败，但继续执行脚本${NC}"
    fi
    
    # 更新FIREWALL_TYPE，以防安装了新的防火墙
    detect_firewall
}

# 配置防火墙
configure_firewall() {
    echo -e "${GREEN}配置防火墙: $FIREWALL_TYPE${NC}"
    
    # 检查防火墙是否存在
    case "$FIREWALL_TYPE" in
        "ufw")
            if ! command_exists ufw; then
                echo -e "${RED}UFW未安装，请先安装UFW${NC}"
                return 1
            fi
            ;;
        "firewalld")
            if ! command_exists firewall-cmd; then
                echo -e "${RED}FirewallD未安装，请先安装FirewallD${NC}"
                return 1
            fi
            ;;
        "iptables")
            if ! command_exists iptables; then
                echo -e "${RED}iptables未安装，请先安装iptables${NC}"
                return 1
            fi
            ;;
        "none")
            echo -e "${YELLOW}未检测到支持的防火墙，跳过防火墙配置${NC}"
            return 0
            ;;
    esac
    
    # 获取非本地监听端口
    local ports_tcp ports_udp
    get_listening_ports ports_tcp ports_udp
    
    # 根据防火墙类型执行配置
    case "$FIREWALL_TYPE" in
        "ufw")
            # 重置并启用UFW
            ufw --force reset
            ufw --force enable
            ufw default deny incoming
            ufw default allow outgoing
            
            # 允许SSH
            ufw allow 22/tcp comment 'SSH'
            
            # 添加端口规则
            for port in $ports_tcp; do
                ufw allow $port/tcp comment "Port $port TCP"
            done
            for port in $ports_udp; do
                ufw allow $port/udp comment "Port $port UDP"
            done
            
            # 显示规则
            ufw status numbered
            ;;
        "firewalld")
            # 启动服务
            systemctl start firewalld
            systemctl enable firewalld
            
            # 允许SSH
            firewall-cmd --permanent --add-service=ssh
            
            # 添加端口规则
            for port in $ports_tcp; do
                firewall-cmd --permanent --add-port=$port/tcp
            done
            for port in $ports_udp; do
                firewall-cmd --permanent --add-port=$port/udp
            done
            
            # 应用规则
            firewall-cmd --reload
            firewall-cmd --list-all
            ;;
        "iptables")
            # 保存当前规则
            local temp_rules=$(mktemp)
            iptables-save > "$temp_rules"
            
            # 设置基本规则
            iptables -F
            iptables -P INPUT DROP
            iptables -P FORWARD DROP
            iptables -P OUTPUT ACCEPT
            iptables -A INPUT -i lo -j ACCEPT
            iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            iptables -A INPUT -p tcp --dport 22 -j ACCEPT
            
            # 添加端口规则
            for port in $ports_tcp; do
                iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            done
            for port in $ports_udp; do
                iptables -A INPUT -p udp --dport "$port" -j ACCEPT
            done
            
            # 保存规则
            save_iptables_rules
            
            # 删除临时文件和显示规则
            rm "$temp_rules"
            iptables -L -v
            ;;
    esac
    
    return 0
}

# 获取监听端口
get_listening_ports() {
    local ports_tcp_var=$1
    local ports_udp_var=$2
    local cmd="ss"
    
    # 检查命令
    if ! command_exists ss; then
        if command_exists netstat; then
            cmd="netstat"
        else
            echo -e "${RED}未找到网络状态命令(ss/netstat)${NC}"
            return 1
        fi
    fi
    
    # 获取TCP端口
    if [ "$cmd" = "ss" ]; then
        local tcp_ports=$(ss -tuln | grep LISTEN | grep -v "127.0.0.1" | grep -v "::1" | grep "tcp" | awk '{print $5}' | awk -F: '{print $NF}' | sort -u | grep -E '^[0-9]+$')
        local udp_ports=$(ss -tuln | grep -v "127.0.0.1" | grep -v "::1" | grep "udp" | awk '{print $5}' | awk -F: '{print $NF}' | sort -u | grep -E '^[0-9]+$')
    else
        local tcp_ports=$(netstat -tuln | grep LISTEN | grep -v "127.0.0.1" | grep -v "::1" | grep "tcp" | awk '{print $4}' | awk -F: '{print $NF}' | sort -u | grep -E '^[0-9]+$')
        local udp_ports=$(netstat -tuln | grep -v "127.0.0.1" | grep -v "::1" | grep "udp" | awk '{print $4}' | awk -F: '{print $NF}' | sort -u | grep -E '^[0-9]+$')
    fi
    
    # 设置返回值
    eval "$ports_tcp_var=\"$tcp_ports\""
    eval "$ports_udp_var=\"$udp_ports\""
    return 0
}

# 保存iptables规则
save_iptables_rules() {
    if command_exists iptables-save; then
        case "$OS_TYPE" in
            "ubuntu"|"debian"|"kali")
                iptables-save > /etc/iptables/rules.v4
                ;;
            "centos"|"rhel"|"fedora"|"rocky"|"almalinux")
                iptables-save > /etc/sysconfig/iptables
                ;;
            *)
                local iptables_rules="/etc/iptables/rules.v4"
                mkdir -p "$(dirname "$iptables_rules")"
                iptables-save > "$iptables_rules"
                echo -e "${YELLOW}规则已保存到 $iptables_rules，但可能需要额外配置以在启动时加载${NC}"
                ;;
        esac
    else
        echo -e "${YELLOW}无法找到 iptables-save 命令，规则可能在重启后丢失${NC}"
    fi
}

# 创建对应防火墙的action配置
create_firewall_action() {
    case "$FIREWALL_TYPE" in
        "ufw")
            cat > "$ACTION_DIR/ufw-comment.conf" << 'EOF'
[Definition]
actionstart = 
actionstop = 
actioncheck = 

actionban = ufw insert 1 deny from <ip> to any port <port> proto <protocol> comment 'fail2ban: <name> - banned on <datetime>' >> /root/ufw.log 2>&1 && /usr/local/bin/fail2ban-notify.sh <ip> <name> "封禁"
            
actionunban = ufw delete deny from <ip> to any port <port> proto <protocol> >> /root/ufw.log 2>&1  && /usr/local/bin/fail2ban-notify.sh <ip> <name> "解封" 

[Init]
EOF
            ;;
        "firewalld")
            cat > "$ACTION_DIR/firewalld-multiport.conf" << 'EOF'
[Definition]
actionstart = firewall-cmd --direct --add-chain ipv4 filter fail2ban-<name>
              firewall-cmd --direct --add-rule ipv4 filter INPUT_direct 0 -m state --state NEW -j fail2ban-<name>

actionstop = firewall-cmd --direct --remove-rule ipv4 filter INPUT_direct 0 -m state --state NEW -j fail2ban-<name>
             firewall-cmd --direct --remove-chain ipv4 filter fail2ban-<name>

actioncheck = firewall-cmd --direct --get-chains ipv4 filter | grep -q 'fail2ban-<name>'

actionban = firewall-cmd --direct --add-rule ipv4 filter fail2ban-<name> 0 -s <ip> -j REJECT && /usr/local/bin/fail2ban-notify.sh <ip> <name> "封禁"
            
actionunban = firewall-cmd --direct --remove-rule ipv4 filter fail2ban-<name> 0 -s <ip> -j REJECT && /usr/local/bin/fail2ban-notify.sh <ip> <name> "解封"

[Init]
EOF
            ;;
        "iptables")
            cat > "$ACTION_DIR/iptables-multiport.conf" << 'EOF'
[Definition]
actionstart = iptables -N fail2ban-<name>
              iptables -A fail2ban-<name> -j RETURN
              iptables -I INPUT -p <protocol> -m multiport --dports <port> -j fail2ban-<name>

actionstop = iptables -D INPUT -p <protocol> -m multiport --dports <port> -j fail2ban-<name>
             iptables -F fail2ban-<name>
             iptables -X fail2ban-<name>

actioncheck = iptables -n -L fail2ban-<name> >/dev/null 2>&1

actionban = iptables -I fail2ban-<name> 1 -s <ip> -j DROP && /usr/local/bin/fail2ban-notify.sh <ip> <name> "封禁"
            
actionunban = iptables -D fail2ban-<name> -s <ip> -j DROP && /usr/local/bin/fail2ban-notify.sh <ip> <name> "解封"

[Init]
name = default
port = ssh
protocol = tcp
EOF
            ;;
        *)
            echo -e "${YELLOW}未检测到支持的防火墙，使用空操作动作${NC}"
            cat > "$ACTION_DIR/dummy.conf" << 'EOF'
[Definition]
actionstart = 
actionstop = 
actioncheck = 

actionban = echo "封禁 <ip> (<name>) 于 <datetime>" >> /var/log/fail2ban-dummy.log && /usr/local/bin/fail2ban-notify.sh <ip> <name> "封禁"
            
actionunban = echo "解封 <ip> (<name>) 于 $(date '+%%Y-%%m-%%d %%H:%%M:%%S')" >> /var/log/fail2ban-dummy.log && /usr/local/bin/fail2ban-notify.sh <ip> <name> "解封"

[Init]
EOF
            ;;
    esac
}

# 创建fail2ban过滤器配置
create_filters() {
    check_directories
    
    # nginx-req-limit.conf
    cat > "$FILTER_DIR/nginx-req-limit.conf" << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*HTTP.*" (?:404|444|403|400|429|502) .*$
           ^<HOST> -.*- .*HTTP/1.* .* .*$
ignoreregex =
EOF

    # 创建对应防火墙的action配置
    create_firewall_action

    # 检查fail2ban-notify.sh是否存在，如果不存在则创建
    local notify_script="/usr/local/bin/fail2ban-notify.sh"
    if [ ! -f "$notify_script" ]; then
        cat > "$notify_script" << 'EOF'
#!/bin/bash
# 封禁/解封通知脚本
# 用法: fail2ban-notify.sh <ip> <jail名称> <动作>

IP="$1"
JAIL="$2"
ACTION="$3"

# 这里可以添加通知逻辑，比如发送邮件、推送通知等
echo "$(date '+%Y-%m-%d %H:%M:%S') - $IP 已被 $JAIL $ACTION" >> /var/log/fail2ban-actions.log
EOF
        chmod +x "$notify_script"
        echo -e "${GREEN}已创建通知脚本: $notify_script${NC}"
    fi
}

# 创建基础jail.local配置
create_base_jail() {
    # 检查配置文件是否存在，如果存在则备份
    if [ -f "$CONFIG_FILE" ]; then
        local backup_file="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        echo -e "${YELLOW}已备份原配置文件到: $backup_file${NC}"
    fi

    # 确定默认ban action
    local ban_action="ufw-comment"
    case "$FIREWALL_TYPE" in
        "firewalld")
            ban_action="firewalld-multiport"
            ;;
        "iptables")
            ban_action="iptables-multiport"
            ;;
        "none")
            ban_action="dummy"
            ;;
    esac

    cat > "$CONFIG_FILE" << EOF
[DEFAULT]
ignoreip = 8.219.115.164,8.134.221.180,54.241.88.222,54.241.6.229,54.241.114.59,54.241.104.254,54.219.249.105,54.219.216.37,54.193.161.89,54.177.98.15,54.177.36.181,54.177.222.120,54.177.153.74,54.176.110.219,54.176.109.175,54.169.255.14,54.153.102.95,54.151.98.220,52.9.102.70,52.77.34.154,52.76.152.217,52.53.59.103,52.53.140.92,52.53.107.248,52.32.115.20,52.221.132.216,50.18.2.120,47.115.3.87,47.113.203.181,44.226.79.51,44.226.193.220,43.198.201.112,43.198.174.122,35.155.189.6,34.209.60.225,3.66.154.171,3.140.147.172,204.236.135.96,184.72.12.221,18.184.40.180,18.167.86.251,18.167.60.135,18.166.12.220,18.166.107.52,18.162.119.139,18.144.77.47,18.144.121.117,18.144.113.28,18.142.25.202,18.142.211.78,18.135.164.144,16.163.181.222,16.162.2.185,16.162.172.75,139.9.101.181,139.159.191.243,13.56.117.186,13.52.72.226,13.52.172.179,13.52.151.41,13.41.107.219,13.250.142.49,13.229.179.115,13.215.58.178,120.79.101.165,120.78.198.94,101.37.165.145,100.21.31.166
bantime = 3600
findtime = 600
maxretry = 15
banaction = $ban_action
banaction_allports = $ban_action

#sshd-START
[sshd]
enabled = false
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

# 通用配置函数，负责创建或更新配置文件
update_config_file() {
    local file=$1
    local content=$2
    local mode=${3:-"a"} # 默认为追加，"w"为覆盖
    
    if [ "$mode" = "w" ]; then
        echo "$content" > "$file"
    else
        echo "$content" >> "$file"
    fi
    
    return $?
}

# 添加站点配置
add_site_config() {
    local site_prefix=$1
    local access_log="$LOG_DIR/${site_prefix}.access.log"
    
    # 检查日志文件
    if [ ! -f "$access_log" ]; then
        echo -e "${RED}找不到站点 ${site_prefix} 的日志文件${NC}"
        return 1
    fi

    # 检查站点是否已配置
    if grep -q "#${site_prefix}_start" "$CONFIG_FILE"; then
        echo -e "${YELLOW}站点 ${site_prefix} 已配置，跳过${NC}"
        return 0
    fi

    # 准备配置内容
    local config_content="
#${site_prefix}_start

[nginx-req-limit-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-req-limit
logpath = $access_log
maxretry = 30
findtime = 60

[nginx-botsearch-${site_prefix}]
enabled = true
port = 80,443
filter = nginx-botsearch
logpath = $access_log
maxretry = 30
findtime = 60
#${site_prefix}_end"

    # 更新配置文件
    update_config_file "$CONFIG_FILE" "$config_content"
    return 0
}

# 添加所有站点
add_all_sites() {
    # 检查配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        create_base_jail
    else
        # 备份原文件
        local backup_file="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        echo -e "${YELLOW}已备份原配置文件到: $backup_file${NC}"
        
        # 仅保留DEFAULT和SSH部分
        local new_content
        new_content=$(sed -n '/^\[DEFAULT\]/,/^$/ p' "$CONFIG_FILE")
        
        # 添加SSH配置（如果存在）
        if grep -q "^\[sshd\]" "$CONFIG_FILE"; then
            new_content="${new_content}\n$(sed -n '/^#sshd-START/,/^#sshd-END/ p' "$CONFIG_FILE")\n"
        fi
        
        # 更新配置文件
        if [ ! -z "$new_content" ]; then
            update_config_file "$CONFIG_FILE" "$new_content" "w"
            echo -e "${GREEN}已清除所有站点配置${NC}"
        else
            create_base_jail
        fi
    fi

    # 添加所有站点
    local added=0
    echo -e "${GREEN}开始添加所有站点...${NC}"
    
    # 使用find代替for循环提高效率
    while IFS= read -r log_file; do
        site_prefix=$(basename "$log_file" .access.log)
        echo -e "${BLUE}处理站点: $site_prefix${NC}"
        
        # 跳过默认日志（如果存在专门的default配置）
        if [ "$site_prefix" = "access" ] && grep -q "#default_logs_start" "$CONFIG_FILE"; then
            echo -e "${YELLOW}跳过默认日志，已有专门配置${NC}"
            continue
        fi
        
        if add_site_config "$site_prefix"; then
            added=$((added + 1))
        fi
    done < <(find "$LOG_DIR" -name "*.access.log" -type f)

    # 处理默认日志
    if ! grep -q "#default_logs_start" "$CONFIG_FILE" && [ -f "$LOG_DIR/access.log" ]; then
        echo -e "${BLUE}添加默认日志监控${NC}"
        add_default_logs
        added=$((added + 1))
    fi

    # 重启服务
    if [ $added -gt 0 ]; then
        echo -e "${GREEN}已添加 $added 个站点/日志配置${NC}"
        restart_fail2ban
    else
        echo -e "${YELLOW}没有找到可添加的站点${NC}"
    fi
}

# 添加默认日志监控
add_default_logs() {
    local access_log="$LOG_DIR/access.log"
    
    # 检查日志文件
    if [ ! -f "$access_log" ]; then
        echo -e "${RED}默认访问日志文件 $access_log 不存在${NC}"
        return 1
    fi

    # 检查是否已经在监控中
    if grep -q "#default_logs_start" "$CONFIG_FILE"; then
        echo -e "${YELLOW}默认日志已在监控列表中${NC}"
        return 0
    fi

    # 准备配置内容
    local config_content="
#default_logs_start
[nginx-req-limit-default]
enabled = true
port = 80,443
filter = nginx-req-limit
logpath = $access_log
maxretry = 30
findtime = 60

[nginx-botsearch-default]
enabled = true
port = 80,443
filter = nginx-botsearch
logpath = $access_log
maxretry = 30
findtime = 60
#default_logs_end"

    # 更新配置文件
    update_config_file "$CONFIG_FILE" "$config_content"
    restart_fail2ban
    echo -e "${GREEN}已添加默认日志到监控列表并重启服务${NC}"
}

# 删除配置区块
remove_config_block() {
    local file=$1
    local start_pattern=$2
    local end_pattern=$3
    
    # 创建临时文件
    local temp_file=$(mktemp)
    
    # 删除配置区块
    sed "/$start_pattern/,/$end_pattern/d" "$file" > "$temp_file"
    
    # 验证文件
    if [ ! -s "$temp_file" ]; then
        echo -e "${RED}配置文件处理失败${NC}"
        rm "$temp_file"
        return 1
    fi
    
    # 更新文件
    mv "$temp_file" "$file"
    return 0
}

# 删除站点配置
remove_site() {
    local site_prefix=$1
    
    # 检查站点是否已配置
    if ! grep -q "#${site_prefix}_start" "$CONFIG_FILE"; then
        echo -e "${RED}站点 ${site_prefix} 未配置${NC}"
        return 1
    fi
    
    # 删除配置区块
    if remove_config_block "$CONFIG_FILE" "#${site_prefix}_start" "#${site_prefix}_end"; then
        restart_fail2ban
        echo -e "${GREEN}站点 ${site_prefix} 已从配置中移除并重启服务${NC}"
        return 0
    fi
    
    return 1
}

# 删除默认日志监控
remove_default_logs() {
    # 检查是否在监控中
    if ! grep -q "#default_logs_start" "$CONFIG_FILE"; then
        echo -e "${YELLOW}默认日志不在监控列表中${NC}"
        return 0
    fi
    
    # 删除配置区块
    if remove_config_block "$CONFIG_FILE" "#default_logs_start" "#default_logs_end"; then
        restart_fail2ban
        echo -e "${GREEN}已从监控列表中移除默认日志并重启服务${NC}"
        return 0
    fi
    
    return 1
}

# 重启fail2ban服务
restart_fail2ban() {
    echo -e "${BLUE}重启fail2ban服务...${NC}"
    if command_exists systemctl; then
        systemctl restart fail2ban
    elif command_exists service; then
        service fail2ban restart
    elif [ -f /etc/init.d/fail2ban ]; then
        /etc/init.d/fail2ban restart
    else
        echo -e "${RED}无法识别系统的服务管理器，请手动重启fail2ban服务${NC}"
        return 1
    fi
    
    # 等待服务启动
    sleep 2
    check_fail2ban_status
    return $?
}

# 列出封禁的IP
list_banned_ips() {
    if ! command_exists fail2ban-client; then
        echo -e "${RED}fail2ban-client 未安装${NC}"
        return 1
    fi

    # 获取所有jail
    local status_output=$(fail2ban-client status)
    local jails=$(echo "$status_output" | grep "Jail list:" | cut -d':' -f2 | tr ',' ' ')
    
    if [ -z "$jails" ]; then
        echo -e "${YELLOW}没有可用的 jail${NC}"
        return 0
    fi

    echo -e "${GREEN}当前封禁IP统计:${NC}"
    local total_banned=0
    local jail_list=""
    
    # 收集所有封禁信息
    for jail in $jails; do
        jail=$(echo "$jail" | tr -d ' ')
        [ -z "$jail" ] && continue
        
        local jail_status=$(fail2ban-client status "$jail")
        local banned_count=$(echo "$jail_status" | grep "Currently banned:" | awk '{print $4}')
        
        if [ -n "$banned_count" ] && [ "$banned_count" -gt 0 ]; then
            local banned_ips=$(echo "$jail_status" | grep "Banned IP list:" | cut -d':' -f2)
            echo -e "${GREEN}$jail:${NC} $banned_count 个IP"
            echo "$banned_ips" | tr ',' '\n' | sed 's/^ //g' | sed 's/^/  /'
            total_banned=$((total_banned + banned_count))
            jail_list="${jail_list} ${jail}"
        fi
    done
    
    if [ $total_banned -eq 0 ]; then
        echo -e "${YELLOW}当前没有封禁的IP${NC}"
    else
        echo -e "\n${GREEN}总计: $total_banned 个IP被封禁${NC}"
    fi
    
    return 0
}

# 解除IP封禁
unban_ip() {
    local ip=$1
    
    if ! command_exists fail2ban-client; then
        echo -e "${RED}fail2ban-client 未安装${NC}"
        return 1
    fi
    
    # 验证IP格式
    if ! [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}无效的IP地址格式: $ip${NC}"
        return 1
    fi
    
    # 获取所有jail
    local jails=$(fail2ban-client status | grep "Jail list:" | cut -d':' -f2 | tr ',' ' ')
    
    local unbanned=0
    for jail in $jails; do
        jail=$(echo "$jail" | tr -d ' ')
        if [ ! -z "$jail" ]; then
            # 检查该jail中是否有这个IP
            if fail2ban-client status "$jail" | grep "Banned IP list:" | grep -q "$ip"; then
                if fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null; then
                    echo -e "${GREEN}已从 $jail 解封IP: $ip${NC}"
                    unbanned=1
                fi
            fi
        fi
    done

    if [ $unbanned -eq 0 ]; then
        echo -e "${RED}未找到被封禁的IP: $ip${NC}"
    else
        echo -e "${GREEN}完成解封操作${NC}"
    fi
}

# 列出已配置的站点
list_configured_sites() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在${NC}"
        return 1
    fi

    local sites=$(grep -o "#.*_start" "$CONFIG_FILE" | sed 's/#\(.*\)_start/\1/' | sort)
    
    if [ -z "$sites" ]; then
        echo -e "${YELLOW}没有已配置的站点${NC}"
        return 1
    fi
    
    echo -e "${GREEN}已配置的站点:${NC}"
    echo "$sites"
    return 0
}

# 列出可追加的站点
list_available_sites() {
    local found=0
    local configured_sites=$(grep -o "#.*_start" "$CONFIG_FILE" | sed 's/#\(.*\)_start/\1/')
    
    echo -e "${GREEN}可追加的站点:${NC}"
    
    # 使用find命令而不是for循环
    while IFS= read -r log_file; do
        site_prefix=$(basename "$log_file" .access.log)
        # 使用grep -v过滤已配置的站点
        if ! echo "$configured_sites" | grep -q "$site_prefix"; then
            echo "$site_prefix"
            found=1
        fi
    done < <(find "$LOG_DIR" -name "*.access.log" -type f)
    
    if [ $found -eq 0 ]; then
        echo -e "${YELLOW}没有可追加的站点${NC}"
    fi
    
    return $found
}

# 修改IP白名单
edit_whitelist() {
    [ ! -f "$CONFIG_FILE" ] && echo -e "${RED}配置文件不存在${NC}" && return 1
    
    # 提取当前白名单
    local current_whitelist=$(grep "^ignoreip" "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^[ \t]*//')
    
    echo -e "${GREEN}当前白名单IP列表:${NC}"
    echo "$current_whitelist" | tr ',' '\n' | nl -w2 -s". "
    
    # 显示选项
    echo
    echo "1. 添加IP到白名单"
    echo "2. 从白名单中删除IP"
    echo "3. 返回"
    echo -n "请选择: "
    read -r op_choice
    
    case $op_choice in
        1) # 添加IP
            echo -n "请输入要添加的IP (多个IP用逗号分隔): "
            read -r new_ips
            [ -z "$new_ips" ] && return 0
            
            # 合并并去重
            local combined_list="${current_whitelist},${new_ips}"
            local unique_list=$(echo "$combined_list" | tr ',' '\n' | sort -u | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
            
            # 更新配置
            sed -i "s/^ignoreip = .*$/ignoreip = ${unique_list}/" "$CONFIG_FILE" && \
                restart_fail2ban && \
                echo -e "${GREEN}已更新白名单并重启服务${NC}"
            ;;
        2) # 删除IP
            echo -n "请输入要删除的IP编号(多个用空格分隔): "
            read -r ids
            [ -z "$ids" ] && return 0
            
            # 将白名单转换为数组
            IFS=',' read -r -a ip_array <<< "$current_whitelist"
            
            # 创建新列表，排除要删除的IP
            local new_list=()
            local ip_count=${#ip_array[@]}
            
            for i in $(seq 0 $((ip_count-1))); do
                if ! echo " $ids " | grep -q " $((i+1)) "; then
                    new_list+=("${ip_array[$i]}")
                fi
            done
            
            # 转换回逗号分隔的字符串
            local new_list_str=$(IFS=,; echo "${new_list[*]}")
            
            # 更新配置
            sed -i "s/^ignoreip = .*$/ignoreip = ${new_list_str}/" "$CONFIG_FILE" && \
                restart_fail2ban && \
                echo -e "${GREEN}已更新白名单并重启服务${NC}"
            ;;
        3) # 返回
            return 0
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            ;;
    esac
    
    return 0
}

# 检查服务状态
check_fail2ban_status() {
    # 检查各种服务管理器
    if command_exists systemctl; then
        # systemd
        if systemctl is-active --quiet fail2ban; then
            return 0
        else
            return 1
        fi
    elif command_exists service; then
        # SysV init
        service fail2ban status >/dev/null 2>&1
        return $?
    elif [ -f /etc/init.d/fail2ban ]; then
        # 直接使用init脚本
        /etc/init.d/fail2ban status >/dev/null 2>&1
        return $?
    else
        # 最后尝试检查进程
        pgrep -f "/usr/bin/fail2ban-server" >/dev/null 2>&1
        return $?
    fi
}

# 启动fail2ban服务
start_fail2ban() {
    if command_exists systemctl; then
        systemctl start fail2ban
    elif command_exists service; then
        service fail2ban start
    elif [ -f /etc/init.d/fail2ban ]; then
        /etc/init.d/fail2ban start
    else
        echo -e "${RED}无法识别系统的服务管理器${NC}"
        return 1
    fi
    
    # 等待服务启动
    sleep 2
    check_fail2ban_status
    return $?
}

# 显示fail2ban状态
show_status() {
    if ! command_exists fail2ban-client; then
        echo -e "${RED}fail2ban-client 未安装${NC}"
        return 1
    fi
    
    # 检查服务是否运行
    if ! check_fail2ban_status; then
        echo -e "${RED}Fail2Ban 服务未运行${NC}"
        
        if command_exists systemctl; then
            systemctl status fail2ban | head -n 3
        fi
        
        echo
        echo -e "${YELLOW}尝试启动服务...${NC}"
        
        if ! start_fail2ban; then
            echo -e "${RED}无法启动 Fail2Ban 服务${NC}"
            return 1
        else
            echo -e "${GREEN}Fail2Ban 服务已启动${NC}"
        fi
    else
        echo -e "${GREEN}Fail2Ban 服务正在运行${NC}"
    fi
    
    echo
    echo -e "${GREEN}Fail2Ban 版本:${NC}"
    fail2ban-client --version
    
    echo
    echo -e "${GREEN}Fail2Ban 状态概览:${NC}"
    fail2ban-client status
    
    local jails=$(fail2ban-client status | grep "Jail list:" | cut -d':' -f2 | tr ',' ' ')
    
    if [ ! -z "$jails" ]; then
        echo
        echo -e "${GREEN}Jail 状态详情:${NC}"
        for jail in $jails; do
            jail=$(echo "$jail" | tr -d ' ')
            if [ ! -z "$jail" ]; then
                local status_output=$(fail2ban-client status "$jail")
                local total_banned=$(echo "$status_output" | grep "Currently banned:" | awk '{print $4}')
                
                echo -e "\n${GREEN}[$jail]${NC} - 当前封禁: ${total_banned} 个IP"
                echo "$status_output" | grep -E "Filter|Actions|Currently|Total"
                
                if [ "$total_banned" -gt 0 ]; then
                    echo -e "${YELLOW}已封禁IP:${NC}"
                    echo "$status_output" | grep "Banned IP list:" | cut -d':' -f2 | tr ',' '\n' | sed 's/^ //g'
                fi
            fi
        done
    fi
}

# 管理站点配置（整合所有站点管理功能）
manage_site_config() {
    local options=("追加单个站点" "删除单个站点" "添加默认日志监控" "删除默认日志监控" "返回主菜单")
    local exit_option=${#options[@]}
    
    while true; do
        echo -e "\n${GREEN}站点配置管理${NC}"
        
        # 显示当前状态
        echo -e "${BLUE}当前配置状态:${NC}"
        echo -n "默认日志监控: "
        if grep -q "#default_logs_start" "$CONFIG_FILE"; then
            echo -e "${GREEN}已启用${NC}"
        else
            echo -e "${YELLOW}未启用${NC}"
        fi
        echo -n "已配置站点数: "
        local site_count=$(grep -c "#.*_start" "$CONFIG_FILE")
        echo -e "${GREEN}$site_count${NC}"
        echo
        
        # 显示菜单选项
        for i in "${!options[@]}"; do
            echo "$((i+1)). ${options[$i]}"
        done
        
        # 获取用户选择
        echo -n "请选择: "
        read -r config_op
        
        # 验证输入
        if ! [[ "$config_op" =~ ^[0-9]+$ ]] || [ "$config_op" -lt 1 ] || [ "$config_op" -gt $exit_option ]; then
            echo -e "${RED}无效的选择${NC}"
            continue
        fi
        
        # 处理选择
        case $config_op in
            1) # 追加站点
                list_available_sites
                if [ $? -eq 0 ]; then
                    echo -n "请输入站点前缀 (留空返回): "
                    read -r site_prefix
                    [ -z "$site_prefix" ] && continue
                    add_site_config "$site_prefix" && restart_fail2ban
                fi
                ;;
            2) # 删除站点
                list_configured_sites
                if [ $? -eq 0 ]; then
                    echo -n "请输入要删除的站点前缀 (留空返回): "
                    read -r site_prefix
                    [ -z "$site_prefix" ] && continue
                    remove_site "$site_prefix"
                fi
                ;;
            3) # 添加默认日志
                add_default_logs
                ;;
            4) # 删除默认日志
                remove_default_logs
                ;;
            $exit_option) # 返回
                return 0
                ;;
        esac
        
        # 按任意键继续
        echo
        read -n 1 -s -r -p "按任意键继续，或按 'q' 返回主菜单... " key
        [ "$key" = "q" ] && return 0
        echo
    done
}

# 修改主菜单（简化显示）
show_menu() {
    local options=(
        "安装和配置 fail2ban和防火墙" 
        "添加所有站点" 
        "管理站点配置" 
        "列出封禁的IP" 
        "解除IP封禁" 
        "列出已配置的站点" 
        "修改IP白名单" 
        "显示fail2ban状态"
        "退出"
    )
    
    echo -e "\n${GREEN}Fail2Ban 管理脚本${NC}"
    
    for i in "${!options[@]}"; do
        if [ $i -eq $((${#options[@]}-1)) ]; then
            echo "0. ${options[$i]}"
        else
            echo "$((i+1)). ${options[$i]}"
        fi
    done
    
    echo -n "请选择: "
}

# 主程序
main() {
    # 检测系统和防火墙类型
    detect_os
    detect_firewall
    adjust_config
    check_directories

    # 主循环
    while true; do
        # 显示菜单
        show_menu
        read -r choice
        
        case $choice in
            1) # 安装配置
                install_packages
                configure_firewall
                create_filters
                echo -e "${GREEN}安装和配置完成${NC}"
                ;;
            2) # 添加所有站点
                add_all_sites
                ;;
            3) # 管理站点配置
                manage_site_config
                ;;
            4) # 列出封禁IP
                list_banned_ips
                ;;
            5) # 解除IP封禁
                echo -n "请输入要解封的IP: "
                read -r ip
                [ -n "$ip" ] && unban_ip "$ip"
                ;;
            6) # 列出已配置站点
                list_configured_sites
                ;;
            7) # 修改白名单
                edit_whitelist
                ;;
            8) # 显示状态
                show_status
                ;;
            0) # 退出
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                ;;
        esac
        
        # 按任意键继续
        echo
        read -n 1 -s -r -p "按任意键继续..."
        echo
    done
}

# 如果直接运行脚本，则执行main函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
