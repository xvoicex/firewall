#!/bin/bash

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用root权限运行此脚本"
    exit 1
fi

# 配置项
BACKUP_PATH="/root/backup_wordpress"
WEB_USER="www-data"
WEB_GROUP="www-data"
NGINX_SITES_PATH="/etc/nginx/sites-enabled"
BACKUP_RETAIN_DAYS=30

# 设置备份路径
[ ! -d "$BACKUP_PATH" ] && mkdir -p "$BACKUP_PATH"
chmod 700 "$BACKUP_PATH"

# 获取当前时间
current_time=$(date +"%Y%m%d_%H%M%S")

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ASCII 艺术标题
show_banner() {
    echo -e "${BLUE}"
    echo '██╗    ██╗ ██████╗ ██████╗ ██████╗ ██████╗ ██████╗ ███████╗███████╗███████╗'
    echo '██║    ██║██╔═══██╗██╔══██╗██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔════╝██╔════╝'
    echo '██║ █╗ ██║██║   ██║██████╔╝██║  ██║██████╔╝██████╔╝█████╗  ███████╗███████╗'
    echo '██║███╗██║██║   ██║██╔══██╗██║  ██║██╔═══╝ ██╔══██╗██╔══╝  ╚════██║╚════██║'
    echo '╚███╔███╔╝╚██████╔╝██║  ██║██████╔╝██║     ██║  ██║███████╗███████║███████║'
    echo ' ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝'
    echo -e "${CYAN}                      WordPress 站点管理工具 v1.1.0${NC}"
    echo -e "${PURPLE}                        作者: Vince | vinceguan@ehaitech.com${NC}"
    echo
}

# 显示进度条
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r[${YELLOW}"
    printf "%${completed}s" | tr ' ' '█'
    printf "${NC}"
    printf "%${remaining}s" | tr ' ' '░'
    printf "${NC}] %d%%" $percentage
}

# 显示分隔线
show_separator() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# 显示成功消息
show_success() {
    echo -e "\n${GREEN}✓ $1${NC}\n"
}

# 显示错误消息
show_error() {
    echo -e "\n${RED}✗ $1${NC}\n"
}

# 显示警告消息
show_warning() {
    echo -e "\n${YELLOW}⚠ $1${NC}\n"
}

# 显示信息消息
show_info() {
    echo -e "\n${BLUE}ℹ $1${NC}\n"
}

# 显示帮助信息
show_help() {
    show_banner
    echo -e "${BOLD}用法:${NC} $0 [选项]"
    echo
    echo -e "${BOLD}选项:${NC}"
    echo "  backupall    备份所有WordPress站点"
    echo "  cleanbackup  清理过期备份文件"
    echo "  -h, --help   显示此帮助信息"
    echo "  无参数       进入交互式菜单"
    echo
    show_separator
}

# 检查命令行参数
check_args() {
    case "$1" in
        backupall)
            show_banner
            check_requirements
            backup_all_sites "noask"  # 传递noask参数，表示不询问清理
            exit 0
            ;;
        cleanbackup)
            show_banner
            cleanup_old_backups
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        "")
            return
            ;;
        *)
            show_error "未知参数 '$1'"
            show_help
            exit 1
            ;;
    esac
}

# 检查必要工具
check_requirements() {
    local tools=("wget" "unzip" "tar" "mysql" "nginx" "php")
    show_info "检查系统环境..."
    
    local i=0
    local total=${#tools[@]}
    for tool in "${tools[@]}"; do
        ((i++))
        show_progress $i $total
        if ! command -v "$tool" &> /dev/null; then
            echo
            show_error "未找到 $tool"
            exit 1
        fi
        sleep 0.1
    done
    echo
    show_success "系统环境检查完成"
}

# 下载进度条
download_with_progress() {
    wget --progress=bar:force -O "$1" "$2" 2>&1
}

# 下载WordPress
download_wordpress() {
    local wp_url="https://wordpress.org/latest.zip"
    show_info "开始下载WordPress..."
    download_with_progress "wordpress_latest.zip" "$wp_url"
    show_success "WordPress下载完成"
}

# 扫描压缩包
scan_archives() {
    local found=false
    local i=1
    
    echo "发现以下压缩包："
    # 使用find命令查找并排序，然后用nl命令添加编号
    if find . -maxdepth 1 -type f \( -name "*.zip" -o -name "*.tar.gz" -o -name "*.tgz" \) -printf "%f\n" | sort | nl -w2 -s") "; then
        found=true
    fi
    
    if [ "$found" = false ]; then
        echo -e "${YELLOW}未找到压缩包${NC}"
        return 1
    fi
    
    return 0
}

# 获取文件大小（MB）
get_file_size_mb() {
    local file="$1"
    local size_bytes
    
    # 尝试使用du命令获取文件大小（更可靠）
    size_bytes=$(du -b "$file" 2>/dev/null | cut -f1)
    
    if [ -n "$size_bytes" ] && [ "$size_bytes" -eq "$size_bytes" ] 2>/dev/null; then
        echo $((size_bytes / 1024 / 1024 + 1))
        return 0
    fi
    
    show_error "无法获取文件 $file 的大小"
    return 1
}

# 检查是否为WordPress压缩包并返回解压目录
is_wordpress_archive() {
    local archive="$1"
    local target_dir="$2"
    
    show_info "正在检查压缩包..."
    
    # 确保目标目录存在
    mkdir -p "$target_dir"
    
    case "$archive" in
        *.zip)
            unzip -q "$archive" -d "$target_dir"
            ;;
        *.tar.gz|*.tgz)
            tar xzf "$archive" -C "$target_dir"
            ;;
        *)
            return 1
            ;;
    esac
    
    # 如果解压出来的是一个目录，把里面的文件移到目标目录
    local extracted_dir
    extracted_dir=$(find "$target_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -n "$extracted_dir" ]; then
        mv "$extracted_dir"/* "$target_dir/" 2>/dev/null || true
        rm -rf "$extracted_dir"
    fi
    
    # 定义WordPress特征文件
    local wp_files=(
        "wp-settings.php"
        "wp-login.php"
        "wp-admin/admin.php"
        "wp-includes/version.php"
    )
    
    # 至少要找到3个特征文件才认为是WordPress
    local found_count=0
    for file in "${wp_files[@]}"; do
        if find "$target_dir" -type f -name "$(basename "$file")" | grep -q .; then
            ((found_count++))
            show_info "找到WordPress文件: $file"
        fi
    done
    
    if [ "$found_count" -ge 3 ]; then
        show_success "确认为WordPress压缩包"
        return 0
    else
        show_error "不是有效的WordPress压缩包（只找到 $found_count 个特征文件）"
        rm -rf "$target_dir"
        return 1
    fi
}

# 解压文件
extract_archive() {
    local archive="$1"
    local target_dir="$2"
    
    # 确保目标目录存在
    mkdir -p "$target_dir"
    
    case "$archive" in
        *.zip)
            unzip -q "$archive" -d "$target_dir"
            ;;
        *.tar.gz|*.tgz)
            tar xzf "$archive" -C "$target_dir"
            ;;
    esac
    
    # 如果解压出来的是一个目录，把里面的文件移到目标目录
    local extracted_dir
    extracted_dir=$(find "$target_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -n "$extracted_dir" ]; then
        mv "$extracted_dir"/* "$target_dir/" 2>/dev/null || true
        rm -rf "$extracted_dir"
    fi
}

# 创建数据库和用户
create_database() {
    local db_name="$1"
    local db_pass=$(openssl rand -base64 12)
    
    # 删除已存在的数据库和用户
    mysql -e "DROP DATABASE IF EXISTS \`$db_name\`;"
    mysql -e "DROP USER IF EXISTS '$db_name'@'localhost';"
    
    # 创建新的数据库和用户
    mysql -e "CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4;"
    mysql -e "CREATE USER '$db_name'@'localhost' IDENTIFIED BY '$db_pass';"
    mysql -e "GRANT ALL ON \`$db_name\`.* TO '$db_name'@'localhost' WITH GRANT OPTION;"
    mysql -e "FLUSH PRIVILEGES;"
    
    echo "$db_pass"
}

# 更新wp-config.php
update_wp_config() {
    local site_path="$1"
    local db_name="$2"
    local db_user="$2"
    local db_pass="$3"
    
    local config_file="$site_path/wp-config.php"
    
    if [ ! -f "$config_file" ]; then
        show_error "未找到wp-config.php文件"
        return 1
    fi
    
    show_info "更新WordPress配置文件..."
    
    # 备份原始配置文件
    cp "$config_file" "${config_file}.bak"
    
    # 转义特殊字符，避免sed失败
    local escaped_db_name=$(echo "$db_name" | sed 's/[\&/]/\\&/g')
    local escaped_db_user=$(echo "$db_user" | sed 's/[\&/]/\\&/g')
    local escaped_db_pass=$(echo "$db_pass" | sed 's/[\&/]/\\&/g')
    
    # 使用临时文件和awk进行安全替换
    local temp_file=$(mktemp)
    
    # 检查wp-config.php的格式，适配不同版本的WordPress
    if grep -q "define('DB_NAME'" "$config_file"; then
        # 使用单引号格式 define('DB_NAME', 'xxx')
        cat "$config_file" | awk -v name="$db_name" -v user="$db_user" -v pass="$db_pass" '
            /define\([ ]*'\''DB_NAME'\''/ { print "define('\''DB_NAME'\'', '\''" name "'\'');"; next }
            /define\([ ]*'\''DB_USER'\''/ { print "define('\''DB_USER'\'', '\''" user "'\'');"; next }
            /define\([ ]*'\''DB_PASSWORD'\''/ { print "define('\''DB_PASSWORD'\'', '\''" pass "'\'');"; next }
            /define\([ ]*'\''DB_HOST'\''/ { print "define('\''DB_HOST'\'', '\''127.0.0.1'\'');"; next }
            { print }
        ' > "$temp_file"
    elif grep -q 'define("DB_NAME"' "$config_file"; then
        # 使用双引号格式 define("DB_NAME", "xxx")
        cat "$config_file" | awk -v name="$db_name" -v user="$db_user" -v pass="$db_pass" '
            /define\([ ]*"DB_NAME"/ { print "define(\"DB_NAME\", \"" name "\");"; next }
            /define\([ ]*"DB_USER"/ { print "define(\"DB_USER\", \"" user "\");"; next }
            /define\([ ]*"DB_PASSWORD"/ { print "define(\"DB_PASSWORD\", \"" pass "\");"; next }
            /define\([ ]*"DB_HOST"/ { print "define(\"DB_HOST\", \"127.0.0.1\");"; next }
            { print }
        ' > "$temp_file"
    else
        # 尝试通用匹配
        show_info "使用通用格式更新配置..."
        cat "$config_file" | awk -v name="$db_name" -v user="$db_user" -v pass="$db_pass" '
            /DB_NAME/ && /define/ { print "define(\"DB_NAME\", \"" name "\");"; next }
            /DB_USER/ && /define/ { print "define(\"DB_USER\", \"" user "\");"; next }
            /DB_PASSWORD/ && /define/ { print "define(\"DB_PASSWORD\", \"" pass "\");"; next }
            /DB_HOST/ && /define/ { print "define(\"DB_HOST\", \"127.0.0.1\");"; next }
            { print }
        ' > "$temp_file"
    fi
    
    # 应用更改
    mv "$temp_file" "$config_file"
    
    show_success "数据库配置已更新"
}

# 设置站点权限
set_permissions() {
    local site_path="$1"
    local site_name=$(basename "$site_path")
    
    show_info "正在设置 $site_name 的权限..."
    
    # 显示进度条
    echo -n "修改所有者和用户组 "
    chown -R $WEB_USER:$WEB_GROUP "$site_path" && show_success "完成" || show_error "失败"
    
    echo -n "设置目录权限 "
    find "$site_path" -type d -exec chmod 755 {} \; && show_success "完成" || show_error "失败"
    
    echo -n "设置文件权限 "
    find "$site_path" -type f -exec chmod 644 {} \; && show_success "完成" || show_error "失败"
    
    show_success "权限设置完成"
}

# 检查路径并处理重名
check_path() {
    local path="$1"
    local force="$2"  # 新增参数，表示是否强制使用指定路径
    
    # 如果指定强制使用，则不进行重命名
    if [ "$force" = "true" ]; then
        echo "$path"
        return 0
    fi
    
    # 如果路径已存在，尝试重命名
    if [ -e "$path" ]; then
        # 分离目录名和基础名
        local dir_name=$(dirname "$path")
        local base_name=$(basename "$path")
        
        # 通知用户并询问是否覆盖
        show_warning "路径 $path 已存在"
        echo -n "是否覆盖现有目录？这将删除该目录下的所有文件！[y/N] "
        read -r answer
        
        if [[ $answer =~ ^[Yy]$ ]]; then
            # 用户选择覆盖
            rm -rf "$path"
            echo "$path"
        else
            # 用户选择不覆盖，生成新名称
            local counter=1
            local new_path="${dir_name}/${base_name}_${counter}"
            
            while [ -e "$new_path" ]; do
                ((counter++))
                new_path="${dir_name}/${base_name}_${counter}"
                
                # 防止无限循环
                if [ $counter -gt 100 ]; then
                    show_error "无法为 $path 找到可用的名称"
                    return 1
                fi
            done
            
            show_info "将使用新路径: $new_path"
            echo "$new_path"
        fi
    else
        echo "$path"
    fi
    
    return 0
}

# 清理旧备份
cleanup_old_backups() {
    if [ "$BACKUP_RETAIN_DAYS" -gt 0 ]; then
        echo -e "${BLUE}清理${BACKUP_RETAIN_DAYS}天前的备份文件...${NC}"
        local old_backups=$(find "$BACKUP_PATH" -type f -name "*.tar.gz" -mtime +${BACKUP_RETAIN_DAYS})
        if [ -n "$old_backups" ]; then
            echo "将删除以下文件："
            echo "$old_backups"
            echo -n "是否继续？[y/N] "
            read -r answer
            if [[ $answer =~ ^[Yy]$ ]]; then
                find "$BACKUP_PATH" -type f -name "*.tar.gz" -mtime +${BACKUP_RETAIN_DAYS} -delete
                echo -e "${GREEN}清理完成${NC}"
            else
                echo "清理已取消"
            fi
        else
            echo "没有需要清理的备份文件"
        fi
    fi
}

# 设置安全权限
secure_path() {
    local path="$1"
    local type="$2"  # file 或 directory
    
    if [ "$type" = "file" ]; then
        chmod 600 "$path"
    elif [ "$type" = "directory" ]; then
        chmod 700 "$path"
    fi
}

# 检查目录空间
check_disk_space() {
    local path="$1"
    local required_mb="$2"
    local available_mb=$(df -m "$path" | awk 'NR==2 {print $4}')
    
    show_info "检查 $path 的可用空间..."
    echo "需要: ${required_mb}MB"
    echo "可用: ${available_mb}MB"
    
    if [ "$available_mb" -lt "$required_mb" ]; then
        show_error "目录 $path 可用空间不足"
        return 1
    fi
    show_success "空间检查通过"
    return 0
}

# 安装WordPress
install_wordpress() {
    local site_name
    local original_site_name
    echo -n "请输入站点名称: "
    read site_name
    original_site_name="$site_name"
    
    # 检查目标路径 - 使用强制模式，让用户自己决定是否覆盖
    local install_path="/var/www/$site_name"
    
    # 如果路径已存在，询问用户是否覆盖
    if [ -e "$install_path" ]; then
        show_warning "站点路径 $install_path 已存在"
        echo -n "是否覆盖现有目录？这将删除该目录下的所有文件！[y/N] "
        read -r answer
        
        if [[ $answer =~ ^[Yy]$ ]]; then
            rm -rf "$install_path"
        else
            show_error "安装已取消"
            return 1
        fi
    fi
    
    # 扫描压缩包
    if ! scan_archives; then
        echo -n "请输入WordPress下载链接(直接回车使用官方包): "
        read download_url
        if [ -z "$download_url" ]; then
            download_wordpress
        else
            download_with_progress "wordpress.zip" "$download_url"
        fi
        scan_archives
    fi
    
    # 获取排序后的压缩包列表
    mapfile -t archives < <(find . -maxdepth 1 -type f \( -name "*.zip" -o -name "*.tar.gz" -o -name "*.tgz" \) -printf "%f\n" | sort)
    
    select archive in "${archives[@]}"; do
        if [ -n "$archive" ]; then
            # 获取压缩包大小并计算所需空间
            local archive_size_mb
            if ! archive_size_mb=$(get_file_size_mb "$archive"); then
                return 1
            fi
            
            # 预估解压后大小（约1.5倍）和额外所需空间
            local required_space_mb=$((archive_size_mb * 15 / 10 + 50))
            
            show_info "压缩包大小: ${archive_size_mb}MB"
            show_info "预计所需空间: ${required_space_mb}MB（包含解压和运行所需空间）"
            
            # 检查/var/www目录空间
            if ! check_disk_space "/var/www" "$required_space_mb"; then
                return 1
            fi
            
            # 检查临时目录空间（需要原始大小加解压空间）
            if ! check_disk_space "/tmp" "$((archive_size_mb * 2))"; then
                return 1
            fi
            
            # 解压并创建目标目录
            show_info "正在解压文件..."
            mkdir -p "$install_path"
            
            case "$archive" in
                *.zip)
                    unzip -q "$archive" -d "$install_path"
                    ;;
                *.tar.gz|*.tgz)
                    tar xzf "$archive" -C "$install_path"
                    ;;
                *)
                    show_error "不支持的压缩包格式"
                    return 1
                    ;;
            esac
            
            # 如果解压出来的是一个目录，把里面的文件移到目标目录
            local extracted_dir
            extracted_dir=$(find "$install_path" -mindepth 1 -maxdepth 1 -type d | head -n 1)
            if [ -n "$extracted_dir" ]; then
                mv "$extracted_dir"/* "$install_path/" 2>/dev/null || true
                rm -rf "$extracted_dir"
            fi
            
            # 验证是否包含WordPress文件
            show_info "验证WordPress文件..."
            local wp_files=("wp-settings.php" "wp-login.php" "wp-admin/admin.php" "wp-includes/version.php")
            local found_count=0
            
            for file in "${wp_files[@]}"; do
                if find "$install_path" -type f -name "$(basename "$file")" | grep -q .; then
                    ((found_count++))
                    show_info "找到WordPress文件: $file"
                fi
            done
            
            if [ "$found_count" -lt 3 ]; then
                show_error "不是有效的WordPress压缩包（只找到 $found_count 个特征文件）"
                rm -rf "$install_path"
                return 1
            fi
            
            show_success "确认为WordPress压缩包"
            
            # 查找SQL文件
            show_info "正在搜索SQL文件..."
            local sql_file=""
            
            # 在WordPress目录中查找SQL文件
            local wp_sql_files=()
            while IFS= read -r -d '' file; do
                wp_sql_files+=("$file")
            done < <(find "$install_path" -type f -name "*.sql" -print0)
            
            # 在WordPress目录中查找zip文件
            local wp_zip_files=()
            while IFS= read -r -d '' file; do
                wp_zip_files+=("$file")
            done < <(find "$install_path" -type f -name "*.zip" -print0)
            
            # 如果WordPress目录中有SQL文件
            if [ ${#wp_sql_files[@]} -gt 0 ]; then
                echo "在WordPress目录中发现以下SQL文件："
                for i in "${!wp_sql_files[@]}"; do
                    echo "$((i+1))) ${wp_sql_files[$i]}"
                done
                echo -n "请选择要导入的SQL文件编号 [1-${#wp_sql_files[@]}]: "
                read choice
                if [ -n "$choice" ] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#wp_sql_files[@]}" ]; then
                    sql_file="${wp_sql_files[$((choice-1))]}"
                    show_success "已选择SQL文件: $sql_file"
                fi
            # 如果WordPress目录中有zip文件，检查其中是否有SQL文件
            elif [ ${#wp_zip_files[@]} -gt 0 ]; then
                echo "在WordPress目录中发现以下ZIP文件："
                for i in "${!wp_zip_files[@]}"; do
                    echo "$((i+1))) ${wp_zip_files[$i]}"
                done
                echo -n "是否检查ZIP文件中的SQL文件？[y/N]: "
                read answer
                if [[ $answer =~ ^[Yy]$ ]]; then
                    echo -n "请选择要检查的ZIP文件编号 [1-${#wp_zip_files[@]}]: "
                    read choice
                    if [ -n "$choice" ] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#wp_zip_files[@]}" ]; then
                        local zip_file="${wp_zip_files[$((choice-1))]}"
                        local zip_temp_dir=$(mktemp -d)
                        
                        # 解压zip文件
                        unzip -q "$zip_file" -d "$zip_temp_dir"
                        
                        # 在解压的zip文件中查找SQL文件
                        local zip_sql_files=()
                        while IFS= read -r -d '' file; do
                            zip_sql_files+=("$file")
                        done < <(find "$zip_temp_dir" -type f -name "*.sql" -print0)
                        
                        if [ ${#zip_sql_files[@]} -gt 0 ]; then
                            echo "在ZIP文件中发现以下SQL文件："
                            for i in "${!zip_sql_files[@]}"; do
                                echo "$((i+1))) ${zip_sql_files[$i]}"
                            done
                            echo -n "请选择要导入的SQL文件编号 [1-${#zip_sql_files[@]}]: "
                            read zip_choice
                            if [ -n "$zip_choice" ] && [ "$zip_choice" -ge 1 ] && [ "$zip_choice" -le "${#zip_sql_files[@]}" ]; then
                                sql_file="${zip_sql_files[$((zip_choice-1))]}"
                                local sql_basename=$(basename "$sql_file")
                                cp "$sql_file" "$install_path/$sql_basename"
                                sql_file="$install_path/$sql_basename"
                                show_success "已从ZIP文件提取SQL文件: $sql_basename"
                            fi
                        else
                            show_warning "ZIP文件中未找到SQL文件"
                        fi
                        
                        # 清理临时目录
                        rm -rf "$zip_temp_dir"
                    fi
                fi
            # 如果WordPress目录和Zip文件中都没有找到SQL文件，则再检查压缩包
            else
                show_info "在WordPress目录中未找到SQL文件，检查原始压缩包..."
                
                # 创建临时目录
                local temp_dir=$(mktemp -d)
                
                case "$archive" in
                    *.zip)
                        # 列出SQL文件
                        unzip -l "$archive" | grep -i "\.sql$" > "$temp_dir/sql_list"
                        if [ -s "$temp_dir/sql_list" ]; then
                            echo "在压缩包中发现以下SQL文件："
                            cat "$temp_dir/sql_list" | awk '{print NR") " $4}'
                            echo -n "请选择要导入的SQL文件编号 [1-$(wc -l < "$temp_dir/sql_list")]: "
                            read choice
                            if [ -n "$choice" ]; then
                                sql_name=$(sed -n "${choice}p" "$temp_dir/sql_list" | awk '{print $4}')
                                unzip -j "$archive" "$sql_name" -d "$temp_dir" >/dev/null
                                if [ -f "$temp_dir/$(basename "$sql_name")" ]; then
                                    cp "$temp_dir/$(basename "$sql_name")" "$install_path/"
                                    sql_file="$install_path/$(basename "$sql_name")"
                                    show_success "已提取SQL文件: $(basename "$sql_name")"
                                fi
                            fi
                        fi
                        ;;
                    *.tar.gz|*.tgz)
                        # 列出SQL文件
                        tar tzf "$archive" | grep -i "\.sql$" > "$temp_dir/sql_list"
                        if [ -s "$temp_dir/sql_list" ]; then
                            echo "在压缩包中发现以下SQL文件："
                            nl "$temp_dir/sql_list"
                            echo -n "请选择要导入的SQL文件编号 [1-$(wc -l < "$temp_dir/sql_list")]: "
                            read choice
                            if [ -n "$choice" ]; then
                                sql_name=$(sed -n "${choice}p" "$temp_dir/sql_list")
                                tar xzf "$archive" -C "$temp_dir" "$sql_name" 2>/dev/null
                                if [ -f "$temp_dir/$sql_name" ]; then
                                    mkdir -p "$install_path/$(dirname "$sql_name")"
                                    cp "$temp_dir/$sql_name" "$install_path/$(basename "$sql_name")"
                                    sql_file="$install_path/$(basename "$sql_name")"
                                    show_success "已提取SQL文件: $(basename "$sql_name")"
                                fi
                            fi
                        fi
                        ;;
                esac
                
                # 清理临时目录
                rm -rf "$temp_dir"
            fi
            
            if [ -z "$sql_file" ]; then
                show_warning "未找到SQL文件，是否继续安装？[y/N]"
                read -r answer
                if [[ ! $answer =~ ^[Yy]$ ]]; then
                    rm -rf "$install_path"
                    return 1
                fi
            fi
            
            # 创建数据库（使用原始站点名）
            show_info "创建数据库..."
            local db_pass=$(create_database "$original_site_name")
            
            # 导入数据库
            if [ -n "$sql_file" ] && [ -f "$sql_file" ]; then
                show_info "正在导入数据库..."
                if mysql "$original_site_name" < "$sql_file" 2>/tmp/mysql_error; then
                    show_success "数据库导入成功：$sql_file"
                else
                    show_error "数据库导入失败，错误信息："
                    cat /tmp/mysql_error
                    rm -f /tmp/mysql_error
                    return 1
                fi
                rm -f /tmp/mysql_error
                # 清理SQL文件
                rm -f "$sql_file"
            else
                show_warning "没有SQL文件需要导入"
            fi
            
            # 更新wp-config.php
            if [ -f "$install_path/wp-config.php" ]; then
                update_wp_config "$install_path" "$original_site_name" "$db_pass"
            else
                show_warning "未找到wp-config.php文件，请手动配置数据库信息"
            fi
            
            show_info "数据库信息如下："
            echo "数据库名: $original_site_name"
            echo "数据库用户: $original_site_name"
            echo "数据库密码: $db_pass"
            echo "数据库主机: 127.0.0.1"
            
            # 设置权限
            set_permissions "$install_path"
            
            # 配置Nginx
            echo "选择要复制的Nginx配置模板："
            local configs=("$NGINX_SITES_PATH"/*.conf)
            select config in "${configs[@]}"; do
                if [ -n "$config" ]; then
                    local nginx_conf="$NGINX_SITES_PATH/$site_name.conf"
                    
                    # 如果配置文件已存在，询问是否覆盖
                    if [ -e "$nginx_conf" ]; then
                        show_warning "Nginx配置文件 $nginx_conf 已存在"
                        echo -n "是否覆盖？[y/N] "
                        read -r answer
                        if [[ ! $answer =~ ^[Yy]$ ]]; then
                            show_error "Nginx配置已取消"
                            return 1
                        fi
                    fi
                    
                    cp "$config" "$nginx_conf"
                    sed -i "s|root .*|root $install_path;|" "$nginx_conf"
                    sed -i "s|access_log .*|access_log /var/log/nginx/$site_name.access.log;|" "$nginx_conf"
                    sed -i "s|error_log .*|error_log /var/log/nginx/$site_name.error.log;|" "$nginx_conf"
                    secure_path "$nginx_conf" "file"
                    break
                fi
            done
            
            # 重启Nginx
            systemctl reload nginx
            
            show_success "WordPress安装完成"
            echo "站点URL: http://$site_name"
            echo "数据库名: $original_site_name"
            echo "数据库用户: $original_site_name"
            echo "数据库密码: $db_pass"
            break
        fi
    done
}

# 备份单个站点
backup_single_site() {
    local site_path="$1"
    local site_name=$(basename "$site_path")
    local is_batch="$2"  # 新增参数，表示是否为批量备份
    
    echo -e "${YELLOW}正在备份 $site_name...${NC}"
    
    # 获取数据库信息
    local config_file="$site_path/wp-config.php"
    
    if [ ! -f "$config_file" ]; then
        show_error "未找到wp-config.php文件"
        return 1
    fi
    
    local db_name=$(grep "DB_NAME" "$config_file" | cut -d "'" -f 4)
    local db_user=$(grep "DB_USER" "$config_file" | cut -d "'" -f 4)
    local db_pass=$(grep "DB_PASSWORD" "$config_file" | cut -d "'" -f 4)
    
    # 备份数据库
    local backup_file="$BACKUP_PATH/${site_name}-${current_time}.tar.gz"
    
    # 如果备份文件已存在，询问是否覆盖
    if [ -e "$backup_file" ]; then
        show_warning "备份文件 $backup_file 已存在"
        echo -n "是否覆盖？[y/N] "
        read -r answer
        if [[ ! $answer =~ ^[Yy]$ ]]; then
            show_error "备份已取消"
            return 1
        fi
    fi
    
    mysqldump -u"$db_user" -p"$db_pass" "$db_name" > "$site_path/$site_name.sql"
    
    # 打包站点
    cd /var/www
    tar czf "$backup_file" "$site_name"
    secure_path "$backup_file" "file"
    
    # 清理SQL文件
    rm -f "$site_path/$site_name.sql"
    
    echo -e "${GREEN}$site_name 备份完成${NC}"
    
    # 只在非批量备份时询问是否清理旧备份
    if [ "$is_batch" != "true" ]; then
        echo -n "是否清理旧备份文件？[y/N] "
        read -r answer
        if [[ $answer =~ ^[Yy]$ ]]; then
            cleanup_old_backups
        fi
    fi
}

# 备份所有站点
backup_all_sites() {
    show_info "开始备份所有WordPress站点..."
    local site_count=0
    local success_count=0
    
    # 计算站点数量
    for site_path in /var/www/*/; do
        if [ -f "$site_path/wp-config.php" ]; then
            ((site_count++))
        fi
    done
    
    if [ $site_count -eq 0 ]; then
        show_warning "未找到WordPress站点"
        return 0
    fi
    
    show_info "找到 $site_count 个WordPress站点"
    
    # 备份所有站点
    local current=0
    for site_path in /var/www/*/; do
        if [ -f "$site_path/wp-config.php" ]; then
            ((current++))
            show_info "[$current/$site_count] 备份站点: $(basename "$site_path")"
            if backup_single_site "$site_path" "true"; then
                ((success_count++))
            fi
        fi
    done
    
    show_success "备份完成: $success_count/$site_count 个站点备份成功"
    
    # 只在所有站点备份完成后，询问一次是否清理
    if [ "$1" != "noask" ]; then
        echo -n "是否清理旧备份文件？[y/N] "
        read -r answer
        if [[ $answer =~ ^[Yy]$ ]]; then
            cleanup_old_backups
        fi
    fi
}

# 还原站点
restore_site() {
    # 扫描备份文件
    echo "可用的备份："
    local sites=()
    for backup in "$BACKUP_PATH"/*.tar.gz; do
        local site_name=$(basename "$backup" | cut -d'-' -f1)
        if [[ ! " ${sites[@]} " =~ " ${site_name} " ]]; then
            sites+=("$site_name")
        fi
    done
    
    select site in "${sites[@]}"; do
        if [ -n "$site" ]; then
            echo "选择 $site 的备份版本："
            local backups=("$BACKUP_PATH/${site}-"*.tar.gz)
            select backup in "${backups[@]}"; do
                if [ -n "$backup" ]; then
                    # 解压备份
                    local temp_dir=$(mktemp -d)
                    tar xzf "$backup" -C "$temp_dir"
                    
                    # 获取SQL文件
                    local sql_file=$(find "$temp_dir/$site" -name "*.sql" -type f)
                    
                    if [ -n "$sql_file" ]; then
                        # 创建数据库
                        local db_pass=$(create_database "$site")
                        
                        # 导入数据库
                        show_info "正在导入数据库..."
                        if mysql "$site" < "$sql_file" 2>/tmp/mysql_error; then
                            show_success "数据库导入成功：$sql_file"
                        else
                            show_error "数据库导入失败，错误信息："
                            cat /tmp/mysql_error
                            rm -f /tmp/mysql_error
                            return 1
                        fi
                        rm -f /tmp/mysql_error
                        
                        # 更新配置
                        show_info "更新WordPress配置..."
                        update_wp_config "$temp_dir/$site" "$site" "$db_pass"
                    fi
                    
                    # 移动到最终位置
                    rm -rf "/var/www/$site"
                    mv "$temp_dir/$site" "/var/www/"
                    
                    # 设置权限
                    set_permissions "/var/www/$site"
                    
                    show_success "站点 $site 还原完成"
                    break
                fi
            done
            break
        fi
    done
}

# 主菜单
main_menu() {
    while true; do
        show_banner
        echo -e "${BOLD}主菜单${NC}"
        echo
        echo -e "${CYAN}1)${NC} 下载WordPress"
        echo -e "${CYAN}2)${NC} 安装WordPress"
        echo -e "${CYAN}3)${NC} 备份WordPress"
        echo -e "${CYAN}4)${NC} 还原WordPress"
        echo -e "${CYAN}5)${NC} 清理旧备份"
        echo -e "${CYAN}0)${NC} 退出"
        echo
        show_separator
        
        echo -n "请选择操作 [0-5]: "
        read choice
        
        case $choice in
            1)
                show_separator
                download_wordpress
                ;;
            2)
                show_separator
                install_wordpress
                ;;
            3)
                show_separator
                echo -e "${BOLD}备份选项:${NC}"
                echo -e "${CYAN}1)${NC} 备份所有站点"
                echo -e "${CYAN}2)${NC} 备份单个站点"
                echo
                echo -n "请选择 [1-2]: "
                read backup_choice
                case $backup_choice in
                    1)
                        backup_all_sites
                        ;;
                    2)
                        echo "选择要备份的站点："
                        select site_path in /var/www/*/; do
                            if [ -f "$site_path/wp-config.php" ]; then
                                backup_single_site "$site_path"
                                break
                            fi
                        done
                        ;;
                esac
                ;;
            4)
                show_separator
                restore_site
                ;;
            5)
                show_separator
                cleanup_old_backups
                ;;
            0)
                echo -e "${BLUE}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                ;;
        esac
    done
}

# 检查环境要求
check_requirements

# 检查命令行参数
check_args "$1"

# 启动主菜单
main_menu 
