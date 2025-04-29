#!/bin/bash

# WordPress 数据库内容扫描工具
# 一键扫描WordPress站点数据库中的违规内容

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # 无颜色

# 字体样式
BOLD='\033[1m'
UNDERLINE='\033[4m'

# 版本信息
VERSION="1.0.5"

# 默认值
OUTPUT_DIR="$(pwd)/wp_scan_results_$(date +%Y%m%d_%H%M%S)"
LOG_LEVEL=1  # 0=禁止输出, 1=正常, 2=详细, 3=调试
LOG_TO_CONSOLE=1  # 1=输出到控制台, 0=只输出到日志文件

# 用于存储站点URL和名称的关联数组
declare -A SITE_URLS
declare -A SITE_NAMES
declare -A DB_CONNECTIONS

# 违规关键词列表
PORN_KEYWORDS=(
    "色情" "淫" "性爱" "做爱" "口交" "肛交" "乳交" "群交" "嫖娼" "妓女" "卖淫"
    "porn" "xxx" "pussy" "dick" "cock" "tits" "boobs" "masturbation"
    "webcam girl" "escort" "stripper" "call girl" "prostitute"
)

GAMBLE_KEYWORDS=(
    "赌博" "博彩" "彩票" "赌场" "投注" "下注" "娱乐城" "网上赌场" "百家乐"
    "gambling" "casino" "lottery" "poker" "slots" "roulette" "blackjack"
    "bookmaker" "sportsbook" "wager"
)

AD_KEYWORDS=(
    "代理" "推广" "推销" "佣金" "联盟"
    "advertise" "click here" "cheap" "best price"
    "buy now" "earn money" "make money"
)

SUSPICIOUS_DOMAINS=(
    ".bet" ".casino" ".porn" ".sex" ".xxx"
)

# 显示横幅
show_banner() {
    echo -e "${CYAN}"
    echo -e "██╗    ██╗██████╗     ███████╗ ██████╗ █████╗ ███╗   ██╗"
    echo -e "██║    ██║██╔══██╗    ██╔════╝██╔════╝██╔══██╗████╗  ██║"
    echo -e "██║ █╗ ██║██████╔╝    ███████╗██║     ███████║██╔██╗ ██║"
    echo -e "██║███╗██║██╔═══╝     ╚════██║██║     ██╔══██║██║╚██╗██║"
    echo -e "╚███╔███╔╝██║         ███████║╚██████╗██║  ██║██║ ╚████║"
    echo -e " ╚══╝╚══╝ ╚═╝         ╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═══╝"
    echo -e "                                                       "
    echo -e "${WHITE}${BOLD}WordPress 数据库内容扫描工具 v${VERSION}${NC}"
    echo -e "${BLUE}一键扫描WordPress站点数据库中的违规内容${NC}"
    echo -e "=============================================================="
    echo ""
}

# 记录日志
log() {
    if [ "$LOG_TO_CONSOLE" -eq 1 ]; then
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
    fi
}

# 记录错误日志
log_error() {
    if [ "$LOG_LEVEL" -ge 0 ] && [ "$LOG_TO_CONSOLE" -eq 1 ]; then
        echo -e "${RED}[✗] $1${NC}" >&2
    fi
}

# 记录成功日志
log_success() {
    if [ "$LOG_LEVEL" -ge 1 ] && [ "$LOG_TO_CONSOLE" -eq 1 ]; then
        echo -e "${GREEN}[✓] $1${NC}" >&2
    fi
}

# 记录警告日志
log_warning() {
    if [ "$LOG_LEVEL" -ge 1 ] && [ "$LOG_TO_CONSOLE" -eq 1 ]; then
        echo -e "${YELLOW}[!] $1${NC}" >&2
    fi
}

# 记录信息日志
log_info() {
    if [ "$LOG_LEVEL" -ge 1 ] && [ "$LOG_TO_CONSOLE" -eq 1 ]; then
        echo -e "${BLUE}[i] $1${NC}" >&2
    fi
}

# 记录详细日志
log_debug() {
    if [ "$LOG_LEVEL" -ge 3 ] && [ "$LOG_TO_CONSOLE" -eq 1 ]; then
        echo -e "${CYAN}[D] $1${NC}" >&2
    fi
}

# 分隔线
print_separator() {
    if [ "$LOG_TO_CONSOLE" -eq 1 ]; then
        echo -e "${BLUE}------------------------------------------------------------${NC}" >&2
    fi
}

# 进度条
show_progress() {
    if [ "$LOG_TO_CONSOLE" -eq 1 ]; then
        local current=$1
        local total=$2
        local percent=$((current * 100 / total))
        local filled=$((percent / 2))
        local empty=$((50 - filled))
        
        # 使用\r回到行首，覆盖之前的进度条
        printf "\r${WHITE}[${GREEN}" >&2
        for ((i=0; i<filled; i++)); do
            printf "█" >&2
        done
        
        for ((i=0; i<empty; i++)); do
            printf "${WHITE}░" >&2
        done
        
        printf "${WHITE}] ${percent}%%${NC}" >&2
        # 不添加换行符，确保进度条在同一行更新
    fi
}

# 写入报告内容，确保没有ANSI颜色代码
write_to_report() {
    local report_file="$1"
    local content="$2"
    # 移除所有ANSI颜色代码
    local clean_content=$(echo "$content" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
    echo "$clean_content" >> "$report_file"
}

# 清理ANSI颜色代码
clean_ansi_codes() {
    echo "$1" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" | grep -v "mysql: \[Warning\]"
}

# 获取站点URL的多种方式 - 无调试版
get_site_url_clean() {
    local site_path="$1"
    local db_prefix="$2"
    local site_url=""
    local domain_name=""
    
    # 方法1: 从数据库获取
    if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
        log_info "尝试从数据库获取站点URL (表: ${db_prefix}options)..."
        
        # 直接使用精确匹配查询siteurl选项，使用无日志版本
        local url_query="SELECT option_value FROM ${db_prefix}options WHERE option_name = 'siteurl';"
        site_url=$(run_mysql_query_silent "$url_query")
        
        if [ -n "$site_url" ]; then
            log_success "从数据库成功获取到站点URL: $site_url"
        else
            log_warning "未找到siteurl选项，尝试查询home选项..."
            
            # 尝试查询home选项
            local home_query="SELECT option_value FROM ${db_prefix}options WHERE option_name = 'home';"
            site_url=$(run_mysql_query_silent "$home_query")
            
            if [ -n "$site_url" ]; then
                log_success "从数据库的home选项获取到站点URL: $site_url"
            else
                # 尝试其他获取方法
                log_info "尝试获取options表中所有与URL相关的选项..."
                local all_urls_query="SELECT option_id, option_name, option_value FROM ${db_prefix}options WHERE option_name LIKE '%url%' OR option_name LIKE '%site%';"
                local all_urls=$(run_mysql_query_silent "$all_urls_query")
                
                if [ -n "$all_urls" ]; then
                    log_debug "找到URL相关选项: $all_urls"
                    
                    # 尝试提取第一个URL
                    local first_url=$(echo "$all_urls" | grep -o "http[s]*://[^ ]*" | head -1)
                    if [ -n "$first_url" ]; then
                        site_url="$first_url"
                        log_success "从相关选项中提取到URL: $site_url"
                    fi
                fi
            fi
        fi
    fi
    
    # 如果从数据库获取URL失败，尝试其他方法
    if [ -z "$site_url" ]; then
        log_info "从数据库获取URL失败，尝试从配置文件获取..."
        local wp_config="${site_path}/wp-config.php"
        if [ -f "$wp_config" ]; then
            local defined_url=$(grep -o "define.*WP_HOME.*['\"].*['\"]" "$wp_config" | sed -E "s/.*['\"](.*)['\"]/\1/")
            if [ -n "$defined_url" ]; then
                site_url="$defined_url"
                log_success "从wp-config.php的WP_HOME获取到URL: $site_url"
            else
                defined_url=$(grep -o "define.*WP_SITEURL.*['\"].*['\"]" "$wp_config" | sed -E "s/.*['\"](.*)['\"]/\1/")
                if [ -n "$defined_url" ]; then
                    site_url="$defined_url"
                    log_success "从wp-config.php的WP_SITEURL获取到URL: $site_url"
                fi
            fi
        fi
    fi
    
    # 方法2: 检查index.php中的重定向
    if [ -z "$site_url" ]; then
        log_info "尝试从index.php获取重定向URL..."
        local index_php="${site_path}/index.php"
        if [ -f "$index_php" ]; then
            local redirect_url=$(grep -o "wp_redirect.*['\"].*['\"]" "$index_php" | head -1 | sed -E "s/.*['\"](.*)['\"]/\1/")
            if [ -n "$redirect_url" ]; then
                site_url="$redirect_url"
                log_success "从index.php中获取到重定向URL: $site_url"
            fi
        fi
    fi
    
    # 方法3: 从.htaccess获取重定向规则
    if [ -z "$site_url" ]; then
        log_info "尝试从.htaccess获取URL..."
        local htaccess="${site_path}/.htaccess"
        if [ -f "$htaccess" ]; then
            local htaccess_url=$(grep -o "RewriteRule.*/index\.php \[R=301,L\]" "$htaccess" | sed -E "s/.*http(s)?:\/\/([^\/]+).*/http\1:\/\/\2/")
            if [ -n "$htaccess_url" ]; then
                site_url="$htaccess_url"
                log_success "从.htaccess获取到URL: $site_url"
            fi
        fi
    fi
    
    # 方法4: 如果还是获取不到，从目录名猜测
    if [ -z "$site_url" ]; then
        # 获取目录名作为可能的域名名称
        local dir_name=$(basename "$site_path")
        if [[ "$dir_name" =~ [a-zA-Z0-9]+ ]]; then
            # 假设域名是目录名加.com
            site_url="http://${dir_name}.com"
            log_warning "无法从任何途径获取站点URL，使用目录名猜测: $site_url"
        else
            # 最后的后备选项
            site_url="未知URL"
            log_error "无法获取站点URL，设置为未知URL"
        fi
    fi
    
    # 从URL中提取域名
    if [ "$site_url" != "未知URL" ]; then
        domain_name=$(echo "$site_url" | sed -E 's/https?:\/\///' | sed -E 's/\/.*//')
        log_info "从URL提取出域名: $domain_name"
    else
        domain_name="未知域名"
    fi
    
    # 返回结果
    echo "$site_url|$domain_name"
}

# 执行MySQL查询 - 带日志输出
run_mysql_query() {
    local query="$1"
    local result=""
    
    # 输出查询信息用于调试
    log_debug "执行SQL查询: ${CYAN}$query${NC}"
    log_debug "连接信息: 主机=${CYAN}${DB_HOST}${NC}, 用户=${CYAN}${DB_USER}${NC}, 数据库=${CYAN}${DB_NAME}${NC}"
    
    # 分离标准输出和错误输出
    if [ -z "$DB_PASS" ]; then
        result=$(mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -e "$query" 2>mysql_errors.tmp)
    else
        result=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "$query" 2>mysql_errors.tmp)
    fi
    
    # 处理错误但不影响结果
    local error_msg=$(cat mysql_errors.tmp)
    rm -f mysql_errors.tmp
    
    # 检查查询是否成功
    if [[ $? -ne 0 ]]; then
        if [ -n "$error_msg" ]; then
            log_error "MySQL查询失败: $(echo "$error_msg" | grep -v 'Warning.*password')"
        else
            log_error "MySQL查询失败"
        fi
        return 1
    fi
    
    # 仅针对控制台报告结果统计
    if [ -n "$result" ]; then
        log_success "查询成功，返回 $(echo "$result" | wc -l) 行结果"
        if [ "$LOG_LEVEL" -ge 2 ]; then
            log_debug "结果示例: ${CYAN}$(echo "$result" | head -n 1)${NC}"
        fi
    else
        log_warning "查询成功但返回空结果"
    fi
    
    # 返回原始结果
    echo "$result"
}

# 执行MySQL查询 - 无日志版本
run_mysql_query_silent() {
    local query="$1"
    local result=""
    
    # 静默执行查询，仅返回结果
    if [ -z "$DB_PASS" ]; then
        result=$(mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -e "$query" 2>/dev/null)
    else
        result=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "$query" 2>/dev/null)
    fi
    
    # 检查是否成功，但不输出任何调试信息
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    echo "$result"
}

# 解析WordPress配置文件
parse_wp_config() {
    local wp_config="$1"
    
    # 检查文件是否存在
    if [ ! -f "$wp_config" ]; then
        log_error "WordPress配置文件不存在: $wp_config"
        return 1
    fi
    
    log_info "正在解析 WordPress 配置文件: $wp_config"
    
    # 提取数据库名称
    DB_NAME=$(grep -o "define.*DB_NAME.*'.*'" "$wp_config" | sed -E "s/.*'(.*)'.*/\1/")
    if [ -z "$DB_NAME" ]; then
        log_error "无法从配置文件中提取数据库名称"
        return 1
    fi
    
    # 提取数据库用户
    DB_USER=$(grep -o "define.*DB_USER.*'.*'" "$wp_config" | sed -E "s/.*'(.*)'.*/\1/")
    if [ -z "$DB_USER" ]; then
        log_error "无法从配置文件中提取数据库用户"
        return 1
    fi
    
    # 提取数据库密码
    DB_PASS=$(grep -o "define.*DB_PASSWORD.*'.*'" "$wp_config" | sed -E "s/.*'(.*)'.*/\1/")
    
    # 提取数据库主机
    DB_HOST=$(grep -o "define.*DB_HOST.*'.*'" "$wp_config" | sed -E "s/.*'(.*)'.*/\1/")
    if [ -z "$DB_HOST" ]; then
        log_warning "未指定数据库主机，使用默认值: localhost"
        DB_HOST="localhost"
    fi
    
    # 提取表前缀 - 修复解析方式
    local prefix_line=$(grep '$table_prefix' "$wp_config")
    if [ -n "$prefix_line" ]; then
        DB_PREFIX=$(echo "$prefix_line" | sed -E "s/.*'(.*)'.*/\1/")
        # 如果提取失败，使用默认值
        if [ -z "$DB_PREFIX" ]; then
            log_warning "无法解析表前缀，使用默认值: wp_"
            DB_PREFIX="wp_"
        fi
    else
        log_warning "未找到表前缀设置，使用默认值: wp_"
        DB_PREFIX="wp_"
    fi
    
    # 存储当前站点的数据库连接信息
    DB_CONNECTIONS["$wp_config"]="$DB_NAME:$DB_USER:$DB_PASS:$DB_HOST:$DB_PREFIX"
    
    log_success "配置解析成功: 数据库=${CYAN}${DB_NAME}${NC}, 表前缀=${CYAN}${DB_PREFIX}${NC}"
    return 0
}

# 构建关键词搜索SQL查询
build_search_query() {
    local table="$1"
    local column="$2"
    local keywords=("${@:3}")
    local query=""
    local conditions=""
    
    for keyword in "${keywords[@]}"; do
        if [ -n "$conditions" ]; then
            conditions+=" OR "
        fi
        conditions+="${column} LIKE '%${keyword}%'"
    done
    
    query="SELECT * FROM ${table} WHERE (${conditions}) LIMIT 100;"
    echo "$query"
}

# 扫描数据库表中的违规内容
scan_table() {
    local table="$1"
    local column="$2"
    local description="$3"
    local report_file="$4"
    local site_url="$5"
    local violations_found_table=0
    
    # 根据不同表类型确定额外字段，便于更好地显示结果上下文
    local context_columns=""
    local content_column="$column"
    
    # 为不同表设置不同的额外显示字段，提供更多上下文
    case "$table" in
        *posts)
            # 对于文章表，显示ID、标题和状态
            context_columns="ID, post_title, post_status"
            ;;
        *postmeta)
            # 对于文章元数据表，显示元数据ID、文章ID和元数据键名
            context_columns="meta_id, post_id, meta_key"
            ;;
        *options)
            # 对于选项表，显示选项ID和选项名
            context_columns="option_id, option_name"
            ;;
        *comments)
            # 对于评论表，显示评论ID、评论者和评论状态
            context_columns="comment_ID, comment_author, comment_approved"
            ;;
        *usermeta)
            # 对于用户元数据表，显示元数据ID、用户ID和元数据键名
            context_columns="umeta_id, user_id, meta_key"
            ;;
        *users)
            # 对于用户表，显示用户ID、登录名和昵称
            context_columns="ID, user_login, user_nicename"
            ;;
        *)
            # 默认情况下不添加额外字段
            context_columns=""
            ;;
    esac
    
    # 扫描色情内容
    local porn_query=""
    if [ -n "$context_columns" ]; then
        porn_query="SELECT $context_columns, SUBSTRING($content_column, 1, 200) as content_preview FROM $table WHERE ("
    else
        porn_query="SELECT SUBSTRING($content_column, 1, 200) as content_preview FROM $table WHERE ("
    fi
    
    local conditions=""
    for keyword in "${PORN_KEYWORDS[@]}"; do
        if [ -n "$conditions" ]; then
            conditions+=" OR "
        fi
        conditions+="$content_column LIKE '%${keyword}%'"
    done
    
    porn_query+="$conditions) LIMIT 20;"
    local porn_results=$(run_mysql_query "$porn_query")
    
    # 扫描赌博内容（类似方式）
    local gamble_query=""
    if [ -n "$context_columns" ]; then
        gamble_query="SELECT $context_columns, SUBSTRING($content_column, 1, 200) as content_preview FROM $table WHERE ("
    else
        gamble_query="SELECT SUBSTRING($content_column, 1, 200) as content_preview FROM $table WHERE ("
    fi
    
    conditions=""
    for keyword in "${GAMBLE_KEYWORDS[@]}"; do
        if [ -n "$conditions" ]; then
            conditions+=" OR "
        fi
        conditions+="$content_column LIKE '%${keyword}%'"
    done
    
    gamble_query+="$conditions) LIMIT 20;"
    local gamble_results=$(run_mysql_query "$gamble_query")
    
    # 扫描广告内容（类似方式）
    local ad_query=""
    if [ -n "$context_columns" ]; then
        ad_query="SELECT $context_columns, SUBSTRING($content_column, 1, 200) as content_preview FROM $table WHERE ("
    else
        ad_query="SELECT SUBSTRING($content_column, 1, 200) as content_preview FROM $table WHERE ("
    fi
    
    conditions=""
    for keyword in "${AD_KEYWORDS[@]}"; do
        if [ -n "$conditions" ]; then
            conditions+=" OR "
        fi
        conditions+="$content_column LIKE '%${keyword}%'"
    done
    
    ad_query+="$conditions) LIMIT 20;"
    local ad_results=$(run_mysql_query "$ad_query")
    
    # 扫描可疑域名
    local domain_query=""
    if [ -n "$context_columns" ]; then
        domain_query="SELECT $context_columns, SUBSTRING($content_column, 1, 200) as content_preview FROM $table WHERE ("
    else
        domain_query="SELECT SUBSTRING($content_column, 1, 200) as content_preview FROM $table WHERE ("
    fi
    
    conditions=""
    for domain in "${SUSPICIOUS_DOMAINS[@]}"; do
        if [ -n "$conditions" ]; then
            conditions+=" OR "
        fi
        conditions+="$content_column LIKE '%${domain}%'"
    done
    
    domain_query+="$conditions) LIMIT 20;"
    local domain_results=$(run_mysql_query "$domain_query")
    
    # 处理结果，避免乱码
    if [ -n "$porn_results" ]; then
        echo -e "\n${RED}${BOLD}=== 疑似色情内容 (${description}) ===${NC}" >> "$report_file"
        echo -e "表: $table, 字段: $column\n" >> "$report_file"
        
        # 格式化结果，每行一个记录，以避免乱码
        echo "$porn_results" | while IFS=$'\t' read -r line; do
            echo -e "- ${line}" | sed 's/\t/ | /g' >> "$report_file"
        done
        
        ((violations_found_table+=1))
    fi
    
    if [ -n "$gamble_results" ]; then
        echo -e "\n${YELLOW}${BOLD}=== 疑似赌博内容 (${description}) ===${NC}" >> "$report_file"
        echo -e "表: $table, 字段: $column\n" >> "$report_file"
        
        # 格式化结果，每行一个记录
        echo "$gamble_results" | while IFS=$'\t' read -r line; do
            echo -e "- ${line}" | sed 's/\t/ | /g' >> "$report_file"
        done
        
        ((violations_found_table+=1))
    fi
    
    if [ -n "$ad_results" ]; then
        echo -e "\n${BLUE}${BOLD}=== 疑似广告内容 (${description}) ===${NC}" >> "$report_file"
        echo -e "表: $table, 字段: $column\n" >> "$report_file"
        
        # 格式化结果，每行一个记录
        echo "$ad_results" | while IFS=$'\t' read -r line; do
            echo -e "- ${line}" | sed 's/\t/ | /g' >> "$report_file"
        done
        
        ((violations_found_table+=1))
    fi
    
    if [ -n "$domain_results" ]; then
        echo -e "\n${PURPLE}${BOLD}=== 可疑域名 (${description}) ===${NC}" >> "$report_file"
        echo -e "表: $table, 字段: $column\n" >> "$report_file"
        
        # 格式化结果，每行一个记录
        echo "$domain_results" | while IFS=$'\t' read -r line; do
            echo -e "- ${line}" | sed 's/\t/ | /g' >> "$report_file"
        done
        
        ((violations_found_table+=1))
    fi
    
    # 返回发现的违规数量
    echo $violations_found_table
    return 0
}

# 扫描单个WordPress站点
scan_site() {
    local site_path="$1"
    local site_output_dir="${OUTPUT_DIR}/$(basename "$site_path")"
    local wp_config="${site_path}/wp-config.php"
    local report_file="${site_output_dir}/scan_report.txt"
    local violations_found=0
    local site_url=""
    local domain_name=""
    
    mkdir -p "$site_output_dir"
    
    print_separator
    echo -e "${CYAN}${BOLD}[扫描站点]${NC} ${UNDERLINE}$site_path${NC}"
    print_separator
    
    echo -e "${BOLD}===== WordPress数据库内容扫描报告 =====${NC}" > "$report_file"
    echo "扫描时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$report_file"
    echo "站点路径: $site_path" >> "$report_file"
    echo "" >> "$report_file"
    
    # 解析WordPress配置文件
    if ! parse_wp_config "$wp_config"; then
        echo "错误: 无法解析WordPress配置文件: $wp_config" >> "$report_file"
        log_error "无法解析WordPress配置文件: $wp_config"
        return 1
    fi
    
    echo "数据库名称: $DB_NAME" >> "$report_file"
    echo "数据库主机: $DB_HOST" >> "$report_file"
    echo "表前缀: $DB_PREFIX" >> "$report_file"

    # 显示数据库连接信息
    log_info "数据库信息: 名称=${CYAN}${DB_NAME}${NC}, 主机=${CYAN}${DB_HOST}${NC}, 前缀=${CYAN}${DB_PREFIX}${NC}"
    
    # 获取站点URL - 通过多种方式获取
    log_info "正在获取站点URL..."
    
    # 获取站点URL和域名
    local site_info=$(get_site_url_clean "$site_path" "$DB_PREFIX")
    site_url=$(echo "$site_info" | cut -d'|' -f1)
    domain_name=$(echo "$site_info" | cut -d'|' -f2)
    
    if [ -n "$site_url" ] && [ "$site_url" != "未知URL" ]; then
        log_success "获取到站点URL: ${GREEN}$site_url${NC}"
        echo "站点URL: $site_url" >> "$report_file"
        echo "站点域名: $domain_name" >> "$report_file"
    else
        log_warning "无法获取站点URL，使用目录名作为标识 (原因: URL不在数据库或配置文件中)"
        site_url="未知URL"
        domain_name=$(basename "$site_path")
        echo "站点URL: 未知" >> "$report_file"
        echo "站点域名: $domain_name (基于目录名)" >> "$report_file"
    fi
    
    echo "" >> "$report_file"
    
    # 保存站点URL到全局变量 - 在扫描开始时就保存
    SITE_URLS["$site_path"]="$site_url"
    SITE_NAMES["$site_path"]="$domain_name"
    
    # 要扫描的表和列
    declare -A tables
    tables["${DB_PREFIX}posts:post_content"]="文章内容"
    tables["${DB_PREFIX}posts:post_title"]="文章标题"
    tables["${DB_PREFIX}postmeta:meta_value"]="文章元数据"
    tables["${DB_PREFIX}options:option_value"]="站点选项"
    tables["${DB_PREFIX}comments:comment_content"]="评论内容"
    
    # 计算总表数
    local total_tables=${#tables[@]}
    local current_table=0
    
    log_info "开始扫描数据库表... (数据库: ${CYAN}${DB_NAME}${NC})"
    echo ""  # 添加空行，为进度条留出空间
    
    # 扫描各个表
    for table_col in "${!tables[@]}"; do
        IFS=':' read -r table column <<< "$table_col"
        description=${tables["$table_col"]}
        
        ((current_table++))
        
        # 显示当前正在扫描的表信息
        log_info "正在扫描表: ${CYAN}${table}${NC} (字段: ${YELLOW}${column}${NC})"
        
        # 在同一行更新进度条
        echo -ne "\r"  # 回到行首
        show_progress $current_table $total_tables
        
        local found=$(scan_table "$table" "$column" "$description" "$report_file" "$site_url")
        
        # 显示表扫描结果
        if [ "$found" -gt 0 ]; then
            log_warning "表 ${CYAN}${table}${NC} 中发现 ${RED}${found}${NC} 处可能的违规内容"
        else
            log_success "表 ${CYAN}${table}${NC} 未发现违规内容 ${GREEN}✓${NC}"
        fi
        
        violations_found=$((violations_found + found))
    done
    
    echo ""  # 换行，确保进度条之后有换行
    
    # 扫描总结
    if [ $violations_found -gt 0 ]; then
        echo "" >> "$report_file"
        echo -e "${BOLD}===== 扫描总结 =====${NC}" >> "$report_file"
        echo "发现 $violations_found 处可能的违规内容，请查看上述详细信息。" >> "$report_file"
        echo "数据库: $DB_NAME, 前缀: $DB_PREFIX" >> "$report_file"
        if [ -n "$site_url" ] && [ "$site_url" != "未知URL" ]; then
            log_warning "站点 ${CYAN}$domain_name${NC} (${UNDERLINE}$site_url${NC}) 发现 ${RED}$violations_found${NC} 处可能的违规内容"
        else
            log_warning "站点 ${CYAN}$domain_name${NC} (数据库: ${CYAN}${DB_NAME}${NC}) 发现 ${RED}$violations_found${NC} 处可能的违规内容"
        fi
        print_separator
        log_info "异常表:"
        for table_col in "${!tables[@]}"; do
            IFS=':' read -r table column <<< "$table_col"
            description=${tables["$table_col"]}
            # 检查文件中是否有与此表相关的违规内容
            if grep -q "$description" "$report_file"; then
                log_warning "  - ${RED}✗${NC} ${CYAN}${table}${NC}"
            fi
        done
    else
        echo "" >> "$report_file"
        echo -e "${BOLD}===== 扫描总结 =====${NC}" >> "$report_file"
        echo "未发现可疑违规内容。" >> "$report_file"
        echo "数据库: $DB_NAME, 前缀: $DB_PREFIX" >> "$report_file"
        if [ -n "$site_url" ] && [ "$site_url" != "未知URL" ]; then
            log_success "站点 ${CYAN}$domain_name${NC} (${UNDERLINE}$site_url${NC}) 未发现可疑违规内容"
        else
            log_success "站点 ${CYAN}$domain_name${NC} (数据库: ${CYAN}${DB_NAME}${NC}) 未发现可疑违规内容"
        fi
        print_separator
        log_info "扫描的表 ${GREEN}(全部正常)${NC}:"
        for table_col in "${!tables[@]}"; do
            IFS=':' read -r table column <<< "$table_col"
            log_success "  - ${GREEN}✓${NC} ${CYAN}${table}${NC}"
        done
    fi
    
    return 0
}

# 添加详细的站点报告到HTML
add_site_details_to_html() {
    local site="$1"
    local summary_file="$2"
    local site_class="$3"
    
    local site_name=$(basename "$site")
    local site_report="${OUTPUT_DIR}/${site_name}/scan_report.txt"
    local site_url="${SITE_URLS[$site]}"
    local domain="${SITE_NAMES[$site]}"
    
    # 从报告文件中获取数据库信息，而不是使用全局变量
    local db_name=$(grep "数据库名称:" "$site_report" | cut -d: -f2 | tr -d ' ')
    local db_prefix=$(grep "表前缀:" "$site_report" | cut -d: -f2 | tr -d ' ')
    
    if [ -f "$site_report" ]; then
        # 添加站点详情
        cat >> "$summary_file" << EOF
        <div class="site ${site_class}">
            <h3>站点: ${site_name}</h3>
            <div class="site-url">域名: ${domain:-未知}</div>
            <div class="site-url">URL: ${site_url:+<a href="${site_url}" target="_blank">${site_url}</a>}</div>
            <div class="site-db">数据库: ${db_name}, 表前缀: ${db_prefix}</div>
EOF
        
        # 如果有违规内容，添加详细信息
        local porn_sections=$(grep -n -A100 "=== 疑似色情内容" "$site_report" | grep -m1 -B100 "^$" || grep -n -A100 "=== 疑似色情内容" "$site_report")
        local gamble_sections=$(grep -n -A100 "=== 疑似赌博内容" "$site_report" | grep -m1 -B100 "^$" || grep -n -A100 "=== 疑似赌博内容" "$site_report")
        local ad_sections=$(grep -n -A100 "=== 疑似广告内容" "$site_report" | grep -m1 -B100 "^$" || grep -n -A100 "=== 疑似广告内容" "$site_report")
        local domain_sections=$(grep -n -A100 "=== 可疑域名" "$site_report" | grep -m1 -B100 "^$" || grep -n -A100 "=== 可疑域名" "$site_report")
        
        if [ -n "$porn_sections" ] || [ -n "$gamble_sections" ] || [ -n "$ad_sections" ] || [ -n "$domain_sections" ]; then
            cat >> "$summary_file" << EOF
            <h4>违规内容详情:</h4>
            <div class="violations-container">
EOF
            
            # 添加色情内容
            if [ -n "$porn_sections" ]; then
                cat >> "$summary_file" << EOF
                <div class="violation-category porn">
                    <h5>疑似色情内容</h5>
                    <div class="violation-items">
EOF
                echo "$porn_sections" | grep -v "===" | grep -v "^--$" | while read -r line; do
                    # 过滤掉行号和其他非内容部分
                    content=$(echo "$line" | sed 's/^[0-9]*[-:]//' | sed 's/\t/ | /g')
                    if [ -n "$content" ]; then
                        echo "<div class='violation-item'>${content}</div>" >> "$summary_file"
                    fi
                done
                
                cat >> "$summary_file" << EOF
                    </div>
                </div>
EOF
            fi
            
            # 添加赌博内容
            if [ -n "$gamble_sections" ]; then
                cat >> "$summary_file" << EOF
                <div class="violation-category gamble">
                    <h5>疑似赌博内容</h5>
                    <div class="violation-items">
EOF
                echo "$gamble_sections" | grep -v "===" | grep -v "^--$" | while read -r line; do
                    content=$(echo "$line" | sed 's/^[0-9]*[-:]//' | sed 's/\t/ | /g')
                    if [ -n "$content" ]; then
                        echo "<div class='violation-item'>${content}</div>" >> "$summary_file"
                    fi
                done
                
                cat >> "$summary_file" << EOF
                    </div>
                </div>
EOF
            fi
            
            # 添加广告内容
            if [ -n "$ad_sections" ]; then
                cat >> "$summary_file" << EOF
                <div class="violation-category ad">
                    <h5>疑似广告内容</h5>
                    <div class="violation-items">
EOF
                echo "$ad_sections" | grep -v "===" | grep -v "^--$" | while read -r line; do
                    content=$(echo "$line" | sed 's/^[0-9]*[-:]//' | sed 's/\t/ | /g')
                    if [ -n "$content" ]; then
                        echo "<div class='violation-item'>${content}</div>" >> "$summary_file"
                    fi
                done
                
                cat >> "$summary_file" << EOF
                    </div>
                </div>
EOF
            fi
            
            # 添加可疑域名
            if [ -n "$domain_sections" ]; then
                cat >> "$summary_file" << EOF
                <div class="violation-category domain">
                    <h5>可疑域名</h5>
                    <div class="violation-items">
EOF
                echo "$domain_sections" | grep -v "===" | grep -v "^--$" | while read -r line; do
                    content=$(echo "$line" | sed 's/^[0-9]*[-:]//' | sed 's/\t/ | /g')
                    if [ -n "$content" ]; then
                        echo "<div class='violation-item'>${content}</div>" >> "$summary_file"
                    fi
                done
                
                cat >> "$summary_file" << EOF
                    </div>
                </div>
EOF
            fi
            
            cat >> "$summary_file" << EOF
            </div>
EOF
        else
            cat >> "$summary_file" << EOF
            <p class="clean-notice">该站点未发现违规内容 ✓</p>
EOF
        fi
        
        # 关闭站点div
        cat >> "$summary_file" << EOF
        </div>
EOF
    fi
}

# 创建HTML格式报告
create_html_report() {
    local summary_file="${OUTPUT_DIR}/scan_report.html"
    
    # 创建HTML报告头部
    cat > "$summary_file" << EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WordPress数据库内容扫描报告</title>
    <style>
        body {
            font-family: 'Arial', 'PingFang SC', 'Microsoft YaHei', sans-serif;
            line-height: 1.6;
            margin: 0;
            padding: 20px;
            color: #333;
            background-color: #f5f5f5;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            padding: 20px;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
            border-radius: 5px;
        }
        h1, h2, h3, h4, h5 {
            color: #2c3e50;
            margin-top: 1em;
            margin-bottom: 0.5em;
        }
        h1 {
            text-align: center;
            padding-bottom: 10px;
            border-bottom: 2px solid #eee;
        }
        .summary {
            background-color: #f8f9fa;
            padding: 15px;
            border-radius: 5px;
            margin: 20px 0;
        }
        .site {
            margin-bottom: 30px;
            padding: 15px;
            border-left: 4px solid #3498db;
            background-color: #ecf0f1;
        }
        .clean {
            border-left-color: #2ecc71;
        }
        .warning {
            border-left-color: #e74c3c;
        }
        .violation-category {
            background-color: #fdedec;
            padding: 10px 15px;
            margin: 10px 0;
            border-radius: 4px;
        }
        .violation-item {
            padding: 5px 10px;
            margin: 5px 0;
            background-color: rgba(255,255,255,0.7);
            border-radius: 3px;
            word-break: break-all;
            line-height: 1.4;
        }
        .porn { 
            border-left: 4px solid #e74c3c; 
            background-color: rgba(231, 76, 60, 0.1);
        }
        .gamble { 
            border-left: 4px solid #f39c12; 
            background-color: rgba(243, 156, 18, 0.1);
        }
        .ad { 
            border-left: 4px solid #3498db; 
            background-color: rgba(52, 152, 219, 0.1);
        }
        .domain { 
            border-left: 4px solid #9b59b6; 
            background-color: rgba(155, 89, 182, 0.1);
        }
        .timestamp {
            color: #7f8c8d;
            font-size: 0.9em;
        }
        footer {
            text-align: center;
            margin-top: 30px;
            color: #7f8c8d;
            font-size: 0.9em;
        }
        .site-url, .site-db {
            margin: 5px 0;
            color: #2980b9;
        }
        .site-url a {
            color: #2980b9;
            text-decoration: none;
            font-weight: bold;
        }
        .site-url a:hover {
            text-decoration: underline;
        }
        .table-container {
            overflow-x: auto;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        th, td {
            border: 1px solid #ddd;
            padding: 8px;
            text-align: left;
        }
        th {
            background-color: #f2f2f2;
            color: #333;
        }
        tr:nth-child(even) {
            background-color: #f9f9f9;
        }
        tr:hover {
            background-color: #f5f5f5;
        }
        .clean-notice {
            color: #2ecc71;
            font-weight: bold;
            padding: 10px;
            background-color: rgba(46, 204, 113, 0.1);
            border-radius: 4px;
        }
        .violations-container {
            max-height: 500px;
            overflow-y: auto;
            border: 1px solid #ddd;
            border-radius: 4px;
            padding: 10px;
        }
        @media print {
            .violations-container {
                max-height: none;
                overflow-y: visible;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>WordPress数据库内容扫描报告</h1>
        <div class="timestamp">扫描时间: $(date '+%Y-%m-%d %H:%M:%S')</div>
        
        <div class="summary">
            <h2>扫描总结</h2>
            <p>共扫描 ${#SITES[@]} 个WordPress站点</p>
EOF
    
    # 计算总违规数
    local total_violations=0
    local clean_sites=0
    
    for site in "${SITES[@]}"; do
        site_name=$(basename "$site")
        site_report="${OUTPUT_DIR}/${site_name}/scan_report.txt"
        
        if [ -f "$site_report" ]; then
            violations=$(grep -c "发现可能的" "$site_report")
            total_violations=$((total_violations + violations))
            
            if [ $violations -eq 0 ]; then
                clean_sites=$((clean_sites + 1))
            fi
        fi
    done
    
    # 继续HTML报告
    cat >> "$summary_file" << EOF
            <p>发现 ${total_violations} 处可能的违规内容</p>
            <p>干净站点: ${clean_sites} 个</p>
            <p>有问题站点: $((${#SITES[@]} - clean_sites)) 个</p>
        </div>
        
        <h2>站点详情</h2>
        
        <div class="table-container">
            <table>
                <tr>
                    <th>站点</th>
                    <th>域名</th>
                    <th>URL</th>
                    <th>数据库</th>
                    <th>违规数</th>
                    <th>状态</th>
                </tr>
EOF
    
    # 添加站点表格
    for site in "${SITES[@]}"; do
        site_name=$(basename "$site")
        site_report="${OUTPUT_DIR}/${site_name}/scan_report.txt"
        site_url="${SITE_URLS[$site]}"
        domain="${SITE_NAMES[$site]}"
        
        if [ -f "$site_report" ]; then
            violations=$(grep -c "发现可能的" "$site_report")
            
            if [ $violations -gt 0 ]; then
                status="<span style='color: #e74c3c;'>有违规内容</span>"
                site_class="warning"
            else
                status="<span style='color: #2ecc71;'>正常</span>"
                site_class="clean"
            fi
            
            db_name=$(grep "数据库名称:" "$site_report" | cut -d: -f2 | tr -d ' ')
            db_prefix=$(grep "表前缀:" "$site_report" | cut -d: -f2 | tr -d ' ')
            
            # 添加表格行
            cat >> "$summary_file" << EOF
                <tr>
                    <td>${site_name}</td>
                    <td>${domain:-未知}</td>
                    <td>${site_url:+<a href="${site_url}" target="_blank">${site_url}</a>}</td>
                    <td>${db_name:-未知}${db_prefix:+ (${db_prefix})}</td>
                    <td>${violations}</td>
                    <td>${status}</td>
                </tr>
EOF
        fi
    done
    
    # 关闭表格
    cat >> "$summary_file" << EOF
            </table>
        </div>
        
        <h2>详细报告</h2>
EOF
    
    # 添加每个站点的详细报告
    for site in "${SITES[@]}"; do
        site_name=$(basename "$site")
        site_report="${OUTPUT_DIR}/${site_name}/scan_report.txt"
        
        if [ -f "$site_report" ]; then
            violations=$(grep -c "发现可能的" "$site_report")
            
            if [ $violations -gt 0 ]; then
                site_class="warning"
            else
                site_class="clean"
            fi
            
            # 添加站点详情
            add_site_details_to_html "$site" "$summary_file" "$site_class"
        fi
    done
    
    # 添加页脚
    cat >> "$summary_file" << EOF
        <footer>
            <p>WordPress数据库内容扫描工具 v${VERSION} | 扫描完成时间: $(date '+%Y-%m-%d %H:%M:%S')</p>
        </footer>
    </div>
</body>
</html>
EOF
    
    log_success "HTML报告已生成: ${CYAN}${summary_file}${NC}"
    
    # 尝试自动打开HTML报告
    if command -v xdg-open &>/dev/null; then
        xdg-open "$summary_file" &>/dev/null &
    elif command -v open &>/dev/null; then
        open "$summary_file" &>/dev/null &
    fi
}

# 查找WordPress站点
find_wordpress_sites() {
    local found_sites=()
    
    # 首先检查宝塔面板的网站目录
    if [ -d "/www/wwwroot" ]; then
        log_info "检测到宝塔面板环境，正在搜索宝塔站点..."
        
        # 查找所有包含wp-config.php的目录（宝塔站点）
        while IFS= read -r config_file; do
            site_dir=$(dirname "$config_file")
            found_sites+=("$site_dir")
        done < <(find /www/wwwroot -type f -name "wp-config.php" 2>/dev/null)
        
        log_success "在宝塔面板中找到 ${#found_sites[@]} 个WordPress站点"
    fi
    
    # 如果没有找到宝塔站点，或者宝塔站点数量为0，则搜索其他常见位置
    if [ ${#found_sites[@]} -eq 0 ]; then
        log_info "正在搜索系统中的WordPress站点..."
        
        # 常见的Web目录
        local web_dirs=(
            "/var/www"
            "/srv/www"
            "/usr/share/nginx"
            "/usr/share/apache2"
            "/home/*/public_html"
            "$(pwd)"
        )
        
        for dir in "${web_dirs[@]}"; do
            if [ -d "$dir" ]; then
                while IFS= read -r config_file; do
                    site_dir=$(dirname "$config_file")
                    found_sites+=("$site_dir")
                done < <(find "$dir" -type f -name "wp-config.php" 2>/dev/null)
            fi
        done
        
        log_success "在系统中找到 ${#found_sites[@]} 个WordPress站点"
    fi
    
    if [ ${#found_sites[@]} -eq 0 ]; then
        log_error "未找到任何WordPress站点"
        log_info "如果您使用宝塔面板，请确保站点在 /www/wwwroot/ 目录下"
        exit 1
    fi
    
    log_success "共找到 ${#found_sites[@]} 个WordPress站点"
    echo ""
    
    # 询问是否扫描所有站点
    echo -e "${YELLOW}发现以下WordPress站点:${NC}"
    for ((i=0; i<${#found_sites[@]}; i++)); do
        echo -e "${CYAN}[$i]${NC} ${found_sites[$i]}"
    done
    echo ""
    echo -e "${YELLOW}按Enter键扫描所有站点，或输入站点编号(如 0,1,3)扫描指定站点...${NC}"
    read -t 10 site_selection
    
    echo ""
    
    # 如果用户有输入，则只扫描选择的站点
    if [ -n "$site_selection" ]; then
        IFS=',' read -ra selected_indices <<< "$site_selection"
        local selected_sites=()
        
        for index in "${selected_indices[@]}"; do
            if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -lt "${#found_sites[@]}" ]; then
                selected_sites+=("${found_sites[$index]}")
                log_info "已选择站点: ${CYAN}${found_sites[$index]}${NC}"
            else
                log_warning "忽略无效的站点索引: $index"
            fi
        done
        
        if [ ${#selected_sites[@]} -gt 0 ]; then
            SITES=("${selected_sites[@]}")
            log_info "将扫描选定的 ${#SITES[@]} 个站点"
        else
            SITES=("${found_sites[@]}")
            log_info "没有有效的站点选择，将扫描所有 ${#SITES[@]} 个站点"
        fi
    else
        SITES=("${found_sites[@]}")
        log_info "将扫描所有 ${#SITES[@]} 个站点"
    fi
}

# 显示使用帮助
show_help() {
    echo -e "${BOLD}WordPress 数据库内容扫描工具 v${VERSION}${NC}"
    echo ""
    echo "使用方法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help          显示帮助信息"
    echo "  -v, --verbose       显示详细输出信息"
    echo "  -o, --output DIR    指定输出目录 (默认: 当前目录/wp_scan_results_<日期时间>)"
    echo ""
    echo "例子:"
    echo "  $0                  使用默认设置扫描所有WordPress站点"
    echo "  $0 -o /tmp/results  将结果输出到 /tmp/results 目录"
    echo ""
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                LOG_LEVEL=2
                shift
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}未知选项: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
}

# 主函数
main() {
    # 解析命令行参数
    parse_args "$@"
    
    # 创建输出目录
    mkdir -p "$OUTPUT_DIR"
    
    # 显示横幅
    show_banner
    
    # 查找WordPress站点
    find_wordpress_sites
    
    # 开始扫描
    print_separator
    log_info "开始扫描${#SITES[@]}个WordPress站点..."
    print_separator
    
    # 扫描每个站点
    for site in "${SITES[@]}"; do
        scan_site "$site"
    done
    
    # 生成HTML报告
    create_html_report
    
    # 显示完成信息
    print_separator
    log_success "扫描完成，结果保存在: ${CYAN}${OUTPUT_DIR}${NC}"
    log_info "HTML报告: ${CYAN}${OUTPUT_DIR}/scan_report.html${NC}"
    print_separator
}

# 执行主函数
main "$@"
