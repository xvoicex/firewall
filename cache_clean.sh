#!/bin/bash

# WordPress 智能缓存清理脚本 (自动执行版)
# 作者: AI助手
# 创建时间: 2024-07-18
# 更新时间: $(date '+%Y-%m-%d %H:%M:%S')
# 功能: 自动检测WordPress站点和缓存插件，执行智能缓存清理 (无用户交互)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 日志文件路径
LOG_FILE="/var/log/wordpress_cache_cleaner_auto.log"
SCAN_DIR="/var/www"

# 初始化变量
declare -a WORDPRESS_SITES=()
declare -a SUCCESS_SITES=()
declare -a FAILED_SITES=()
declare -A SITE_CACHE_PLUGINS=()  # 关联数组：站点 -> 缓存插件列表
declare -A PLUGIN_STATS=()        # 关联数组：插件类型 -> 使用次数
TOTAL_SITES=0
SUCCESS_COUNT=0
FAILED_COUNT=0

# 支持的缓存插件配置
declare -A CACHE_PLUGINS=(
    ["wp-super-cache"]="WP Super Cache"
    ["litespeed-cache"]="LiteSpeed Cache"
    ["w3-total-cache"]="W3 Total Cache"
    ["wp-rocket"]="WP Rocket"
    ["wp-fastest-cache"]="WP Fastest Cache"
    ["autoptimize"]="Autoptimize"
    ["wp-optimize"]="WP-Optimize"
    ["hummingbird-performance"]="Hummingbird"
    ["cache-enabler"]="Cache Enabler"
    ["comet-cache"]="Comet Cache"
)

# 日志记录函数 (静默模式，只记录到文件)
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# 检测站点的缓存插件
detect_cache_plugins() {
    local site_path=$1
    local site_name=$(basename "$site_path")
    local plugins_dir="$site_path/wp-content/plugins"
    local detected_plugins=()
    
    log_message "INFO" "检测站点 $site_name 的缓存插件..."
    
    # 检查插件目录是否存在
    if [[ ! -d "$plugins_dir" ]]; then
        log_message "WARNING" "站点 $site_name 的插件目录不存在: $plugins_dir"
        return 1
    fi
    
    # 检测已安装的缓存插件
    for plugin_slug in "${!CACHE_PLUGINS[@]}"; do
        local plugin_path="$plugins_dir/$plugin_slug"
        if [[ -d "$plugin_path" ]]; then
            # 进一步检查插件是否激活
            cd "$site_path" || continue
            if wp plugin is-active "$plugin_slug" --allow-root 2>/dev/null; then
                detected_plugins+=("${CACHE_PLUGINS[$plugin_slug]}")
                log_message "SUCCESS" "发现激活的缓存插件: ${CACHE_PLUGINS[$plugin_slug]} ($plugin_slug)"
                
                # 统计插件使用次数
                if [[ -n "${PLUGIN_STATS[$plugin_slug]}" ]]; then
                    ((PLUGIN_STATS[$plugin_slug]++))
                else
                    PLUGIN_STATS[$plugin_slug]=1
                fi
            else
                log_message "INFO" "发现未激活的缓存插件: ${CACHE_PLUGINS[$plugin_slug]} ($plugin_slug)"
            fi
        fi
    done
    
    # 保存检测结果
    if [[ ${#detected_plugins[@]} -gt 0 ]]; then
        SITE_CACHE_PLUGINS["$site_path"]=$(IFS=","; echo "${detected_plugins[*]}")
        log_message "SUCCESS" "站点 $site_name 检测到 ${#detected_plugins[@]} 个激活的缓存插件"
    else
        SITE_CACHE_PLUGINS["$site_path"]="无缓存插件"
        log_message "INFO" "站点 $site_name 未检测到激活的缓存插件"
    fi
    
    return 0
}

# 获取插件特定的清理命令
get_cache_clear_commands() {
    local site_path=$1
    local plugins_string="${SITE_CACHE_PLUGINS[$site_path]}"
    local commands=()
    
    if [[ "$plugins_string" == "无缓存插件" ]]; then
        # 通用WordPress缓存清理
        commands+=(
            "wp cache flush --allow-root"
            "wp transient delete --all --allow-root"
            "wp rewrite flush --allow-root"
        )
    else
        # 根据检测到的插件添加特定命令
        IFS=',' read -ra PLUGINS <<< "$plugins_string"
        for plugin in "${PLUGINS[@]}"; do
            case "$plugin" in
                "WP Super Cache")
                    commands+=("wp super-cache flush --allow-root")
                    ;;
                "LiteSpeed Cache")
                    commands+=("wp litespeed-purge all --allow-root")
                    ;;
                "W3 Total Cache")
                    commands+=("wp w3-total-cache flush all --allow-root")
                    ;;
                "WP Rocket")
                    commands+=("wp rocket clean --confirm --allow-root")
                    ;;
                "WP Fastest Cache")
                    commands+=("wp fastest-cache clear all --allow-root")
                    ;;
                "Autoptimize")
                    commands+=("wp autoptimize clear --allow-root")
                    ;;
                "WP-Optimize")
                    commands+=("wp wp-optimize cache --allow-root")
                    ;;
                "Hummingbird")
                    commands+=("wp hummingbird cache clear --allow-root")
                    ;;
                "Cache Enabler")
                    commands+=("wp cache-enabler clear --allow-root")
                    ;;
                "Comet Cache")
                    commands+=("wp comet-cache clear --allow-root")
                    ;;
            esac
        done
        
        # 添加通用WordPress缓存清理作为备用
        commands+=(
            "wp cache flush --allow-root"
            "wp transient delete --all --allow-root"
            "wp rewrite flush --allow-root"
        )
    fi
    
    printf '%s\n' "${commands[@]}"
}

# 检查脚本运行权限
check_permissions() {
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR" "此脚本需要root权限运行，请使用 sudo 执行"
        exit 1
    fi
    
    if [[ ! -d "$SCAN_DIR" ]]; then
        log_message "ERROR" "扫描目录 $SCAN_DIR 不存在"
        exit 1
    fi
    
    if ! command -v wp &> /dev/null; then
        log_message "ERROR" "WP-CLI 未安装或不在PATH中，请先安装 WP-CLI"
        exit 1
    fi
}

# 检测WordPress站点
detect_wordpress_sites() {
    log_message "INFO" "开始扫描 $SCAN_DIR 目录下的WordPress站点..."
    
    for dir in "$SCAN_DIR"/*; do
        if [[ -d "$dir" ]]; then
            local site_name=$(basename "$dir")
            local wp_config="$dir/wp-config.php"
            
            if [[ -f "$wp_config" ]]; then
                # 验证是否为有效的WordPress配置文件
                if grep -q "DB_NAME\|DB_USER\|DB_PASSWORD" "$wp_config" 2>/dev/null; then
                    WORDPRESS_SITES+=("$dir")
                    log_message "SUCCESS" "发现WordPress站点: $site_name ($dir)"
                    ((TOTAL_SITES++))
                    
                    # 检测缓存插件
                    detect_cache_plugins "$dir"
                else
                    log_message "WARNING" "目录 $site_name 包含 wp-config.php 但可能不是有效的WordPress站点"
                fi
            else
                log_message "INFO" "目录 $site_name 不包含 wp-config.php，跳过"
            fi
        fi
    done
    
    if [[ $TOTAL_SITES -eq 0 ]]; then
        log_message "WARNING" "未发现任何WordPress站点"
        exit 0
    fi
    
    log_message "INFO" "总共发现 $TOTAL_SITES 个WordPress站点"
    
    # 记录缓存插件统计
    if [[ ${#PLUGIN_STATS[@]} -gt 0 ]]; then
        log_message "INFO" "缓存插件使用统计:"
        for plugin in "${!PLUGIN_STATS[@]}"; do
            log_message "INFO" "  ${CACHE_PLUGINS[$plugin]}: ${PLUGIN_STATS[$plugin]} 个站点"
        done
    fi
}

# 清理单个站点缓存
clean_site_cache() {
    local site_path=$1
    local site_name=$(basename "$site_path")
    local plugins_info="${SITE_CACHE_PLUGINS[$site_path]}"
    
    log_message "INFO" "开始清理站点 $site_name 的缓存..."
    log_message "INFO" "检测到的缓存插件: $plugins_info"
    
    # 检查目录权限
    if [[ ! -r "$site_path" ]]; then
        log_message "ERROR" "无法读取站点目录: $site_path"
        FAILED_SITES+=("$site_name (权限错误)")
        ((FAILED_COUNT++))
        return 1
    fi
    
    # 进入站点目录
    cd "$site_path" || {
        log_message "ERROR" "无法进入站点目录: $site_path"
        FAILED_SITES+=("$site_name (目录访问失败)")
        ((FAILED_COUNT++))
        return 1
    }
    
    # 获取针对该站点的清理命令
    local cache_commands
    readarray -t cache_commands < <(get_cache_clear_commands "$site_path")
    
    local command_success=true
    local successful_commands=0
    local total_commands=${#cache_commands[@]}
    
    log_message "INFO" "将执行 $total_commands 个清理命令"
    
    for cmd in "${cache_commands[@]}"; do
        log_message "INFO" "执行命令: $cmd (在目录: $site_path)"
        
        if timeout 30 $cmd >> "$LOG_FILE" 2>&1; then
            log_message "SUCCESS" "命令执行成功: $cmd"
            ((successful_commands++))
        else
            log_message "WARNING" "命令执行失败: $cmd"
            
            # 如果是插件特定命令失败，尝试通用命令
            if [[ "$cmd" != *"cache flush"* && "$cmd" != *"transient delete"* && "$cmd" != *"rewrite flush"* ]]; then
                log_message "INFO" "尝试通用缓存清理命令作为备用..."
                if timeout 30 wp cache flush --allow-root >> "$LOG_FILE" 2>&1; then
                    log_message "SUCCESS" "通用缓存清理成功"
                    ((successful_commands++))
                else
                    log_message "ERROR" "通用缓存清理也失败"
                fi
            fi
        fi
    done
    
    # 判断整体成功率
    local success_rate=$((successful_commands * 100 / total_commands))
    
    if [[ $success_rate -ge 50 ]]; then
        SUCCESS_SITES+=("$site_name ($plugins_info)")
        ((SUCCESS_COUNT++))
        log_message "SUCCESS" "站点 $site_name 缓存清理完成 (成功率: $success_rate%)"
    else
        FAILED_SITES+=("$site_name ($plugins_info)")
        ((FAILED_COUNT++))
        log_message "ERROR" "站点 $site_name 缓存清理失败 (成功率: $success_rate%)"
    fi
    
    return 0
}

# 主函数 (自动执行版)
main() {
    # 初始化日志文件
    echo "========== WordPress缓存清理日志 (自动执行) ==========" > "$LOG_FILE"
    log_message "INFO" "自动缓存清理脚本开始执行"
    
    # 检查权限和环境
    check_permissions
    
    # 检测WordPress站点
    detect_wordpress_sites
    
    # 自动开始清理缓存
    log_message "INFO" "开始自动清理所有站点的缓存..."
    
    # 逐个清理站点缓存
    for site_path in "${WORDPRESS_SITES[@]}"; do
        clean_site_cache "$site_path"
    done
    
    # 记录汇总到日志
    log_message "INFO" "自动缓存清理完成 - 总计:$TOTAL_SITES 成功:$SUCCESS_COUNT 失败:$FAILED_COUNT"
    
    # 记录插件统计到日志
    if [[ ${#PLUGIN_STATS[@]} -gt 0 ]]; then
        log_message "INFO" "缓存插件统计:"
        for plugin in "${!PLUGIN_STATS[@]}"; do
            log_message "INFO" "  ${CACHE_PLUGINS[$plugin]}: ${PLUGIN_STATS[$plugin]} 个站点"
        done
    fi
    
    log_message "INFO" "自动缓存清理脚本执行完成"
    
    # 输出简要结果到控制台
    echo "WordPress自动缓存清理完成"
    echo "总站点数: $TOTAL_SITES"
    echo "成功清理: $SUCCESS_COUNT"
    echo "清理失败: $FAILED_COUNT"
    echo "详细日志: $LOG_FILE"
}

# 脚本入口点
main "$@"
