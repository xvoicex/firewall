#!/bin/bash

for site in /var/www/*/; do
    if [ -d "$site" ]; then
        site_name=$(basename "$site")
        echo "正在清理站点: $site_name"

        # 清理SuperCache的.tmp文件
        supercache_dir="${site}wp-content/cache/supercache"
        if [ -d "$supercache_dir" ]; then
            echo "清理 SuperCache 临时文件..."
            # 查找并删除所有.tmp文件
            find "$supercache_dir" -type f -name "*.tmp" -delete
            # 删除空目录
            find "$supercache_dir" -type d -empty -delete
            
            # 显示清理后的目录大小
            du -sh "$supercache_dir"
        fi

        # 清理LiteSpeed缓存
        litespeed_cache="${site}wp-content/litespeed"
        if [ -d "$litespeed_cache" ]; then
            echo "清理 LiteSpeed 缓存..."
            
            # 清理各类缓存目录
            cache_dirs=(
                "css"
                "js"
                "ccss"
                "ucss"
                "vpi"
            )
            
            for dir in "${cache_dirs[@]}"; do
                if [ -d "${litespeed_cache}/${dir}" ]; then
                    rm -rf "${litespeed_cache}/${dir}"/*
                fi
            done
            
            # 显示清理后的目录大小
            du -sh "$litespeed_cache"
        fi

        echo "完成清理: $site_name"
        echo "----------------------------------------"
    fi
done

echo "所有缓存清理完成"

# 修复权限
for site in /var/www/*/; do
    if [ -d "$site" ]; then
        chown -R www-data:www-data "${site}wp-content"
        find "${site}wp-content" -type d -not -path "${site}wp-content/uploads/*" -exec chmod 755 {} \;
        find "${site}wp-content" -type f -not -path "${site}wp-content/uploads/*" -exec chmod 644 {} \;
    fi
done
