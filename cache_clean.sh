#!/bin/bash

echo "=== WordPress缓存清理脚本 ==="
echo "时间: $(date)"
echo ""

# 检查WP-CLI是否可用
if ! command -v wp &> /dev/null; then
    echo "❌ WP-CLI未安装，无法执行缓存清理"
    exit 1
fi

# 进入WordPress目录（根据实际情况修改）
cd /var/www/html || exit 1

echo "🧹 开始清理各种缓存..."
echo ""

# 1. 清除WordPress核心缓存
echo "📝 清除WordPress核心缓存..."
wp cache flush 2>/dev/null && echo "✅ WordPress核心缓存已清除" || echo "⚠️ WordPress核心缓存清除失败或不存在"

# 2. 清除WP Super Cache
echo "🚀 清除WP Super Cache..."
wp super-cache flush 2>/dev/null && echo "✅ WP Super Cache已清除" || echo "⚠️ WP Super Cache清除失败或插件未安装"

# 3. 清除LiteSpeed Cache
echo "⚡ 清除LiteSpeed Cache..."
wp litespeed-purge all 2>/dev/null && echo "✅ LiteSpeed Cache已清除" || echo "⚠️ LiteSpeed Cache清除失败或插件未安装"

# 4. 清除W3 Total Cache
echo "🔧 清除W3 Total Cache..."
wp w3-total-cache flush 2>/dev/null && echo "✅ W3 Total Cache已清除" || echo "⚠️ W3 Total Cache清除失败或插件未安装"

# 5. 清除WP Rocket
echo "🚀 清除WP Rocket..."
wp rocket clean --confirm 2>/dev/null && echo "✅ WP Rocket缓存已清除" || echo "⚠️ WP Rocket清除失败或插件未安装"

# 6. 清除对象缓存
echo "💾 清除对象缓存..."
wp object-cache flush 2>/dev/null && echo "✅ 对象缓存已清除" || echo "⚠️ 对象缓存清除失败或未启用"

# 7. 清除Nginx FastCGI缓存（如果启用）
echo "🌐 清除Nginx FastCGI缓存..."
if [ -d "/var/run/nginx-cache" ]; then
    find /var/run/nginx-cache -type f -delete 2>/dev/null
    echo "✅ Nginx FastCGI缓存已清除"
else
    echo "⚠️ Nginx FastCGI缓存目录不存在"
fi

# 8. 清除OPcache
echo "⚡ 清除OPcache..."
if command -v php &> /dev/null; then
    php -r "if(function_exists('opcache_reset')) { opcache_reset(); echo 'OPcache已清除'; } else { echo 'OPcache未启用'; }" 2>/dev/null
else
    echo "⚠️ PHP命令不可用"
fi

echo ""
echo "🎉 缓存清理完成！"
echo ""

# 显示当前缓存状态
echo "📊 当前缓存状态检查："
wp plugin list --status=active --field=name | grep -i cache | while read plugin; do
    echo "   ✅ 已激活缓存插件: $plugin"
done

echo ""
echo "💡 建议：清理缓存后，请访问网站首页确认页面正常加载"
