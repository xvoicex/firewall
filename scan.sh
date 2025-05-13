#!/bin/bash
# WordPress数据库扫描脚本 - 检测垃圾信息 (合并版本)
# 可通过 curl https://xxxxx | bash 方式运行

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 全局变量
SCRIPT_DIR="$(pwd)/wp_scan_$(date +%Y%m%d%H%M%S)"
REPORT_DIR="${SCRIPT_DIR}/reports"
TEMP_DIR="${SCRIPT_DIR}/temp"
TOTAL_SITES=0
TOTAL_SUSPICIOUS=0
FOUND_SITES=()
CURRENT_DATE=$(date +"%Y年%m月%d日 %H:%M:%S")
SCAN_START_TIME=$(date +%s)

# 确保目录存在
mkdir -p "$REPORT_DIR" "$TEMP_DIR"

# 这里会在脚本执行时插入HTML模板和报告生成器函数
# 为了减小脚本体积，将模板转换为纯代码嵌入

# --------------------------
# 1. 基础函数
# --------------------------

# 记录日志
log() {
    echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" >> "${SCRIPT_DIR}/scan.log"
}

# 显示帮助信息
show_banner() {
    echo -e "${BLUE}"
    echo "=============================================="
    echo "      WordPress 数据库扫描工具 V1.0"
    echo "=============================================="
    echo -e "${NC}"
    echo "检测垃圾信息、恶意代码及可疑内容"
    echo "扫描开始时间: ${CURRENT_DATE}"
    echo "报告输出目录: ${SCRIPT_DIR}"
    echo ""
}

# --------------------------
# 2. 站点查找和数据库连接函数
# --------------------------

# 查找所有WordPress站点
find_wordpress_sites() {
    log "开始查找WordPress站点..."
    
    # 只检查指定的网站根目录
    WEB_ROOTS=("/var/www/" "/www/wwwroot/")
    
    # 用于存储已找到的站点路径，防止重复添加
    local found_paths=()
    
    for root in "${WEB_ROOTS[@]}"; do
        if [ -d "$root" ]; then
            log "检查目录: $root"
            # 使用进程替换而不是管道，避免子shell问题
            while IFS= read -r config_file; do
                if [ -f "$config_file" ]; then
                    site_dir=$(dirname "$config_file")
                    
                    # 检查是否已经添加过该站点
                    local is_duplicate=0
                    for existing_path in "${found_paths[@]}"; do
                        if [ "$existing_path" = "$site_dir" ]; then
                            is_duplicate=1
                            break
                        fi
                    done
                    
                    if [ $is_duplicate -eq 0 ]; then
                        FOUND_SITES+=("$site_dir")
                        found_paths+=("$site_dir")
                        log "发现WordPress站点: $site_dir"
                        ((TOTAL_SITES++))
                    fi
                fi
            done < <(find "$root" -name "wp-config.php" -type f 2>/dev/null)
        fi
    done
    
    log "共发现 $TOTAL_SITES 个WordPress站点"
}

# 从wp-config.php中提取数据库信息
extract_db_info() {
    local wp_config=$1
    local prefix="wp_"
    
    # 提取数据库名称、用户名和密码
    DB_NAME=$(grep -o "define.*DB_NAME.*'.*'" "$wp_config" | cut -d\' -f4)
    DB_USER=$(grep -o "define.*DB_USER.*'.*'" "$wp_config" | cut -d\' -f4)
    DB_PASSWORD=$(grep -o "define.*DB_PASSWORD.*'.*'" "$wp_config" | cut -d\' -f4)
    DB_HOST=$(grep -o "define.*DB_HOST.*'.*'" "$wp_config" | cut -d\' -f4)
    
    # 如果没有指定主机，默认为localhost
    [ -z "$DB_HOST" ] && DB_HOST="localhost"
    
    # 提取表前缀
    local prefix_line=$(grep "\$table_prefix" "$wp_config")
    if [[ $prefix_line =~ table_prefix[[:space:]]*=[[:space:]]*[\"\'](.*)[\"\']\; ]]; then
        prefix="${BASH_REMATCH[1]}"
    fi
    
    echo "$DB_NAME|$DB_USER|$DB_PASSWORD|$DB_HOST|$prefix"
}

# 执行MySQL查询
execute_query() {
    local db_name=$1
    local db_user=$2
    local db_password=$3
    local db_host=$4
    local query=$5
    local output_file=$6
    
    mysql -h "$db_host" -u "$db_user" -p"$db_password" "$db_name" -e "$query" > "$output_file" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        log "错误: 执行SQL查询失败: $query"
        return 1
    fi
    
    return 0
}

# 获取站点URL
get_site_url() {
    local db_name=$1
    local db_user=$2
    local db_password=$3
    local db_host=$4
    local prefix=$5
    
    local query="SELECT option_value FROM ${prefix}options WHERE option_name = 'siteurl';"
    local output_file="${TEMP_DIR}/site_url.txt"
    
    execute_query "$db_name" "$db_user" "$db_password" "$db_host" "$query" "$output_file"
    
    if [ $? -eq 0 ]; then
        local site_url=$(tail -n 1 "$output_file")
        echo "$site_url"
    else
        echo "未知"
    fi
}

# --------------------------
# 3. 内容扫描函数
# --------------------------

# 扫描垃圾信息
scan_suspicious_content() {
    local site_dir=$1
    local db_info=$2
    local output_dir=$3
    
    # 解析数据库信息
    IFS='|' read -r DB_NAME DB_USER DB_PASSWORD DB_HOST DB_PREFIX <<< "$db_info"
    
    # 创建站点报告目录
    local site_report_dir="${output_dir}/$(basename "$site_dir")"
    mkdir -p "$site_report_dir"
    
    log "扫描站点: $site_dir (数据库: $DB_NAME)"
    
    # 获取站点URL
    local site_url=$(get_site_url "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$DB_PREFIX")
    log "站点URL: $site_url"
    
    # 创建扫描结果目录
    mkdir -p "${site_report_dir}/results"
    
    # 1. 扫描可疑文章内容
    local query1="SELECT ID, post_author, post_date, post_title, post_status, post_name, post_modified 
                 FROM ${DB_PREFIX}posts 
                 WHERE LOWER(post_content) LIKE '%eval(%' 
                    OR LOWER(post_content) LIKE '%base64_%' 
                    OR LOWER(post_content) LIKE '%gzinflate(%'
                    OR LOWER(post_content) LIKE '%porn%'
                    OR LOWER(post_content) LIKE '%xxx%'
                    OR LOWER(post_content) LIKE '%adult%'
                    OR post_content LIKE '%性爱%'
                    OR post_content LIKE '%色情%'
                    OR post_content LIKE '%成人%';"
    
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$query1" "${site_report_dir}/results/suspicious_posts.txt"
    local suspicious_posts=0
    if [ -f "${site_report_dir}/results/suspicious_posts.txt" ]; then
        # 确保文件非空并减去标题行
        local line_count=$(wc -l < "${site_report_dir}/results/suspicious_posts.txt")
        suspicious_posts=$((line_count > 1 ? line_count - 1 : 0))
    fi
    
    # 2. 扫描可疑用户
    local query2="SELECT user_login FROM ${DB_PREFIX}users 
                 WHERE LOWER(user_login) LIKE '%admin%' 
                    OR LOWER(user_login) LIKE '%test%'
                    OR LOWER(user_login) LIKE '%temp%';"
                    
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$query2" "${site_report_dir}/results/suspicious_users.txt"
    local suspicious_users=0
    if [ -f "${site_report_dir}/results/suspicious_users.txt" ]; then
        local line_count=$(wc -l < "${site_report_dir}/results/suspicious_users.txt")
        suspicious_users=$((line_count > 1 ? line_count - 1 : 0))
    fi
    
    # 3. 扫描可疑选项值
    local query3="SELECT option_id, option_name, autoload
                 FROM ${DB_PREFIX}options
                 WHERE LOWER(option_value) LIKE '%<script%' 
                    OR LOWER(option_value) LIKE '%eval(%' 
                    OR LOWER(option_value) LIKE '%base64_%';"
                    
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$query3" "${site_report_dir}/results/suspicious_options.txt"
    local suspicious_options=0
    if [ -f "${site_report_dir}/results/suspicious_options.txt" ]; then
        local line_count=$(wc -l < "${site_report_dir}/results/suspicious_options.txt")
        suspicious_options=$((line_count > 1 ? line_count - 1 : 0))
    fi
    
    # 4. 扫描可疑评论
    local query4="SELECT comment_post_ID, comment_content, comment_date
                 FROM ${DB_PREFIX}comments
                 WHERE LOWER(comment_content) LIKE '%<script%' 
                    OR LOWER(comment_content) LIKE '%iframe%'
                    OR LOWER(comment_content) LIKE '%porn%'
                    OR LOWER(comment_content) LIKE '%xxx%'
                    OR LOWER(comment_content) LIKE '%telegram%'
                    OR LOWER(comment_content) LIKE '%adult%';"
                    
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$query4" "${site_report_dir}/results/suspicious_comments.txt"
    local suspicious_comments=0
    if [ -f "${site_report_dir}/results/suspicious_comments.txt" ]; then
        local line_count=$(wc -l < "${site_report_dir}/results/suspicious_comments.txt")
        suspicious_comments=$((line_count > 1 ? line_count - 1 : 0))
    fi
    
    # 5. 扫描可疑元数据
    local query5="SELECT meta_id, post_id, meta_key, meta_value
                 FROM ${DB_PREFIX}postmeta 
                 WHERE LOWER(meta_value) LIKE '%<script%' 
                    OR LOWER(meta_value) LIKE '%eval(%' 
                    OR LOWER(meta_value) LIKE '%base64_%'
                    OR LOWER(meta_value) LIKE '%iframe%';"
                    
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$query5" "${site_report_dir}/results/suspicious_postmeta.txt"
    local suspicious_postmeta=0
    if [ -f "${site_report_dir}/results/suspicious_postmeta.txt" ]; then
        local line_count=$(wc -l < "${site_report_dir}/results/suspicious_postmeta.txt")
        suspicious_postmeta=$((line_count > 1 ? line_count - 1 : 0))
    fi
    
    # 6. 检查可疑日期文章
    local query6="SELECT p.ID, p.post_author, p.post_date, p.post_title, p.post_status, 
                       p.post_name, p.post_modified, u.user_login
                 FROM ${DB_PREFIX}posts p
                 JOIN ${DB_PREFIX}users u ON p.post_author = u.ID
                 WHERE p.post_date > NOW() 
                    OR p.post_modified > NOW();"
                    
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$query6" "${site_report_dir}/results/suspicious_dates.txt"
    local suspicious_dates=0
    if [ -f "${site_report_dir}/results/suspicious_dates.txt" ]; then
        local line_count=$(wc -l < "${site_report_dir}/results/suspicious_dates.txt")
        suspicious_dates=$((line_count > 1 ? line_count - 1 : 0))
    fi
    
    # 计算总可疑项目数
    local total_suspicious=$((suspicious_posts + suspicious_users + suspicious_options + suspicious_comments + suspicious_postmeta + suspicious_dates))
    ((TOTAL_SUSPICIOUS += total_suspicious))
    
    # 获取数据库大小
    local db_size_query="SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) 
                         FROM information_schema.tables 
                         WHERE table_schema = '$DB_NAME';"
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$db_size_query" "${site_report_dir}/results/db_size.txt"
    local db_size="0.00"
    if [ -f "${site_report_dir}/results/db_size.txt" ] && [ -s "${site_report_dir}/results/db_size.txt" ]; then
        db_size=$(tail -n 1 "${site_report_dir}/results/db_size.txt")
    fi
    
    # 获取表数量
    local table_count_query="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME';"
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$table_count_query" "${site_report_dir}/results/table_count.txt"
    local table_count="0"
    if [ -f "${site_report_dir}/results/table_count.txt" ] && [ -s "${site_report_dir}/results/table_count.txt" ]; then
        table_count=$(tail -n 1 "${site_report_dir}/results/table_count.txt")
    fi
    
    # 获取文章数量
    local post_count_query="SELECT COUNT(*) FROM ${DB_PREFIX}posts WHERE post_type = 'post' AND post_status = 'publish';"
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$post_count_query" "${site_report_dir}/results/post_count.txt"
    local post_count="0"
    if [ -f "${site_report_dir}/results/post_count.txt" ] && [ -s "${site_report_dir}/results/post_count.txt" ]; then
        post_count=$(tail -n 1 "${site_report_dir}/results/post_count.txt")
    fi
    
    # 获取用户数量
    local user_count_query="SELECT COUNT(*) FROM ${DB_PREFIX}users;"
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$user_count_query" "${site_report_dir}/results/user_count.txt"
    local user_count="0"
    if [ -f "${site_report_dir}/results/user_count.txt" ] && [ -s "${site_report_dir}/results/user_count.txt" ]; then
        user_count=$(tail -n 1 "${site_report_dir}/results/user_count.txt")
    fi
    
    # 获取评论数量
    local comment_count_query="SELECT COUNT(*) FROM ${DB_PREFIX}comments WHERE comment_approved = '1';"
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$comment_count_query" "${site_report_dir}/results/comment_count.txt"
    local comment_count="0"
    if [ -f "${site_report_dir}/results/comment_count.txt" ] && [ -s "${site_report_dir}/results/comment_count.txt" ]; then
        comment_count=$(tail -n 1 "${site_report_dir}/results/comment_count.txt")
    fi
    
    # 获取WordPress版本
    local wp_version_query="SELECT option_value FROM ${DB_PREFIX}options WHERE option_name = 'version';"
    execute_query "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$wp_version_query" "${site_report_dir}/results/wp_version.txt"
    local wp_version="未知"
    if [ -f "${site_report_dir}/results/wp_version.txt" ] && [ -s "${site_report_dir}/results/wp_version.txt" ]; then
        wp_version=$(tail -n 1 "${site_report_dir}/results/wp_version.txt")
    fi
    
    # 生成站点报告HTML
    log "生成站点报告: ${site_report_dir}/report.html"
    
    # 保存站点信息用于总报告
    echo "${site_dir}|${site_url}|${DB_NAME}|${db_size}|${table_count}|${post_count}|${user_count}|${comment_count}|${wp_version}|${total_suspicious}" >> "${TEMP_DIR}/all_sites_info.txt"
    
    # 创建单站点报告
    create_site_report "$site_dir" "$site_report_dir" "$site_url" "$DB_NAME" "$db_size" "$table_count" "$post_count" "$user_count" "$comment_count" "$wp_version" "$total_suspicious" "$suspicious_posts" "$suspicious_users" "$suspicious_options" "$suspicious_comments" "$suspicious_postmeta" "$suspicious_dates"
    
    log "站点扫描完成: $site_dir (发现可疑项: $total_suspicious)"
    
    # 创建临时目录保存站点可疑内容计数
    mkdir -p "${TEMP_DIR}/sites/${site_basename}"
    echo "$suspicious_posts" > "${TEMP_DIR}/sites/${site_basename}/suspicious_posts_count.txt"
    echo "$suspicious_users" > "${TEMP_DIR}/sites/${site_basename}/suspicious_users_count.txt"
    echo "$suspicious_options" > "${TEMP_DIR}/sites/${site_basename}/suspicious_options_count.txt"
    echo "$suspicious_comments" > "${TEMP_DIR}/sites/${site_basename}/suspicious_comments_count.txt"
    echo "$suspicious_postmeta" > "${TEMP_DIR}/sites/${site_basename}/suspicious_postmeta_count.txt"
    echo "$suspicious_dates" > "${TEMP_DIR}/sites/${site_basename}/suspicious_dates_count.txt"
}

# --------------------------
# 4. 报告生成函数
# --------------------------

# 创建HTML模板
create_html_template() {
    local template_dir=$1
    
    # 确保目录存在
    mkdir -p "$template_dir"
    
    # 创建简化版报告模板
    cat > "${template_dir}/report_template.html" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WordPress数据库扫描报告</title>
    <style>
        :root {
            --primary-color: #0073aa;
            --secondary-color: #005177;
            --accent-color: #d54e21;
            --light-gray: #f5f5f5;
            --dark-gray: #333;
            --success-color: #46b450;
            --warning-color: #ffb900;
            --danger-color: #dc3232;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            line-height: 1.6;
            color: #333;
            background-color: #f1f1f1;
        }
        .container { width: 90%; max-width: 1200px; margin: 2rem auto; }
        header {
            background-color: var(--primary-color);
            color: white;
            padding: 1.5rem;
            border-radius: 5px 5px 0 0;
        }
        .report-meta {
            display: flex;
            justify-content: space-between;
            background-color: var(--secondary-color);
            color: white;
            padding: 0.5rem 1.5rem;
            font-size: 0.9rem;
        }
        .content {
            background-color: white;
            padding: 1.5rem;
            border-radius: 0 0 5px 5px;
            box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
        }
        h1 { font-size: 1.8rem; margin-bottom: 0.5rem; }
        h2 { 
            font-size: 1.4rem; 
            margin: 1.5rem 0 1rem; 
            padding-bottom: 0.5rem;
            border-bottom: 1px solid #eee;
            color: var(--primary-color);
        }
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
            gap: 1rem;
            margin: 1.5rem 0;
        }
        .card {
            background-color: white;
            border-radius: 5px;
            padding: 1.5rem;
            box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
            border-top: 3px solid var(--primary-color);
        }
        .card h3 {
            font-size: 1.1rem;
            margin-bottom: 0.5rem;
            color: var(--dark-gray);
        }
        .card p.value {
            font-size: 2rem;
            font-weight: bold;
            color: var(--primary-color);
            margin-bottom: 0.5rem;
        }
        .card.warning { border-top-color: var(--warning-color); }
        .card.warning p.value { color: var(--warning-color); }
        .card.danger { border-top-color: var(--danger-color); }
        .card.danger p.value { color: var(--danger-color); }
        .card.success { border-top-color: var(--success-color); }
        .card.success p.value { color: var(--success-color); }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 1.5rem 0;
        }
        thead { background-color: var(--light-gray); }
        th, td {
            padding: 0.75rem;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th { font-weight: 600; }
        tr:hover { background-color: rgba(0, 115, 170, 0.05); }
        tr.suspicious { background-color: rgba(220, 50, 50, 0.1); }
        tr.suspicious td { border-left: 3px solid var(--danger-color); }
        footer {
            text-align: center;
            margin-top: 2rem;
            padding: 1rem;
            color: #777;
            font-size: 0.9rem;
        }
        .pagination-controls {
            display: flex;
            justify-content: center;
            margin: 1.5rem 0;
            gap: 0.5rem;
        }
        .pagination-controls button {
            padding: 0.5rem 1rem;
            background-color: white;
            border: 1px solid #ddd;
            border-radius: 3px;
            cursor: pointer;
            transition: background-color 0.2s;
        }
        .pagination-controls button:hover { background-color: var(--light-gray); }
        .pagination-controls button.active {
            background-color: var(--primary-color);
            color: white;
            border-color: var(--primary-color);
        }
        .pagination-controls button:disabled { opacity: 0.5; cursor: not-allowed; }
        .search-box {
            margin: 1rem 0;
            display: flex;
            gap: 0.5rem;
        }
        .search-box input {
            flex: 1;
            padding: 0.5rem;
            border: 1px solid #ddd;
            border-radius: 3px;
        }
        .search-box button {
            padding: 0.5rem 1rem;
            background-color: var(--primary-color);
            color: white;
            border: none;
            border-radius: 3px;
            cursor: pointer;
        }
        .collapsible { margin-top: 1rem; }
        .collapsible-header {
            background-color: var(--light-gray);
            padding: 0.75rem;
            border-radius: 3px;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .collapsible-header::after { content: "+"; font-size: 1.2rem; font-weight: bold; }
        .collapsible-header.active::after { content: "-"; }
        .collapsible-content {
            display: none;
            padding: 1rem;
            border: 1px solid #ddd;
            border-top: none;
            border-radius: 0 0 3px 3px;
        }
    </style>
    <script>
        document.addEventListener('DOMContentLoaded', function() {
            // 折叠面板功能
            const collapsibles = document.querySelectorAll('.collapsible-header');
            collapsibles.forEach(header => {
                header.addEventListener('click', function() {
                    this.classList.toggle('active');
                    const content = this.nextElementSibling;
                    if (content.style.display === 'block') {
                        content.style.display = 'none';
                    } else {
                        content.style.display = 'block';
                    }
                });
            });
            
            // 表格分页功能
            initPagination('site-url-table', 5);
            
            // 搜索功能
            const searchButton = document.getElementById('search-button');
            const searchInput = document.getElementById('search-input');
            
            if (searchButton && searchInput) {
                searchButton.addEventListener('click', function() {
                    searchSites(searchInput.value);
                });
                
                searchInput.addEventListener('keypress', function(e) {
                    if (e.key === 'Enter') {
                        searchSites(searchInput.value);
                    }
                });
            }
        });
        
        // 分页逻辑
        function initPagination(tableId, itemsPerPage) {
            const table = document.getElementById(tableId);
            if (!table) return;
            
            const tbody = table.querySelector('tbody');
            const rows = tbody.querySelectorAll('tr');
            const pageCount = Math.ceil(rows.length / itemsPerPage);
            
            // 创建分页控制区
            const paginationDiv = document.createElement('div');
            paginationDiv.className = 'pagination-controls';
            table.parentNode.insertBefore(paginationDiv, table.nextSibling);
            
            // 添加页码按钮
            const prevBtn = document.createElement('button');
            prevBtn.innerText = '上一页';
            prevBtn.addEventListener('click', () => goToPage(currentPage - 1));
            paginationDiv.appendChild(prevBtn);
            
            // 页码按钮
            for (let i = 1; i <= pageCount; i++) {
                const pageBtn = document.createElement('button');
                pageBtn.innerText = i;
                pageBtn.addEventListener('click', () => goToPage(i));
                paginationDiv.appendChild(pageBtn);
            }
            
            const nextBtn = document.createElement('button');
            nextBtn.innerText = '下一页';
            nextBtn.addEventListener('click', () => goToPage(currentPage + 1));
            paginationDiv.appendChild(nextBtn);
            
            // 显示第一页
            let currentPage = 1;
            goToPage(currentPage);
            
            function goToPage(page) {
                if (page < 1 || page > pageCount) return;
                
                currentPage = page;
                const start = (page - 1) * itemsPerPage;
                const end = start + itemsPerPage;
                
                // 隐藏所有行
                rows.forEach(row => row.style.display = 'none');
                
                // 显示当前页的行
                for (let i = start; i < end && i < rows.length; i++) {
                    rows[i].style.display = '';
                }
                
                // 更新按钮状态
                updatePaginationButtons();
            }
            
            function updatePaginationButtons() {
                const buttons = paginationDiv.querySelectorAll('button');
                buttons.forEach((button, i) => {
                    if (i === 0) { // 前一页按钮
                        button.disabled = currentPage === 1;
                    } else if (i === buttons.length - 1) { // 下一页按钮
                        button.disabled = currentPage === pageCount;
                    } else { // 页码按钮
                        button.classList.toggle('active', i === currentPage);
                    }
                });
            }
        }
        
        // 搜索功能
        function searchSites(query) {
            if (!query) return;
            
            query = query.toLowerCase();
            const table = document.getElementById('site-url-table');
            const rows = table.querySelectorAll('tbody tr');
            
            let hasResults = false;
            
            rows.forEach(row => {
                const text = row.textContent.toLowerCase();
                if (text.includes(query)) {
                    row.style.display = '';
                    hasResults = true;
                } else {
                    row.style.display = 'none';
                }
            });
            
            // 隐藏分页控制
            const pagination = table.nextElementSibling;
            if (pagination && pagination.classList.contains('pagination-controls')) {
                pagination.style.display = query ? 'none' : 'flex';
            }
            
            // 显示搜索结果信息
            const resultInfo = document.getElementById('search-result-info');
            if (resultInfo) {
                resultInfo.textContent = hasResults 
                    ? `找到包含"${query}"的结果` 
                    : `未找到包含"${query}"的结果`;
                resultInfo.style.display = 'block';
            }
        }
    </script>
</head>
<body>
    <div class="container">
        <header>
            <h1>WordPress数据库扫描报告</h1>
            <p>服务器：{{SERVER_NAME}}</p>
        </header>
        <div class="report-meta">
            <span>生成时间：{{SCAN_DATE}}</span>
            <span>扫描耗时：{{SCAN_DURATION}}</span>
        </div>
        <div class="content">
            <section>
                <h2>概览</h2>
                <div class="summary-cards">
                    <div class="card">
                        <h3>WordPress数据库总数</h3>
                        <p class="value">{{TOTAL_DBS}}</p>
                    </div>
                    <div class="card">
                        <h3>总数据库大小</h3>
                        <p class="value">{{TOTAL_SIZE}} MB</p>
                    </div>
                    <div class="card">
                        <h3>总网站数</h3>
                        <p class="value">{{TOTAL_SITES}}</p>
                    </div>
                    <div class="card">
                        <h3>扫描站点总数</h3>
                        <p class="value">{{SCAN_SITES}}</p>
                    </div>
                </div>
            </section>
            
            <section>
                <h2>站点URL信息</h2>
                <div class="search-box">
                    <input type="text" id="search-input" placeholder="搜索站点...">
                    <button id="search-button">搜索</button>
                </div>
                <p id="search-result-info" style="display: none; margin: 1rem 0; font-style: italic;"></p>
                <table id="site-url-table">
                    <thead>
                        <tr>
                            <th>数据库名称</th>
                            <th>站点URL</th>
                            <th>首页URL</th>
                            <th>多站点</th>
                            <th>状态</th>
                        </tr>
                    </thead>
                    <tbody>
                        {{SITE_URL_TABLE_ROWS}}
                    </tbody>
                </table>
            </section>
            
            <section>
                <h2>垃圾信息检测结果</h2>
                <div class="summary-cards">
                    <div class="card">
                        <h3>扫描内容总数</h3>
                        <p class="value">{{TOTAL_CONTENT}}</p>
                    </div>
                    <div class="card" style="border-top-color: var(--danger-color);">
                        <h3>可疑内容数</h3>
                        <p class="value" style="color: var(--danger-color);">{{TOTAL_SUSPICIOUS}}</p>
                    </div>
                    <div class="card">
                        <h3>可疑站点数</h3>
                        <p class="value">{{SUSPICIOUS_SITES}}</p>
                    </div>
                    <div class="card">
                        <h3>检测关键词数</h3>
                        <p class="value">24</p>
                    </div>
                </div>
                
                <div class="collapsible">
                    <div class="collapsible-header">可疑文章内容</div>
                    <div class="collapsible-content">
                        <table>
                            <thead>
                                <tr>
                                    <th>数据库</th>
                                    <th>文章ID</th>
                                    <th>标题</th>
                                    <th>作者</th>
                                    <th>发布日期</th>
                                    <th>匹配关键词</th>
                                    <th>操作</th>
                                </tr>
                            </thead>
                            <tbody>
                                {{SUSPICIOUS_POSTS_ROWS}}
                            </tbody>
                        </table>
                    </div>
                </div>
                
                <div class="collapsible">
                    <div class="collapsible-header">可疑选项值</div>
                    <div class="collapsible-content">
                        <table>
                            <thead>
                                <tr>
                                    <th>数据库</th>
                                    <th>选项ID</th>
                                    <th>选项名称</th>
                                    <th>自动加载</th>
                                    <th>匹配关键词</th>
                                    <th>操作</th>
                                </tr>
                            </thead>
                            <tbody>
                                {{SUSPICIOUS_OPTIONS_ROWS}}
                            </tbody>
                        </table>
                    </div>
                </div>
                
                <div class="collapsible">
                    <div class="collapsible-header">可疑评论内容</div>
                    <div class="collapsible-content">
                        <table>
                            <thead>
                                <tr>
                                    <th>数据库</th>
                                    <th>文章ID</th>
                                    <th>评论日期</th>
                                    <th>匹配关键词</th>
                                    <th>操作</th>
                                </tr>
                            </thead>
                            <tbody>
                                {{SUSPICIOUS_COMMENTS_ROWS}}
                            </tbody>
                        </table>
                    </div>
                </div>
                
                <div class="collapsible">
                    <div class="collapsible-header">可疑元数据</div>
                    <div class="collapsible-content">
                        <table>
                            <thead>
                                <tr>
                                    <th>数据库</th>
                                    <th>元数据ID</th>
                                    <th>文章ID</th>
                                    <th>元数据键</th>
                                    <th>匹配关键词</th>
                                    <th>操作</th>
                                </tr>
                            </thead>
                            <tbody>
                                {{SUSPICIOUS_POSTMETA_ROWS}}
                            </tbody>
                        </table>
                    </div>
                </div>
                
                <div class="collapsible">
                    <div class="collapsible-header">可疑用户账号</div>
                    <div class="collapsible-content">
                        <table>
                            <thead>
                                <tr>
                                    <th>数据库</th>
                                    <th>用户名</th>
                                    <th>创建时间</th>
                                    <th>匹配条件</th>
                                    <th>操作</th>
                                </tr>
                            </thead>
                            <tbody>
                                {{SUSPICIOUS_USERS_ROWS}}
                            </tbody>
                        </table>
                    </div>
                </div>
                
                <div class="collapsible">
                    <div class="collapsible-header">可疑日期内容</div>
                    <div class="collapsible-content">
                        <table>
                            <thead>
                                <tr>
                                    <th>数据库</th>
                                    <th>文章ID</th>
                                    <th>标题</th>
                                    <th>作者</th>
                                    <th>发布/修改日期</th>
                                    <th>异常</th>
                                    <th>操作</th>
                                </tr>
                            </thead>
                            <tbody>
                                {{SUSPICIOUS_DATES_ROWS}}
                            </tbody>
                        </table>
                    </div>
                </div>
            </section>
        </div>
        <footer>
            <p>WordPress数据库扫描报告 | 生成于{{SCAN_DATE}} | v1.0</p>
        </footer>
    </div>
</body>
</html>
EOF

    # 创建站点报告模板 - 修改主模板适用于单站点报告
    sed -e 's|<h1>WordPress数据库扫描报告</h1>|<h1>数据库 {{DB_NAME}} 扫描报告</h1>|g' \
        -e 's|<p>服务器：{{SERVER_NAME}}</p>|<p>站点目录：{{SITE_DIR}}</p>|g' \
        "${template_dir}/report_template.html" > "${template_dir}/site_report_template.html"
    
    # 保持主报告模板原样
    cp "${template_dir}/report_template.html" "${template_dir}/main_report_template.html"
    
    echo "报告模板准备完成"
}

# 准备报告模板
prepare_templates() {
    log "准备报告模板..."
    
    # 创建模板目录
    mkdir -p "${TEMP_DIR}/templates"
    
    # 创建HTML模板
    create_html_template "${TEMP_DIR}/templates"
    
    log "报告模板准备完成"
}

# 创建单站点报告
create_site_report() {
    local site_dir=$1
    local site_report_dir=$2
    local site_url=$3
    local db_name=$4
    local db_size=$5
    local table_count=$6
    local post_count=$7
    local user_count=$8
    local comment_count=$9
    local wp_version=${10}
    local total_suspicious=${11}
    local suspicious_posts=${12}
    local suspicious_users=${13}
    local suspicious_options=${14}
    local suspicious_comments=${15}
    local suspicious_postmeta=${16}
    local suspicious_dates=${17}
    
    # 确保WordPress版本不为空
    if [ -z "$wp_version" ] || [ "$wp_version" = "未知" ]; then
        # 尝试从wp-includes/version.php文件获取版本
        if [ -f "${site_dir}/wp-includes/version.php" ]; then
            wp_version=$(grep -oP "\\\$wp_version\s*=\s*'[^']+'" "${site_dir}/wp-includes/version.php" | cut -d"'" -f2)
            # 保存到文件
            echo -e "version\n${wp_version}" > "${site_report_dir}/results/wp_version.txt"
        fi
    fi
    
    # 如果仍然未知，设置默认值
    [ -z "$wp_version" ] && wp_version="未知"
    
    # 检查结果文件存在性
    local results_dir="${site_report_dir}/results"
    for result_file in suspicious_posts.txt suspicious_users.txt suspicious_options.txt suspicious_comments.txt suspicious_postmeta.txt suspicious_dates.txt; do
        if [ ! -f "${results_dir}/${result_file}" ]; then
            touch "${results_dir}/${result_file}"
        fi
    done
    
    # 准备报告数据
    local site_name=$(basename "$site_dir")
    
    # 创建HTML报告
    cat > "${site_report_dir}/report.html" << EOL
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WordPress站点扫描报告 - ${site_name}</title>
    <style>
        body {
            font-family: 'Arial', sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        header {
            background-color: #2c3e50;
            color: white;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 20px;
        }
        h1, h2, h3 {
            color: #2c3e50;
        }
        header h1 {
            color: white;
            margin: 0;
        }
        .dashboard {
            display: flex;
            flex-wrap: wrap;
            gap: 20px;
            margin-bottom: 20px;
        }
        .card {
            background-color: white;
            border-radius: 5px;
            padding: 20px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
            flex: 1;
            min-width: 200px;
        }
        .warning {
            background-color: #e74c3c;
            color: white;
        }
        .safe {
            background-color: #2ecc71;
            color: white;
        }
        .number {
            font-size: 2.5em;
            font-weight: bold;
            margin: 10px 0;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            background-color: white;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #2c3e50;
            color: white;
        }
        tr:hover {
            background-color: #f5f5f5;
        }
        .tabs {
            margin-top: 20px;
        }
        .tab-button {
            background-color: #f5f5f5;
            border: none;
            padding: 10px 20px;
            margin-right: 5px;
            cursor: pointer;
            border-radius: 5px 5px 0 0;
        }
        .tab-button.active {
            background-color: #2c3e50;
            color: white;
        }
        .tab-content {
            display: none;
            padding: 20px;
            background-color: white;
            border-radius: 0 5px 5px 5px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .tab-content.active {
            display: block;
        }
        footer {
            margin-top: 30px;
            text-align: center;
            font-size: 0.9em;
            color: #7f8c8d;
        }
    </style>
</head>
<body>
    <header>
        <h1>WordPress站点扫描报告</h1>
        <p>站点: ${site_name} (${site_url})</p>
    </header>
    
    <div class="dashboard">
        <div class="card ${total_suspicious > 0 ? 'warning' : 'safe'}">
            <h3>可疑内容</h3>
            <div class="number">${total_suspicious}</div>
            <p>检测到的可疑项目总数</p>
        </div>
        <div class="card">
            <h3>WordPress信息</h3>
            <p>版本: ${wp_version}</p>
            <p>数据库: ${db_name}</p>
            <p>大小: ${db_size} MB</p>
        </div>
        <div class="card">
            <h3>内容统计</h3>
            <p>表: ${table_count}</p>
            <p>文章: ${post_count}</p>
            <p>用户: ${user_count}</p>
            <p>评论: ${comment_count}</p>
        </div>
    </div>
    
    <div class="tabs">
        <button class="tab-button active" onclick="openTab(event, 'suspicious-posts')">可疑文章 (${suspicious_posts})</button>
        <button class="tab-button" onclick="openTab(event, 'suspicious-users')">可疑用户 (${suspicious_users})</button>
        <button class="tab-button" onclick="openTab(event, 'suspicious-options')">可疑选项 (${suspicious_options})</button>
        <button class="tab-button" onclick="openTab(event, 'suspicious-comments')">可疑评论 (${suspicious_comments})</button>
        <button class="tab-button" onclick="openTab(event, 'suspicious-postmeta')">可疑元数据 (${suspicious_postmeta})</button>
        <button class="tab-button" onclick="openTab(event, 'suspicious-dates')">可疑日期 (${suspicious_dates})</button>
    </div>
    
    <div id="suspicious-posts" class="tab-content active">
        <h3>可疑文章内容</h3>
EOL

    # 插入可疑文章表格
    if [ "$suspicious_posts" -gt 0 ]; then
        echo '<table><thead><tr>' >> "${site_report_dir}/report.html"
        head -n 1 "${results_dir}/suspicious_posts.txt" | awk -F'\t' '{for(i=1; i<=NF; i++) printf "<th>%s</th>", $i; print ""}' >> "${site_report_dir}/report.html"
        echo '</tr></thead><tbody>' >> "${site_report_dir}/report.html"
        
        tail -n +2 "${results_dir}/suspicious_posts.txt" | awk -F'\t' '{print "<tr>"; for(i=1; i<=NF; i++) printf "<td>%s</td>", $i; print "</tr>"}' >> "${site_report_dir}/report.html"
        
        echo '</tbody></table>' >> "${site_report_dir}/report.html"
    else
        echo '<p>未发现可疑文章内容</p>' >> "${site_report_dir}/report.html"
    fi

    cat >> "${site_report_dir}/report.html" << EOL
    </div>
    
    <div id="suspicious-users" class="tab-content">
        <h3>可疑用户</h3>
EOL

    # 插入可疑用户表格
    if [ "$suspicious_users" -gt 0 ]; then
        echo '<table><thead><tr>' >> "${site_report_dir}/report.html"
        head -n 1 "${results_dir}/suspicious_users.txt" | awk -F'\t' '{for(i=1; i<=NF; i++) printf "<th>%s</th>", $i; print ""}' >> "${site_report_dir}/report.html"
        echo '</tr></thead><tbody>' >> "${site_report_dir}/report.html"
        
        tail -n +2 "${results_dir}/suspicious_users.txt" | awk -F'\t' '{print "<tr>"; for(i=1; i<=NF; i++) printf "<td>%s</td>", $i; print "</tr>"}' >> "${site_report_dir}/report.html"
        
        echo '</tbody></table>' >> "${site_report_dir}/report.html"
    else
        echo '<p>未发现可疑用户</p>' >> "${site_report_dir}/report.html"
    fi

    cat >> "${site_report_dir}/report.html" << EOL
    </div>
    
    <div id="suspicious-options" class="tab-content">
        <h3>可疑选项值</h3>
EOL

    # 插入可疑选项表格
    if [ "$suspicious_options" -gt 0 ]; then
        echo '<table><thead><tr>' >> "${site_report_dir}/report.html"
        head -n 1 "${results_dir}/suspicious_options.txt" | awk -F'\t' '{for(i=1; i<=NF; i++) printf "<th>%s</th>", $i; print ""}' >> "${site_report_dir}/report.html"
        echo '</tr></thead><tbody>' >> "${site_report_dir}/report.html"
        
        tail -n +2 "${results_dir}/suspicious_options.txt" | awk -F'\t' '{print "<tr>"; for(i=1; i<=NF; i++) printf "<td>%s</td>", $i; print "</tr>"}' >> "${site_report_dir}/report.html"
        
        echo '</tbody></table>' >> "${site_report_dir}/report.html"
    else
        echo '<p>未发现可疑选项值</p>' >> "${site_report_dir}/report.html"
    fi

    cat >> "${site_report_dir}/report.html" << EOL
    </div>
    
    <div id="suspicious-comments" class="tab-content">
        <h3>可疑评论</h3>
EOL

    # 插入可疑评论表格
    if [ "$suspicious_comments" -gt 0 ]; then
        echo '<table><thead><tr>' >> "${site_report_dir}/report.html"
        head -n 1 "${results_dir}/suspicious_comments.txt" | awk -F'\t' '{for(i=1; i<=NF; i++) printf "<th>%s</th>", $i; print ""}' >> "${site_report_dir}/report.html"
        echo '</tr></thead><tbody>' >> "${site_report_dir}/report.html"
        
        tail -n +2 "${results_dir}/suspicious_comments.txt" | awk -F'\t' '{print "<tr>"; for(i=1; i<=NF; i++) printf "<td>%s</td>", $i; print "</tr>"}' >> "${site_report_dir}/report.html"
        
        echo '</tbody></table>' >> "${site_report_dir}/report.html"
    else
        echo '<p>未发现可疑评论</p>' >> "${site_report_dir}/report.html"
    fi

    cat >> "${site_report_dir}/report.html" << EOL
    </div>
    
    <div id="suspicious-postmeta" class="tab-content">
        <h3>可疑元数据</h3>
EOL

    # 插入可疑元数据表格
    if [ "$suspicious_postmeta" -gt 0 ]; then
        echo '<table><thead><tr>' >> "${site_report_dir}/report.html"
        head -n 1 "${results_dir}/suspicious_postmeta.txt" | awk -F'\t' '{for(i=1; i<=NF; i++) printf "<th>%s</th>", $i; print ""}' >> "${site_report_dir}/report.html"
        echo '</tr></thead><tbody>' >> "${site_report_dir}/report.html"
        
        tail -n +2 "${results_dir}/suspicious_postmeta.txt" | awk -F'\t' '{print "<tr>"; for(i=1; i<=NF; i++) printf "<td>%s</td>", $i; print "</tr>"}' >> "${site_report_dir}/report.html"
        
        echo '</tbody></table>' >> "${site_report_dir}/report.html"
    else
        echo '<p>未发现可疑元数据</p>' >> "${site_report_dir}/report.html"
    fi

    cat >> "${site_report_dir}/report.html" << EOL
    </div>
    
    <div id="suspicious-dates" class="tab-content">
        <h3>可疑日期</h3>
EOL

    # 插入可疑日期表格
    if [ "$suspicious_dates" -gt 0 ]; then
        echo '<table><thead><tr>' >> "${site_report_dir}/report.html"
        head -n 1 "${results_dir}/suspicious_dates.txt" | awk -F'\t' '{for(i=1; i<=NF; i++) printf "<th>%s</th>", $i; print ""}' >> "${site_report_dir}/report.html"
        echo '</tr></thead><tbody>' >> "${site_report_dir}/report.html"
        
        tail -n +2 "${results_dir}/suspicious_dates.txt" | awk -F'\t' '{print "<tr>"; for(i=1; i<=NF; i++) printf "<td>%s</td>", $i; print "</tr>"}' >> "${site_report_dir}/report.html"
        
        echo '</tbody></table>' >> "${site_report_dir}/report.html"
    else
        echo '<p>未发现可疑日期</p>' >> "${site_report_dir}/report.html"
    fi

    cat >> "${site_report_dir}/report.html" << EOL
    </div>
    
    <footer>
        <p>WordPress数据库扫描工具 - 扫描路径: ${site_dir}</p>
    </footer>
    
    <script>
        function openTab(evt, tabName) {
            var i, tabcontent, tabbuttons;
            
            // 隐藏所有标签内容
            tabcontent = document.getElementsByClassName("tab-content");
            for (i = 0; i < tabcontent.length; i++) {
                tabcontent[i].className = tabcontent[i].className.replace(" active", "");
            }
            
            // 移除所有标签按钮的active类
            tabbuttons = document.getElementsByClassName("tab-button");
            for (i = 0; i < tabbuttons.length; i++) {
                tabbuttons[i].className = tabbuttons[i].className.replace(" active", "");
            }
            
            // 显示当前标签，并添加active类到按钮
            document.getElementById(tabName).className += " active";
            evt.currentTarget.className += " active";
        }
    </script>
</body>
</html>
EOL

    log "站点报告生成完成: ${site_report_dir}/report.html"
}

# 创建总报告
create_master_report() {
    local output_dir=$1
    local timestamp=$2
    local site_count=$3
    
    log "生成总报告: ${output_dir}/index.html"
    
    # 读取所有站点信息
    local all_sites=()
    local total_suspicious=0
    local total_posts=0
    local total_users=0
    local total_comments=0
    local total_sites=0
    local total_size=0
    local total_tables=0
    
    # 统计各类可疑内容数量
    local total_suspicious_posts=0
    local total_suspicious_users=0
    local total_suspicious_options=0
    local total_suspicious_comments=0
    local total_suspicious_postmeta=0
    local total_suspicious_dates=0
    
    if [ -f "${TEMP_DIR}/all_sites_info.txt" ]; then
        while IFS='|' read -r site_dir site_url db_name db_size table_count post_count user_count comment_count wp_version suspicious_count; do
            all_sites+=("$site_dir|$site_url|$db_name|$db_size|$table_count|$post_count|$user_count|$comment_count|$wp_version|$suspicious_count")
            ((total_suspicious += suspicious_count))
            ((total_posts += post_count))
            ((total_users += user_count))
            ((total_comments += comment_count))
            ((total_sites++))
            
            # 数据库大小计算确保是数值
            log "处理站点 ${db_name} 的数据库大小: ${db_size}"
            db_size=$(echo "$db_size" | sed 's/[^0-9.]//g')
            log "清理后的数据库大小: ${db_size}"
            
            if [[ "$db_size" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                # 使用更可靠的方式计算
                if command -v awk &>/dev/null; then
                    total_size=$(awk "BEGIN {print $total_size + $db_size}")
                    log "使用awk计算后的总大小: ${total_size}"
                else
                    total_size=$(echo "$total_size + $db_size" | bc 2>/dev/null || echo "$total_size")
                    log "使用bc计算后的总大小: ${total_size}"
                fi
            fi
            
            ((total_tables += table_count))
            
            # 获取每个站点的可疑内容具体信息
            site_basename=$(basename "$site_dir")
            local site_report_path="${output_dir}/${site_basename}"
            
            # 获取可疑文章数
            if [ -f "${site_report_path}/results/suspicious_posts.txt" ]; then
                local line_count=$(wc -l < "${site_report_path}/results/suspicious_posts.txt")
                local site_suspicious_posts=$((line_count > 1 ? line_count - 1 : 0))
                ((total_suspicious_posts += site_suspicious_posts))
            fi
            
            # 获取可疑用户数
            if [ -f "${site_report_path}/results/suspicious_users.txt" ]; then
                local line_count=$(wc -l < "${site_report_path}/results/suspicious_users.txt")
                local site_suspicious_users=$((line_count > 1 ? line_count - 1 : 0))
                ((total_suspicious_users += site_suspicious_users))
            fi
            
            # 获取可疑选项数
            if [ -f "${site_report_path}/results/suspicious_options.txt" ]; then
                local line_count=$(wc -l < "${site_report_path}/results/suspicious_options.txt")
                local site_suspicious_options=$((line_count > 1 ? line_count - 1 : 0))
                ((total_suspicious_options += site_suspicious_options))
            fi
            
            # 获取可疑评论数
            if [ -f "${site_report_path}/results/suspicious_comments.txt" ]; then
                local line_count=$(wc -l < "${site_report_path}/results/suspicious_comments.txt")
                local site_suspicious_comments=$((line_count > 1 ? line_count - 1 : 0))
                ((total_suspicious_comments += site_suspicious_comments))
            fi
            
            # 获取可疑元数据数
            if [ -f "${site_report_path}/results/suspicious_postmeta.txt" ]; then
                local line_count=$(wc -l < "${site_report_path}/results/suspicious_postmeta.txt")
                local site_suspicious_postmeta=$((line_count > 1 ? line_count - 1 : 0))
                ((total_suspicious_postmeta += site_suspicious_postmeta))
            fi
            
            # 获取可疑日期数
            if [ -f "${site_report_path}/results/suspicious_dates.txt" ]; then
                local line_count=$(wc -l < "${site_report_path}/results/suspicious_dates.txt")
                local site_suspicious_dates=$((line_count > 1 ? line_count - 1 : 0))
                ((total_suspicious_dates += site_suspicious_dates))
            fi
        done < "${TEMP_DIR}/all_sites_info.txt"
    fi
    
    # 确保total_size是一个有效数字
    total_size=$(echo "$total_size" | sed 's/[^0-9.]//g')
    if [ -z "$total_size" ]; then
        total_size="0"
    fi
    
    # 获取主机名
    local hostname=$(hostname)
    
    # 创建HTML报告
    cat > "${output_dir}/index.html" << EOL
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WordPress数据库扫描报告</title>
    <style>
        :root {
            --primary-color: #0073aa;
            --secondary-color: #005177;
            --accent-color: #d54e21;
            --light-gray: #f5f5f5;
            --dark-gray: #333;
            --success-color: #46b450;
            --warning-color: #ffb900;
            --danger-color: #dc3232;
        }
        
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen-Sans, Ubuntu, Cantarell, "Helvetica Neue", sans-serif;
            line-height: 1.6;
            color: #333;
            background-color: #f1f1f1;
        }
        
        .container {
            width: 90%;
            max-width: 1200px;
            margin: 2rem auto;
        }
        
        header {
            background-color: var(--primary-color);
            color: white;
            padding: 1.5rem;
            border-radius: 5px 5px 0 0;
        }
        
        .report-meta {
            display: flex;
            justify-content: space-between;
            background-color: var(--secondary-color);
            color: white;
            padding: 0.5rem 1.5rem;
            font-size: 0.9rem;
        }
        
        .content {
            background-color: white;
            padding: 1.5rem;
            border-radius: 0 0 5px 5px;
            box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
        }
        
        h1 {
            font-size: 1.8rem;
            margin-bottom: 0.5rem;
        }
        
        h2 {
            font-size: 1.4rem;
            margin: 1.5rem 0 1rem;
            padding-bottom: 0.5rem;
            border-bottom: 1px solid #eee;
            color: var(--primary-color);
        }
        
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
            gap: 1rem;
            margin: 1.5rem 0;
        }
        
        .card {
            background-color: white;
            border-radius: 5px;
            padding: 1.5rem;
            box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
            border-top: 3px solid var(--primary-color);
        }
        
        .card h3 {
            font-size: 1.1rem;
            margin-bottom: 0.5rem;
            color: var(--dark-gray);
        }
        
        .card p.value {
            font-size: 2rem;
            font-weight: bold;
            color: var(--primary-color);
            margin-bottom: 0.5rem;
        }
        
        .card.warning {
            border-top-color: var(--warning-color);
        }
        
        .card.warning p.value {
            color: var(--warning-color);
        }
        
        .card.danger {
            border-top-color: var(--danger-color);
        }
        
        .card.danger p.value {
            color: var(--danger-color);
        }
        
        .card.success {
            border-top-color: var(--success-color);
        }
        
        .card.success p.value {
            color: var(--success-color);
        }

        table {
            width: 100%;
            border-collapse: collapse;
            margin: 1.5rem 0;
        }
        
        thead {
            background-color: var(--light-gray);
        }
        
        th, td {
            padding: 0.75rem;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        
        th {
            font-weight: 600;
        }
        
        tr:hover {
            background-color: rgba(0, 115, 170, 0.05);
        }
        
        tr.child-site {
            background-color: rgba(0, 115, 170, 0.03);
        }
        
        tr.child-site td {
            padding-left: 2rem;
            font-size: 0.95em;
        }
        
        .suspicious-low a {
            color: var(--primary-color);
        }
        
        .suspicious-medium a {
            color: var(--warning-color);
        }
        
        .suspicious-high a {
            color: var(--danger-color);
        }
        
        .site-link {
            text-decoration: none;
            color: var(--primary-color);
        }
        
        .site-link:hover {
            text-decoration: underline;
        }
        
        footer {
            text-align: center;
            margin-top: 2rem;
            padding: 1rem;
            color: #777;
            font-size: 0.9rem;
        }
        
        @media (max-width: 768px) {
            .container {
                width: 95%;
            }
            
            .summary-cards {
                grid-template-columns: 1fr;
            }
        }
        
        /* 分页控制样式 */
        .pagination-controls {
            display: flex;
            justify-content: center;
            margin: 1.5rem 0;
            gap: 0.5rem;
        }
        
        .pagination-controls button {
            padding: 0.5rem 1rem;
            background-color: white;
            border: 1px solid #ddd;
            border-radius: 3px;
            cursor: pointer;
            transition: background-color 0.2s;
        }
        
        .pagination-controls button:hover {
            background-color: var(--light-gray);
        }
        
        .pagination-controls button.active {
            background-color: var(--primary-color);
            color: white;
            border-color: var(--primary-color);
        }
        
        .pagination-controls button:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }
        
        /* 搜索框样式 */
        .search-box {
            margin: 1rem 0;
            display: flex;
            gap: 0.5rem;
        }
        
        .search-box input {
            flex: 1;
            padding: 0.5rem;
            border: 1px solid #ddd;
            border-radius: 3px;
        }
        
        .search-box button {
            padding: 0.5rem 1rem;
            background-color: var(--primary-color);
            color: white;
            border: none;
            border-radius: 3px;
            cursor: pointer;
        }
    </style>
    <script>
        // 页面加载完成后执行
        document.addEventListener('DOMContentLoaded', function() {
            // 站点表格分页功能
            initPagination('site-url-table', 30);
            
            // 搜索功能
            const searchButton = document.getElementById('search-button');
            const searchInput = document.getElementById('search-input');
            
            if (searchButton && searchInput) {
                searchButton.addEventListener('click', function() {
                    searchSites(searchInput.value);
                });
                
                searchInput.addEventListener('keypress', function(e) {
                    if (e.key === 'Enter') {
                        searchSites(searchInput.value);
                    }
                });
            }
        });
        
        // 分页逻辑
        function initPagination(tableId, itemsPerPage) {
            const table = document.getElementById(tableId);
            if (!table) return;
            
            const tbody = table.querySelector('tbody');
            const rows = tbody.querySelectorAll('tr');
            const pageCount = Math.ceil(rows.length / itemsPerPage);
            
            // 创建分页控制区
            const paginationDiv = document.createElement('div');
            paginationDiv.className = 'pagination-controls';
            table.parentNode.insertBefore(paginationDiv, table.nextSibling);
            
            // 添加页码按钮
            const prevBtn = document.createElement('button');
            prevBtn.innerText = '上一页';
            prevBtn.addEventListener('click', () => goToPage(currentPage - 1));
            paginationDiv.appendChild(prevBtn);
            
            // 页码按钮
            for (let i = 1; i <= pageCount; i++) {
                const pageBtn = document.createElement('button');
                pageBtn.innerText = i;
                pageBtn.addEventListener('click', () => goToPage(i));
                paginationDiv.appendChild(pageBtn);
            }
            
            const nextBtn = document.createElement('button');
            nextBtn.innerText = '下一页';
            nextBtn.addEventListener('click', () => goToPage(currentPage + 1));
            paginationDiv.appendChild(nextBtn);
            
            // 显示第一页
            let currentPage = 1;
            goToPage(currentPage);
            
            function goToPage(page) {
                if (page < 1 || page > pageCount) return;
                
                currentPage = page;
                const start = (page - 1) * itemsPerPage;
                const end = start + itemsPerPage;
                
                // 隐藏所有行
                rows.forEach(row => row.style.display = 'none');
                
                // 显示当前页的行
                for (let i = start; i < end && i < rows.length; i++) {
                    rows[i].style.display = '';
                }
                
                // 更新按钮状态
                updatePaginationButtons();
            }
            
            function updatePaginationButtons() {
                const buttons = paginationDiv.querySelectorAll('button');
                buttons.forEach((button, i) => {
                    if (i === 0) { // 前一页按钮
                        button.disabled = currentPage === 1;
                    } else if (i === buttons.length - 1) { // 下一页按钮
                        button.disabled = currentPage === pageCount;
                    } else { // 页码按钮
                        button.classList.toggle('active', i === currentPage);
                    }
                });
            }
        }
        
        // 搜索功能
        function searchSites(query) {
            if (!query) return;
            
            query = query.toLowerCase();
            const table = document.getElementById('site-url-table');
            const rows = table.querySelectorAll('tbody tr');
            
            let hasResults = false;
            
            rows.forEach(row => {
                const text = row.textContent.toLowerCase();
                if (text.includes(query)) {
                    row.style.display = '';
                    hasResults = true;
                } else {
                    row.style.display = 'none';
                }
            });
            
            // 隐藏分页控制
            const pagination = table.nextElementSibling;
            if (pagination && pagination.classList.contains('pagination-controls')) {
                pagination.style.display = query ? 'none' : 'flex';
            }
            
            // 显示搜索结果信息
            const resultInfo = document.getElementById('search-result-info');
            if (resultInfo) {
                resultInfo.textContent = hasResults 
                    ? "找到包含\"" + query + "\"的结果" 
                    : "未找到包含\"" + query + "\"的结果";
                resultInfo.style.display = 'block';
            }
        }
    </script>
</head>
<body>
    <div class="container">
        <header>
            <h1>WordPress数据库扫描报告</h1>
            <p>服务器：${hostname}</p>
        </header>
        <div class="report-meta">
            <span>生成时间：${timestamp}</span>
            <span>扫描站点数：${total_sites}</span>
        </div>
        <div class="content">
            <section>
                <h2>概览</h2>
                <div class="summary-cards">
                    <div class="card">
                        <h3>WordPress数据库总数</h3>
                        <p class="value">${total_sites}</p>
                    </div>
                    <div class="card">
                        <h3>总数据库大小</h3>
                        <p class="value">${total_size} MB</p>
                    </div>
                    <div class="card">
                        <h3>总文章数</h3>
                        <p class="value">${total_posts}</p>
                    </div>
                    <div class="card">
                        <h3>总用户数</h3>
                        <p class="value">${total_users}</p>
                    </div>
                </div>
                
                <div class="summary-cards">
                    <div class="card">
                        <h3>总评论数</h3>
                        <p class="value">${total_comments}</p>
                    </div>
                    <div class="card">
                        <h3>总表数量</h3>
                        <p class="value">${total_tables}</p>
                    </div>
                    <div class="card" style="border-top-color: var(--danger-color);">
                        <h3>可疑内容总数</h3>
                        <p class="value" style="color: var(--danger-color);">${total_suspicious}</p>
                    </div>
                    <div class="card">
                        <h3>扫描站点总数</h3>
                        <p class="value">${total_sites}</p>
                    </div>
                </div>
            </section>
            
            <section id="sites-section">
                <h2>站点信息</h2>
                <div class="search-box">
                    <input type="text" id="search-input" placeholder="搜索站点...">
                    <button id="search-button">搜索</button>
                </div>
                <p id="search-result-info" style="display: none; margin: 1rem 0; font-style: italic;"></p>
                <table id="site-url-table">
                    <thead>
                        <tr>
                            <th>站点路径</th>
                            <th>站点URL</th>
                            <th>数据库名</th>
                            <th>大小(MB)</th>
                            <th>表数量</th>
                            <th>文章数</th>
                            <th>用户数</th>
                            <th>评论数</th>
                            <th>WP版本</th>
                            <th>可疑项</th>
                        </tr>
                    </thead>
                    <tbody>
EOL

    # 站点行
    for site_info in "${all_sites[@]}"; do
        IFS='|' read -r site_dir site_url db_name db_size table_count post_count user_count comment_count wp_version suspicious_count <<< "$site_info"
        
        local suspicious_class="suspicious-low"
        if [ "$suspicious_count" -gt 10 ]; then
            suspicious_class="suspicious-high"
        elif [ "$suspicious_count" -gt 0 ]; then
            suspicious_class="suspicious-medium"
        fi
        
        local site_basename=$(basename "$site_dir")
        local report_link="./${site_basename}/report.html"
        
        cat >> "${output_dir}/index.html" << EOL
            <tr>
                <td>${site_dir}</td>
                <td><a href="${site_url}" target="_blank" class="site-link">${site_url}</a></td>
                <td>${db_name}</td>
                <td>${db_size}</td>
                <td>${table_count}</td>
                <td>${post_count}</td>
                <td>${user_count}</td>
                <td>${comment_count}</td>
                <td>${wp_version}</td>
                <td class="${suspicious_class}"><a href="${report_link}" class="site-link">${suspicious_count}</a></td>
            </tr>
EOL
    done

    # 如果没有站点数据，添加一行提示信息
    if [ ${#all_sites[@]} -eq 0 ]; then
        cat >> "${output_dir}/index.html" << EOL
            <tr>
                <td colspan="10" style="text-align: center;">未找到WordPress站点或无法访问其数据库</td>
            </tr>
EOL
    fi

    # 完成表格
    cat >> "${output_dir}/index.html" << EOL
                    </tbody>
                </table>
            </section>
    
            <section>
                <h2>可疑内容统计</h2>
                <div class="summary-cards">
                    <div class="card" style="border-top-color: var(--danger-color);">
                        <h3>可疑文章</h3>
                        <p class="value" style="color: var(--danger-color);">${total_suspicious_posts}</p>
                    </div>
                    <div class="card" style="border-top-color: var(--warning-color);">
                        <h3>可疑用户</h3>
                        <p class="value" style="color: var(--warning-color);">${total_suspicious_users}</p>
                    </div>
                    <div class="card" style="border-top-color: var(--danger-color);">
                        <h3>可疑选项</h3>
                        <p class="value" style="color: var(--danger-color);">${total_suspicious_options}</p>
                    </div>
                    <div class="card" style="border-top-color: var(--warning-color);">
                        <h3>可疑评论</h3>
                        <p class="value" style="color: var(--warning-color);">${total_suspicious_comments}</p>
                    </div>
                    <div class="card" style="border-top-color: var(--danger-color);">
                        <h3>可疑元数据</h3>
                        <p class="value" style="color: var(--danger-color);">${total_suspicious_postmeta}</p>
                    </div>
                    <div class="card" style="border-top-color: var(--warning-color);">
                        <h3>可疑日期</h3>
                        <p class="value" style="color: var(--warning-color);">${total_suspicious_dates}</p>
                    </div>
                </div>
            </section>
    
            <footer>
                <p>WordPress数据库扫描工具 - 生成于 ${timestamp}</p>
            </footer>
        </div>
    </body>
    </html>
EOL

    log "总报告生成完成: ${output_dir}/index.html"
}

# 处理报告输出
process_report_output() {
    log "处理报告输出..."
    
    # 判断站点路径决定输出位置
    if [[ "${FOUND_SITES[0]}" == /var/www/* ]]; then
        # 如果站点在/var/www/下，输出到/var/www/html/
        local output_dir="/var/www/html/wp_scan_report_$(date +%Y%m%d)"
        mkdir -p "$output_dir"
        cp -r "${REPORT_DIR}"/* "$output_dir/"
        chmod -R 755 "$output_dir"
        log "报告已输出到: $output_dir"
        echo -e "${GREEN}报告已生成，请访问: http://服务器IP/wp_scan_report_$(date +%Y%m%d)/${NC}"
    else
        # 其他情况打包成tar放在用户目录下
        local user_home=$(eval echo ~$(whoami))
        local output_file="${user_home}/wp_scan_report_$(date +%Y%m%d).tar.gz"
        tar -czf "$output_file" -C "${REPORT_DIR}" .
        log "报告已打包到: $output_file"
        echo -e "${GREEN}报告已打包到: $output_file${NC}"
    fi
}

# 清理临时文件
cleanup() {
    log "清理临时文件..."
    rm -rf "${TEMP_DIR}"
    log "扫描完成！"
}

# 主函数
main() {
    show_banner
    
    # 检查必要的命令
    for cmd in mysql find grep sed awk tar; do
        if ! command -v $cmd &> /dev/null; then
            log "错误: 找不到命令 $cmd，请先安装"
            exit 1
        fi
    done
    
    # 准备报告模板
    prepare_templates
    
    # 查找WordPress站点
    find_wordpress_sites
    
    # 调试信息
    log "找到的站点数量: ${#FOUND_SITES[@]}"
    for site in "${FOUND_SITES[@]}"; do
        log "站点: $site"
    done
    
    if [ ${#FOUND_SITES[@]} -eq 0 ]; then
        log "未找到任何WordPress站点！"
        exit 0
    fi
    
    # 扫描每个站点
    for site_dir in "${FOUND_SITES[@]}"; do
        wp_config="${site_dir}/wp-config.php"
        
        if [ -f "$wp_config" ]; then
            db_info=$(extract_db_info "$wp_config")
            scan_suspicious_content "$site_dir" "$db_info" "$REPORT_DIR"
        else
            log "警告: $site_dir 中找不到wp-config.php文件"
        fi
    done
    
    # 创建总报告
    create_master_report "$REPORT_DIR" "$CURRENT_DATE" "$TOTAL_SITES"
    
    # 处理报告输出
    process_report_output
    
    # 清理临时文件
    cleanup
    
    echo -e "${GREEN}扫描完成！共扫描 ${TOTAL_SITES} 个站点，发现 ${TOTAL_SUSPICIOUS} 个可疑项${NC}"
}

# 执行主函数
main "$@" 
