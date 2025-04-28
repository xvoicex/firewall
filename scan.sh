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
VERSION="1.0.0"

# 默认值
OUTPUT_DIR="$(pwd)/wp_scan_results_$(date +%Y%m%d_%H%M%S)"
VERBOSE=1

# 用于存储站点URL和名称的关联数组
declare -A SITE_URLS
declare -A SITE_NAMES

# 违规关键词列表
PORN_KEYWORDS=(
    "色情" "淫" "性爱" "做爱" "口交" "肛交" "乳交" "群交" "嫖娼" "妓女" "卖淫"
    "porn" "sex" "adult" "xxx" "pussy" "dick" "cock" "tits" "boobs" "masturbation"
    "webcam girl" "escort" "stripper" "call girl" "prostitute"
)

GAMBLE_KEYWORDS=(
    "赌博" "博彩" "彩票" "赌场" "投注" "下注" "娱乐城" "网上赌场" "百家乐"
    "gambling" "casino" "bet" "lottery" "poker" "slots" "roulette" "blackjack"
    "bookmaker" "sportsbook" "wager"
)

AD_KEYWORDS=(
    "代理" "推广" "推销" "广告" "优惠" "促销" "返利" "佣金" "点击" "联盟"
    "advertise" "promotion" "discount" "offer" "click here" "cheap" "best price"
    "buy now" "earn money" "make money" "affiliate" "sale"
)

SUSPICIOUS_DOMAINS=(
    ".top" ".win" ".loan" ".online" ".vip" ".xyz" ".club" ".shop" ".site"
    ".bet" ".casino" ".porn" ".sex" ".xxx" ".click" ".link" ".tk" ".cc"
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
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 记录错误日志
log_error() {
    echo -e "${RED}[✗] $1${NC}" >&2
}

# 记录成功日志
log_success() {
    echo -e "${GREEN}[✓] $1${NC}"
}

# 记录警告日志
log_warning() {
    echo -e "${YELLOW}[!] $1${NC}"
}

# 记录信息日志
log_info() {
    echo -e "${BLUE}[i] $1${NC}"
}

# 分隔线
print_separator() {
    echo -e "${BLUE}------------------------------------------------------------${NC}"
}

# 进度条
show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "${WHITE}[${GREEN}"
    for ((i=0; i<filled; i++)); do
        printf "█"
    done
    
    for ((i=0; i<empty; i++)); do
        printf "${WHITE}░"
    done
    
    printf "${WHITE}] ${percent}%%${NC}\r"
}

# 自动查找WordPress安装目录
find_wordpress_sites() {
    log_info "正在搜索系统中的WordPress站点..."
    
    # 尝试从常见目录开始查找
    local search_dirs=("/var/www" "/var/www/html" "/var/www/vhosts" "/home" "/srv/www" ".")
    
    # 添加宝塔面板专用目录
    if [ -d "/www/wwwroot" ]; then
        search_dirs=("/www/wwwroot" "${search_dirs[@]}")
        log_info "检测到宝塔面板环境，将优先搜索 ${CYAN}/www/wwwroot${NC} 目录..."
    fi
    
    # 用于存储找到的WordPress路径
    local found_sites=()
    
    # 首先搜索宝塔环境下的WordPress站点
    if [ -d "/www/wwwroot" ]; then
        log_info "开始在宝塔面板网站目录中搜索..."
        
        # 直接列出宝塔网站目录
        local bt_sites=()
        while IFS= read -r site_dir; do
            if [ -d "$site_dir" ]; then
                bt_sites+=("$site_dir")
            fi
        done < <(find "/www/wwwroot" -maxdepth 1 -type d 2>/dev/null | grep -v "^/www/wwwroot$")
        
        # 搜索每个站点目录
        for bt_site in "${bt_sites[@]}"; do
            site_name=$(basename "$bt_site")
            log_info "检查宝塔站点: ${CYAN}$site_name${NC}"
            
            # 检查常见的WordPress配置文件位置
            local wp_locations=(
                "$bt_site/wp-config.php"                # 标准路径
                "$bt_site/public_html/wp-config.php"    # 子目录public_html
                "$bt_site/public/wp-config.php"         # 子目录public
                "$bt_site/htdocs/wp-config.php"         # 子目录htdocs
                "$bt_site/web/wp-config.php"            # 子目录web
            )
            
            for wp_config in "${wp_locations[@]}"; do
                if [ -f "$wp_config" ]; then
                    site_dir=$(dirname "$wp_config")
                    found_sites+=("$site_dir")
                    log_success "找到宝塔WordPress站点: ${GREEN}$site_dir${NC}"
                    break
                fi
            done
        done
    fi
    
    # 然后搜索其他常规目录
    for dir in "${search_dirs[@]}"; do
        if [ -d "$dir" ] && [ "$dir" != "/www/wwwroot" ]; then
            log_info "正在搜索 $dir 目录..."
            # 查找wp-config.php文件
            while IFS= read -r config_file; do
                site_dir=$(dirname "$config_file")
                # 避免重复添加已找到的站点
                local is_duplicate=0
                for existing_site in "${found_sites[@]}"; do
                    if [ "$existing_site" = "$site_dir" ]; then
                        is_duplicate=1
                        break
                    fi
                done
                
                if [ $is_duplicate -eq 0 ]; then
                    found_sites+=("$site_dir")
                    log_success "找到WordPress站点: $site_dir"
                fi
            done < <(find "$dir" -type f -name "wp-config.php" 2>/dev/null)
        fi
    done
    
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

# 解析WordPress配置文件获取数据库信息
parse_wp_config() {
    local wp_config="$1"
    
    if [ ! -f "$wp_config" ]; then
        log_error "无法找到WordPress配置文件: $wp_config"
        return 1
    fi
    
    log_info "正在解析配置文件: ${CYAN}$wp_config${NC}"
    
    # 宝塔面板可能使用的配置方式
    local bt_include_file=""
    if grep -q "include_once" "$wp_config"; then
        bt_include_file=$(grep -o "include_once.*\.php[\'|\"]" "$wp_config" | grep -o "/[^'\"]*\.php")
        
        if [ -n "$bt_include_file" ] && [ -f "$bt_include_file" ]; then
            log_info "检测到宝塔面板配置引用: ${CYAN}$bt_include_file${NC}"
            
            # 从引用文件中获取数据库信息
            DB_NAME=$(grep -o "define.*DB_NAME.*'.*'" "$bt_include_file" 2>/dev/null | cut -d\' -f4)
            DB_USER=$(grep -o "define.*DB_USER.*'.*'" "$bt_include_file" 2>/dev/null | cut -d\' -f4)
            DB_PASS=$(grep -o "define.*DB_PASSWORD.*'.*'" "$bt_include_file" 2>/dev/null | cut -d\' -f4)
            DB_HOST=$(grep -o "define.*DB_HOST.*'.*'" "$bt_include_file" 2>/dev/null | cut -d\' -f4)
        fi
    fi
    
    # 如果没有从引用文件中获取到，从原配置文件中获取
    if [ -z "$DB_NAME" ]; then
        # 提取数据库连接信息
        DB_NAME=$(grep -o "define.*DB_NAME.*'.*'" "$wp_config" | cut -d\' -f4)
        DB_USER=$(grep -o "define.*DB_USER.*'.*'" "$wp_config" | cut -d\' -f4)
        DB_PASS=$(grep -o "define.*DB_PASSWORD.*'.*'" "$wp_config" | cut -d\' -f4)
        DB_HOST=$(grep -o "define.*DB_HOST.*'.*'" "$wp_config" | cut -d\' -f4)
    fi
    
    # 处理使用双引号的情况
    if [ -z "$DB_NAME" ]; then
        DB_NAME=$(grep -o 'define.*DB_NAME.*".*"' "$wp_config" | cut -d\" -f4)
        DB_USER=$(grep -o 'define.*DB_USER.*".*"' "$wp_config" | cut -d\" -f4)
        DB_PASS=$(grep -o 'define.*DB_PASSWORD.*".*"' "$wp_config" | cut -d\" -f4)
        DB_HOST=$(grep -o 'define.*DB_HOST.*".*"' "$wp_config" | cut -d\" -f4)
    fi
    
    # 提取表前缀
    DB_PREFIX=$(grep -o "\$table_prefix.*=.*['\"].*['\"]" "$wp_config" | cut -d[\'\"] -f2)
    
    # 默认表前缀
    if [ -z "$DB_PREFIX" ]; then
        DB_PREFIX="wp_"
    fi
    
    # 验证数据库连接信息
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_HOST" ]; then
        log_error "无法从配置文件解析数据库信息: $wp_config"
        
        # 特殊处理宝塔面板可能的配置方式
        if [ -f "$wp_config" ]; then
            if grep -q "BT_" "$wp_config"; then
                log_warning "检测到宝塔专用配置格式，尝试特殊解析..."
                
                # 搜索宝塔数据库配置文件
                local wp_dir=$(dirname "$wp_config")
                local bt_config_files=(
                    "$wp_dir/data/config.php"
                    "/www/server/panel/data/database.db"
                    "/www/server/panel/data/default.db"
                )
                
                for bt_config in "${bt_config_files[@]}"; do
                    if [ -f "$bt_config" ]; then
                        log_info "检测到宝塔配置文件: ${CYAN}$bt_config${NC}"
                        
                        # SQLite文件无法直接读取，跳过
                        if [[ "$bt_config" == *.db ]]; then
                            continue
                        fi
                        
                        # 尝试从宝塔配置中提取信息
                        local site_name=$(basename "$(dirname "$wp_dir")")
                        
                        DB_NAME=$(grep -o "name.*=.*['\"].*['\"]" "$bt_config" 2>/dev/null | head -1 | cut -d[\'\"] -f2)
                        DB_USER=$(grep -o "user.*=.*['\"].*['\"]" "$bt_config" 2>/dev/null | head -1 | cut -d[\'\"] -f2)
                        DB_PASS=$(grep -o "pass.*=.*['\"].*['\"]" "$bt_config" 2>/dev/null | head -1 | cut -d[\'\"] -f2)
                        DB_HOST=$(grep -o "host.*=.*['\"].*['\"]" "$bt_config" 2>/dev/null | head -1 | cut -d[\'\"] -f2)
                        
                        if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
                            log_success "成功从宝塔配置获取数据库信息"
                            break
                        fi
                    fi
                done
            fi
        fi
        
        # 再次验证是否成功获取数据库信息
        if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_HOST" ]; then
            return 1
        fi
    fi
    
    if [ $VERBOSE -eq 1 ]; then
        log_info "数据库名称: ${CYAN}$DB_NAME${NC}"
        log_info "数据库主机: ${CYAN}$DB_HOST${NC}"
        log_info "表前缀: ${CYAN}$DB_PREFIX${NC}"
    fi
    
    return 0
}

# 执行MySQL查询
run_mysql_query() {
    local query="$1"
    local result
    
    if [ -z "$DB_PASS" ]; then
        result=$(mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "$query" 2>/dev/null)
    else
        result=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "$query" 2>/dev/null)
    fi
    
    echo "$result"
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

# 扫描单个WordPress站点
scan_site() {
    local site_path="$1"
    local site_output_dir="${OUTPUT_DIR}/$(basename "$site_path")"
    local wp_config="${site_path}/wp-config.php"
    local report_file="${site_output_dir}/scan_report.txt"
    local violations_found=0
    local site_url=""
    local site_name=""
    
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
    
    # 获取站点URL
    log_info "正在获取站点URL..."
    
    # 尝试从数据库获取站点URL
    local url_query="SELECT option_value FROM ${DB_PREFIX}options WHERE option_name IN ('siteurl', 'home') LIMIT 1;"
    site_url=$(run_mysql_query "$url_query" | grep -v "option_value" | head -1)
    
    if [ -n "$site_url" ]; then
        log_success "获取到站点URL: ${GREEN}$site_url${NC}"
        echo "站点URL: $site_url" >> "$report_file"
        
        # 从URL中提取站点名称
        site_name=$(echo "$site_url" | sed -E 's/https?:\/\///' | sed -E 's/\/.*//')
        echo "站点域名: $site_name" >> "$report_file"
    else
        log_warning "无法从数据库获取站点URL"
        echo "站点URL: 未知" >> "$report_file"
    fi
    
    echo "" >> "$report_file"
    
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
    
    # 扫描各个表
    for table_col in "${!tables[@]}"; do
        IFS=':' read -r table column <<< "$table_col"
        description=${tables["$table_col"]}
        
        ((current_table++))
        show_progress $current_table $total_tables
        
        scan_table "$table" "$column" "$description" "$report_file" "$site_url"
    done
    
    echo ""  # 换行，确保进度条之后有换行
    
    # 扫描总结
    if [ $violations_found -gt 0 ]; then
        echo "" >> "$report_file"
        echo -e "${BOLD}===== 扫描总结 =====${NC}" >> "$report_file"
        echo "发现 $violations_found 处可能的违规内容，请查看上述详细信息。" >> "$report_file"
        if [ -n "$site_url" ]; then
            log_warning "站点 ${CYAN}$site_name${NC} (${UNDERLINE}$site_url${NC}) 发现 ${RED}$violations_found${NC} 处可能的违规内容"
        else
            log_warning "发现 ${RED}$violations_found${NC} 处可能的违规内容"
        fi
    else
        echo "" >> "$report_file"
        echo -e "${BOLD}===== 扫描总结 =====${NC}" >> "$report_file"
        echo "未发现可疑违规内容。" >> "$report_file"
        if [ -n "$site_url" ]; then
            log_success "站点 ${CYAN}$site_name${NC} (${UNDERLINE}$site_url${NC}) 未发现可疑违规内容"
        else
            log_success "未发现可疑违规内容"
        fi
    fi
    
    # 保存站点URL到全局变量
    SITE_URLS["$site_path"]="$site_url"
    SITE_NAMES["$site_path"]="$site_name"
    
    return 0
}

# 扫描单个数据库表
scan_table() {
    local table="$1"
    local column="$2"
    local description="$3"
    local report_file="$4"
    local site_url="$5"
    local found=0
    
    # 扫描色情内容
    local porn_query=$(build_search_query "$table" "$column" "${PORN_KEYWORDS[@]}")
    local porn_results=$(run_mysql_query "$porn_query")
    
    if [ -n "$porn_results" ]; then
        found=1
        violations_found=$((violations_found + 1))
        echo "" >> "$report_file"
        echo -e "${BOLD}==== 在${description}中发现可能的色情内容 ====${NC}" >> "$report_file"
        echo "表: $table, 列: $column" >> "$report_file"
        echo "$porn_results" >> "$report_file"
        
        log_warning "在${CYAN}${description}${NC}中发现可能的${RED}色情内容${NC}"
    fi
    
    # 扫描赌博内容
    local gamble_query=$(build_search_query "$table" "$column" "${GAMBLE_KEYWORDS[@]}")
    local gamble_results=$(run_mysql_query "$gamble_query")
    
    if [ -n "$gamble_results" ]; then
        found=1
        violations_found=$((violations_found + 1))
        echo "" >> "$report_file"
        echo -e "${BOLD}==== 在${description}中发现可能的赌博内容 ====${NC}" >> "$report_file"
        echo "表: $table, 列: $column" >> "$report_file"
        echo "$gamble_results" >> "$report_file"
        
        log_warning "在${CYAN}${description}${NC}中发现可能的${RED}赌博内容${NC}"
    fi
    
    # 扫描广告内容
    local ad_query=$(build_search_query "$table" "$column" "${AD_KEYWORDS[@]}")
    local ad_results=$(run_mysql_query "$ad_query")
    
    if [ -n "$ad_results" ]; then
        found=1
        violations_found=$((violations_found + 1))
        echo "" >> "$report_file"
        echo -e "${BOLD}==== 在${description}中发现可能的广告内容 ====${NC}" >> "$report_file"
        echo "表: $table, 列: $column" >> "$report_file"
        echo "$ad_results" >> "$report_file"
        
        log_warning "在${CYAN}${description}${NC}中发现可能的${RED}广告内容${NC}"
    fi
    
    # 扫描可疑域名
    local domain_query=$(build_search_query "$table" "$column" "${SUSPICIOUS_DOMAINS[@]}")
    local domain_results=$(run_mysql_query "$domain_query")
    
    if [ -n "$domain_results" ]; then
        found=1
        violations_found=$((violations_found + 1))
        echo "" >> "$report_file"
        echo -e "${BOLD}==== 在${description}中发现可疑域名 ====${NC}" >> "$report_file"
        echo "表: $table, 列: $column" >> "$report_file"
        echo "$domain_results" >> "$report_file"
        
        log_warning "在${CYAN}${description}${NC}中发现${RED}可疑域名${NC}"
    fi
}

# 生成HTML报告
generate_html_report() {
    local summary_file="${OUTPUT_DIR}/summary.html"
    
    # HTML头部
    cat > "$summary_file" << EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WordPress数据库内容扫描报告</title>
    <style>
        body {
            font-family: 'Arial', sans-serif;
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
        h1, h2, h3 {
            color: #2c3e50;
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
        .violation {
            background-color: #fdedec;
            padding: 10px;
            margin: 10px 0;
            border-radius: 4px;
        }
        .porn { border-left: 4px solid #e74c3c; }
        .gamble { border-left: 4px solid #f39c12; }
        .ad { border-left: 4px solid #3498db; }
        .domain { border-left: 4px solid #9b59b6; }
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
        .site-url {
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
            
            # 添加表格行
            cat >> "$summary_file" << EOF
                <tr>
                    <td>${site_name}</td>
                    <td>${domain:-未知}</td>
                    <td>${site_url:+<a href="${site_url}" target="_blank">${site_url}</a>}</td>
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
    
    # 添加每个站点的详情
    for site in "${SITES[@]}"; do
        site_name=$(basename "$site")
        site_report="${OUTPUT_DIR}/${site_name}/scan_report.txt"
        site_url="${SITE_URLS[$site]}"
        domain="${SITE_NAMES[$site]}"
        
        if [ -f "$site_report" ]; then
            violations=$(grep -c "发现可能的" "$site_report")
            
            if [ $violations -gt 0 ]; then
                site_class="warning"
            else
                site_class="clean"
            fi
            
            # 站点基本信息
            cat >> "$summary_file" << EOF
        <div class="site ${site_class}">
            <h3>${site_name}</h3>
            <p>路径: ${site}</p>
EOF
            
            # 添加站点URL信息
            if [ -n "$site_url" ]; then
                cat >> "$summary_file" << EOF
            <p class="site-url">域名: <strong>${domain}</strong></p>
            <p class="site-url">URL: <a href="${site_url}" target="_blank">${site_url}</a></p>
EOF
            fi
            
            # 数据库信息
            db_name=$(grep "数据库名称:" "$site_report" | cut -d':' -f2 | xargs)
            db_host=$(grep "数据库主机:" "$site_report" | cut -d':' -f2 | xargs)
            table_prefix=$(grep "表前缀:" "$site_report" | cut -d':' -f2 | xargs)
            
            cat >> "$summary_file" << EOF
            <p>数据库: ${db_name} (${db_host})</p>
            <p>表前缀: ${table_prefix}</p>
EOF
            
            # 违规内容
            if [ $violations -gt 0 ]; then
                cat >> "$summary_file" << EOF
            <h4>发现 ${violations} 处可能的违规内容:</h4>
EOF
                
                # 提取各类违规内容
                if grep -q "发现可能的色情内容" "$site_report"; then
                    echo '            <div class="violation porn"><strong>色情内容</strong></div>' >> "$summary_file"
                fi
                
                if grep -q "发现可能的赌博内容" "$site_report"; then
                    echo '            <div class="violation gamble"><strong>赌博内容</strong></div>' >> "$summary_file"
                fi
                
                if grep -q "发现可能的广告内容" "$site_report"; then
                    echo '            <div class="violation ad"><strong>广告内容</strong></div>' >> "$summary_file"
                fi
                
                if grep -q "发现可疑域名" "$site_report"; then
                    echo '            <div class="violation domain"><strong>可疑域名</strong></div>' >> "$summary_file"
                fi
                
                echo '            <p><a href="./'${site_name}'/scan_report.txt" target="_blank">查看详细报告</a></p>' >> "$summary_file"
            else
                echo '            <p><strong>未发现可疑违规内容</strong></p>' >> "$summary_file"
            fi
            
            echo '        </div>' >> "$summary_file"
        fi
    done
    
    # HTML尾部
    cat >> "$summary_file" << EOF
        <footer>
            <p>WordPress数据库内容扫描工具 v${VERSION}</p>
            <p>报告生成时间: $(date '+%Y-%m-%d %H:%M:%S')</p>
        </footer>
    </div>
</body>
</html>
EOF

    log_success "HTML报告已生成: $summary_file"
}

# 主程序
main() {
    # 显示欢迎横幅
    show_banner
    
    # 检测宝塔面板环境
    if [ -d "/www/wwwroot" ] || [ -d "/www/server/panel" ]; then
        log_info "检测到宝塔面板环境"
        echo -e "${YELLOW}宝塔面板环境已识别，将优先扫描宝塔建站目录${NC}"
        print_separator
    fi
    
    # 创建输出目录
    mkdir -p "$OUTPUT_DIR"
    log_info "扫描结果将保存在: ${CYAN}$OUTPUT_DIR${NC}"
    
    # 自动查找WordPress站点
    find_wordpress_sites
    
    # 显示开始扫描消息
    log_info "开始扫描 ${#SITES[@]} 个WordPress站点..."
    print_separator
    
    # 扫描所有站点
    local scan_success=0
    local scan_failed=0
    
    for site in "${SITES[@]}"; do
        if scan_site "$site"; then
            scan_success=$((scan_success + 1))
        else
            scan_failed=$((scan_failed + 1))
        fi
    done
    
    # 生成报告
    print_separator
    log_info "正在生成扫描报告..."
    
    # 生成文本摘要报告
    SUMMARY_FILE="${OUTPUT_DIR}/summary.txt"
    echo -e "${BOLD}===== WordPress数据库内容扫描总结 =====${NC}" > "$SUMMARY_FILE"
    echo "扫描时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$SUMMARY_FILE"
    echo "扫描站点数: ${#SITES[@]} (成功: $scan_success, 失败: $scan_failed)" >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
    
    echo "站点详情:" >> "$SUMMARY_FILE"
    echo "----------------------------------------" >> "$SUMMARY_FILE"
    echo "路径                 | 域名             | URL                  | 状态" >> "$SUMMARY_FILE"
    echo "----------------------------------------" >> "$SUMMARY_FILE"
    
    local total_violations=0
    
    for site in "${SITES[@]}"; do
        site_name=$(basename "$site")
        site_report="${OUTPUT_DIR}/${site_name}/scan_report.txt"
        site_url="${SITE_URLS[$site]}"
        domain="${SITE_NAMES[$site]:-未知}"
        
        if [ -f "$site_report" ]; then
            violations=$(grep -c "发现可能的" "$site_report")
            total_violations=$((total_violations + violations))
            
            # 格式化输出
            printf "%-20s | %-16s | %-20s | " "$site_name" "$domain" "${site_url:0:20}" >> "$SUMMARY_FILE"
            
            if [ $violations -gt 0 ]; then
                echo "发现 $violations 处违规内容" >> "$SUMMARY_FILE"
            else
                echo "正常" >> "$SUMMARY_FILE"
            fi
        else
            printf "%-20s | %-16s | %-20s | 扫描失败\n" "$site_name" "未知" "未知" >> "$SUMMARY_FILE"
        fi
    done
    
    echo "" >> "$SUMMARY_FILE"
    echo "总计: 发现 $total_violations 处可能的违规内容" >> "$SUMMARY_FILE"
    
    # 生成HTML报告
    generate_html_report
    
    # 扫描完成
    print_separator
    log_success "扫描完成，共发现 ${total_violations} 处可能的违规内容"
    log_info "文本报告: ${CYAN}${SUMMARY_FILE}${NC}"
    log_info "HTML报告: ${CYAN}${OUTPUT_DIR}/summary.html${NC}"
    print_separator
    
    # 提示打开HTML报告
    if command -v xdg-open &>/dev/null; then
        echo -e "${YELLOW}是否打开HTML报告? (y/n)${NC}"
        read -t 5 -n 1 open_report || true
        echo ""
        
        if [[ $open_report == "y" || $open_report == "Y" ]]; then
            xdg-open "${OUTPUT_DIR}/summary.html" &>/dev/null &
        fi
    fi
}

# 执行主程序
main

exit 0 