#!/bin/bash

# Nginx FastCGI缓存一键管理脚本
# 作者: vince
# 版本: 2.0
# 用途: 一键开启/关闭nginx FastCGI缓存

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置变量
CACHE_DIR="/var/run/nginx-cache"
CACHE_ZONE_NAME="WORDPRESS"
DEFAULT_MEMORY="50m"
NGINX_CONF="/etc/nginx/nginx.conf"
PASS2PHP_CONF="/etc/nginx/rules/pass2php.conf"
MONITOR_SCRIPT="/etc/nginx/cache_monitor.sh"

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_header() { echo -e "${CYAN}$1${NC}"; }

# 显示横幅
show_banner() {
    echo ""
    log_header "=================================================="
    log_header "    Nginx FastCGI缓存一键管理脚本 v2.0"
    log_header "=================================================="
    echo ""
}

# 显示帮助
show_help() {
    show_banner
    echo "用法: $0 [命令] [选项]"
    echo ""
    echo "命令:"
    echo "  enable   启用FastCGI缓存 (默认)"
    echo "  disable  禁用FastCGI缓存"
    echo "  status   查看缓存状态"
    echo "  monitor  监控缓存使用情况"
    echo "  clean    清理缓存文件"
    echo ""
    echo "选项:"
    echo "  --memory SIZE    设置缓存内存大小 (默认: 50m)"
    echo "  --help          显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 enable                    # 启用缓存"
    echo "  $0 enable --memory 100m     # 启用缓存并设置100MB内存"
    echo "  $0 disable                  # 禁用缓存"
    echo "  $0 status                   # 查看状态"
    echo ""

}

# 检查权限
check_permissions() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        echo "请使用: sudo $0 或 curl -sSL url | sudo bash -s --"
        exit 1
    fi
}

# 检查nginx
check_nginx() {
    if ! command -v nginx &> /dev/null; then
        log_error "nginx未安装，请先安装nginx"
        exit 1
    fi
}

# 备份配置
backup_config() {
    local file="$1"
    if [ -f "$file" ]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "已备份: $file"
    fi
}

# 创建缓存目录
create_cache_dir() {
    if [ ! -d "$CACHE_DIR" ]; then
        mkdir -p "$CACHE_DIR"
        chown www-data:www-data "$CACHE_DIR" 2>/dev/null || chown nginx:nginx "$CACHE_DIR" 2>/dev/null || true
        chmod 700 "$CACHE_DIR"
        log_success "缓存目录创建完成: $CACHE_DIR"
    fi
}

# 启用FastCGI缓存
enable_fastcgi_cache() {
    local memory_size="${1:-$DEFAULT_MEMORY}"
    
    log_info "启用FastCGI缓存 (内存: $memory_size)"
    
    # 备份配置文件
    backup_config "$NGINX_CONF"
    backup_config "$PASS2PHP_CONF"
    
    # 创建缓存目录
    create_cache_dir
    
    # 配置nginx.conf
    if grep -q "fastcgi_cache_path.*$CACHE_ZONE_NAME" "$NGINX_CONF"; then
        # 更新现有配置
        sed -i "s|#.*fastcgi_cache_path.*$CACHE_ZONE_NAME.*|fastcgi_cache_path $CACHE_DIR levels=1:2 keys_zone=$CACHE_ZONE_NAME:$memory_size inactive=10m use_temp_path=off;|" "$NGINX_CONF"
        sed -i "s|fastcgi_cache_path.*$CACHE_ZONE_NAME.*|fastcgi_cache_path $CACHE_DIR levels=1:2 keys_zone=$CACHE_ZONE_NAME:$memory_size inactive=10m use_temp_path=off;|" "$NGINX_CONF"
    else
        # 添加新配置
        sed -i "/^http {/a\\    # FastCGI缓存配置\\n    fastcgi_cache_path $CACHE_DIR levels=1:2 keys_zone=$CACHE_ZONE_NAME:$memory_size inactive=10m use_temp_path=off;" "$NGINX_CONF"
    fi
    
    # 配置pass2php.conf
    mkdir -p "$(dirname "$PASS2PHP_CONF")"
    cat > "$PASS2PHP_CONF" << EOF
    include fastcgi.conf;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_intercept_errors on;

    # FastCGI缓存配置
    fastcgi_cache $CACHE_ZONE_NAME;
    fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";
    fastcgi_cache_valid 200 301 302 10m;
    fastcgi_cache_valid 404 1m;
    fastcgi_cache_min_uses 1;
    fastcgi_cache_use_stale error timeout invalid_header updating http_500 http_503;
    fastcgi_cache_bypass \$cookie_nocache \$arg_nocache \$arg_comment;
    fastcgi_no_cache \$cookie_nocache \$arg_nocache \$arg_comment;
    add_header X-FastCGI-Cache \$upstream_cache_status;

    # 超时配置
    fastcgi_connect_timeout 600;
    fastcgi_send_timeout 600;
    fastcgi_read_timeout 600;

    # 缓冲区配置
    fastcgi_buffer_size 128k;
    fastcgi_buffers 32 32k;
    fastcgi_busy_buffers_size 128k;
    fastcgi_temp_file_write_size 256k;

    fastcgi_pass php;
EOF
    
    # 创建监控脚本
    create_monitor_script
    
    # 测试并重载nginx
    if nginx -t; then
        systemctl reload nginx
        log_success "FastCGI缓存已启用"
        log_info "缓存目录: $CACHE_DIR"
        log_info "内存区域: $CACHE_ZONE_NAME:$memory_size"
        log_info "监控脚本: $MONITOR_SCRIPT"
    else
        log_error "nginx配置测试失败"
        exit 1
    fi
}

# 禁用FastCGI缓存
disable_fastcgi_cache() {
    log_info "禁用FastCGI缓存"
    
    # 备份配置文件
    backup_config "$NGINX_CONF"
    backup_config "$PASS2PHP_CONF"
    
    # 注释nginx.conf中的缓存配置
    sed -i "s|^[[:space:]]*fastcgi_cache_path.*$CACHE_ZONE_NAME.*|    # fastcgi_cache_path $CACHE_DIR levels=1:2 keys_zone=$CACHE_ZONE_NAME:$DEFAULT_MEMORY inactive=10m use_temp_path=off; # DISABLED|" "$NGINX_CONF"
    
    # 注释pass2php.conf中的缓存配置
    if [ -f "$PASS2PHP_CONF" ]; then
        sed -i 's|^[[:space:]]*fastcgi_cache |    # fastcgi_cache |' "$PASS2PHP_CONF"
        sed -i 's|^[[:space:]]*fastcgi_cache_|    # fastcgi_cache_|' "$PASS2PHP_CONF"
        sed -i 's|^[[:space:]]*fastcgi_no_cache|    # fastcgi_no_cache|' "$PASS2PHP_CONF"
        sed -i 's|^[[:space:]]*add_header X-FastCGI-Cache|    # add_header X-FastCGI-Cache|' "$PASS2PHP_CONF"
    fi
    
    # 测试并重载nginx
    if nginx -t; then
        systemctl reload nginx
        log_success "FastCGI缓存已禁用"
        log_info "缓存文件保留在: $CACHE_DIR"
        log_info "如需完全清理，请运行: $0 clean"
    else
        log_error "nginx配置测试失败"
        exit 1
    fi
}

# 查看缓存状态
show_status() {
    log_header "FastCGI缓存状态检查"
    echo ""
    
    # 检查nginx.conf配置
    if grep -q "^[[:space:]]*fastcgi_cache_path.*$CACHE_ZONE_NAME" "$NGINX_CONF"; then
        log_success "✅ nginx.conf: FastCGI缓存已启用"
        grep "fastcgi_cache_path.*$CACHE_ZONE_NAME" "$NGINX_CONF" | sed 's/^/   /'
    else
        log_warning "❌ nginx.conf: FastCGI缓存未启用或已禁用"
    fi
    
    # 检查pass2php.conf配置
    if [ -f "$PASS2PHP_CONF" ] && grep -q "^[[:space:]]*fastcgi_cache $CACHE_ZONE_NAME" "$PASS2PHP_CONF"; then
        log_success "✅ pass2php.conf: 缓存规则已配置"
    else
        log_warning "❌ pass2php.conf: 缓存规则未配置或已禁用"
    fi
    
    # 检查缓存目录
    if [ -d "$CACHE_DIR" ]; then
        cache_files=$(find "$CACHE_DIR" -type f 2>/dev/null | wc -l)
        cache_size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
        log_success "✅ 缓存目录: $CACHE_DIR"
        echo "   文件数量: $cache_files"
        echo "   目录大小: $cache_size"
    else
        log_warning "❌ 缓存目录不存在: $CACHE_DIR"
    fi
    
    # 检查nginx进程
    if pgrep nginx > /dev/null; then
        log_success "✅ nginx进程运行中"
    else
        log_error "❌ nginx进程未运行"
    fi
    
    echo ""
}

# 清理缓存
clean_cache() {
    log_info "清理FastCGI缓存文件"
    
    if [ -d "$CACHE_DIR" ]; then
        find "$CACHE_DIR" -type f -delete 2>/dev/null || true
        log_success "缓存文件清理完成"
    else
        log_warning "缓存目录不存在"
    fi
}

# 创建监控脚本
create_monitor_script() {
    cat > "$MONITOR_SCRIPT" << 'EOF'
#!/bin/bash
echo "=== FastCGI缓存监控 ==="
echo "时间: $(date)"
echo ""

if [ -d "/var/run/nginx-cache" ]; then
    cache_files=$(find /var/run/nginx-cache -type f 2>/dev/null | wc -l)
    cache_size=$(du -sh /var/run/nginx-cache 2>/dev/null | cut -f1)
    echo "📊 缓存统计:"
    echo "   文件数量: $cache_files"
    echo "   总大小: $cache_size"
    
    if [ $cache_files -lt 1000 ]; then
        echo "   💡 建议: 当前缓存量较少，10-50MB内存足够"
    elif [ $cache_files -lt 10000 ]; then
        echo "   💡 建议: 缓存量中等，建议50-100MB内存"
    else
        echo "   💡 建议: 缓存量较大，建议100MB+内存"
    fi
else
    echo "❌ 缓存目录不存在"
fi

echo ""
echo "💾 内存使用:"
free -h | grep -E "Mem|Swap"
echo ""
EOF
    chmod +x "$MONITOR_SCRIPT"
}

# 运行监控
run_monitor() {
    if [ -f "$MONITOR_SCRIPT" ]; then
        "$MONITOR_SCRIPT"
    else
        create_monitor_script
        "$MONITOR_SCRIPT"
    fi
}


# 主函数
main() {
    local action="${1:-enable}"
    local memory_size="$DEFAULT_MEMORY"
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            enable|disable|status|monitor|clean)
                action="$1"
                shift
                ;;
            --memory)
                memory_size="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
    
    show_banner
    
    # 执行对应操作
    case $action in
        enable)
            check_permissions
            check_nginx
            enable_fastcgi_cache "$memory_size"
            echo ""
            show_status
            ;;
        disable)
            check_permissions
            check_nginx
            disable_fastcgi_cache
            echo ""
            show_status
            ;;
        status)
            show_status
            ;;
        monitor)
            run_monitor
            ;;
        clean)
            check_permissions
            clean_cache
            ;;
        *)
            log_error "未知命令: $action"
            show_help
            exit 1
            ;;
    esac
    
    echo ""
    log_header "操作完成！"
    echo ""
}

# 运行主函数
main "$@"
