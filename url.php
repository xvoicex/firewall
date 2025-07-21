<?php
/**
 * 统一的交互式WordPress URL替换脚本
 * 整合现有的换链功能，提供完整的站点发现、URL猜测和替换功能
 * 
 * 功能特性：
 * - 站点发现：自动扫描WordPress站点
 * - 智能URL猜测：基于现有逻辑的精准猜测
 * - 增强功能：确认步骤、备份、日志、回滚、进度显示
 * 
 * 使用方法:
 * php interactive_url_replacer.php
 * 
 * @author vince
 * @version 1.0
 * @date 2025-07-17
 */

// 设置错误报告和环境
error_reporting(E_ALL);
ini_set('display_errors', 1);
ini_set('memory_limit', '512M');
set_time_limit(0);

// 统一的交互式URL替换脚本 - 完全独立，不依赖其他文件

class InteractiveURLReplacer {

    private $base_dirs = array();
    private $discovered_sites = array();
    private $current_site = null;
    private $replacer = null;
    private $backup_dir = './backups';
    private $log_file = './interactive_replacer.log';
    private $operation_history = array();
    private $old_url = null;
    private $new_url = null;
    private $backup_file = null;
    private $db_config = array();
    private $stats = array(
        'step1' => array(
            'db_total' => 0,
            'db_replaced' => 0,
            'files_processed' => 0,
            'files_replaced' => 0
        ),
        'step2' => array(
            'db_total' => 0,
            'db_replaced' => 0,
            'files_processed' => 0,
            'files_replaced' => 0
        ),
        'start_time' => 0
    );
    
    public function __construct() {
        // 创建必要的目录
        $this->createDirectories();
        $this->stats['start_time'] = microtime(true);
        $this->log("=== 统一的交互式WordPress URL替换脚本 ===");
        $this->log("启动时间: " . date('Y-m-d H:i:s'));
    }
    
    /**
     * 创建必要的目录
     */
    private function createDirectories() {
        if (!is_dir($this->backup_dir)) {
            mkdir($this->backup_dir, 0755, true);
        }
    }
    
    /**
     * 彩色输出
     */
    private function colorOutput($text, $color = 'white') {
        $colors = array(
            'red' => "\033[0;31m",
            'green' => "\033[0;32m",
            'yellow' => "\033[1;33m",
            'blue' => "\033[0;34m",
            'cyan' => "\033[0;36m",
            'white' => "\033[0m",
            'bold' => "\033[1m"
        );
        
        $color_code = isset($colors[$color]) ? $colors[$color] : $colors['white'];
        echo $color_code . $text . $colors['white'];
    }
    
    /**
     * 日志记录
     */
    private function log($message) {
        $log_entry = date('Y-m-d H:i:s') . " - " . $message . "\n";
        echo $log_entry;
        file_put_contents($this->log_file, $log_entry, FILE_APPEND | LOCK_EX);
    }

    /**
     * 改进的用户输入函数，支持readline
     */
    private function getUserInput($prompt, $default = '') {
        if (function_exists('readline')) {
            // 使用readline提供更好的输入体验
            $input = readline($prompt);
            if ($input !== false) {
                // 添加到历史记录
                readline_add_history($input);
                return trim($input);
            }
        }

        // 回退到基础输入方式
        echo $prompt;
        $input = trim(fgets(STDIN));
        return $input;
    }

    /**
     * 将技术性的来源名称转换为用户友好的描述
     */
    private function getSourceDescription($source) {
        $descriptions = array(
            'database_siteurl' => '数据库站点URL配置',
            'database_home' => '数据库首页URL配置',
            'server_ip' => '服务器IP地址',
            'development' => '本地开发环境',
            'test_subdomain' => '测试子域名',
            'environment' => '当前环境推断',
            'historical' => '历史URL记录',
            'unknown' => '未知来源'
        );

        return isset($descriptions[$source]) ? $descriptions[$source] : $source;
    }

    /**
     * 从URL中提取域名部分（包含主机名和路径）
     */
    private function extractDomain($url) {
        $parsed = parse_url($url);
        if (isset($parsed['host'])) {
            $domain = $parsed['host'];

            // 添加端口（如果存在）
            if (isset($parsed['port'])) {
                $domain .= ':' . $parsed['port'];
            }

            // 添加路径（如果存在且不是根路径）
            if (isset($parsed['path']) && $parsed['path'] !== '/' && !empty(trim($parsed['path'], '/'))) {
                $domain .= $parsed['path'];
            }

            return $domain;
        }
        return null;
    }

    /**
     * 解析WordPress配置文件
     */
    public function parseWpConfig() {
        $wp_config_path = $this->current_site['path'] . '/wp-config.php';

        if (!file_exists($wp_config_path)) {
            $this->log("错误: wp-config.php文件不存在");
            return false;
        }

        $content = file_get_contents($wp_config_path);
        if ($content === false) {
            $this->log("错误: 无法读取wp-config.php文件");
            return false;
        }

        // 提取数据库配置
        $patterns = array(
            'DB_NAME' => "/define\s*\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]([^'\"]*)['\"].*\)/i",
            'DB_USER' => "/define\s*\(\s*['\"]DB_USER['\"]\s*,\s*['\"]([^'\"]*)['\"].*\)/i",
            'DB_PASSWORD' => "/define\s*\(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"]([^'\"]*)['\"].*\)/i",
            'DB_HOST' => "/define\s*\(\s*['\"]DB_HOST['\"]\s*,\s*['\"]([^'\"]*)['\"].*\)/i",
            'DB_CHARSET' => "/define\s*\(\s*['\"]DB_CHARSET['\"]\s*,\s*['\"]([^'\"]*)['\"].*\)/i"
        );

        foreach ($patterns as $key => $pattern) {
            if (preg_match($pattern, $content, $matches)) {
                $this->db_config[$key] = $matches[1];
            } else {
                // 设置默认值
                if ($key == 'DB_HOST') {
                    $this->db_config[$key] = 'localhost';
                } elseif ($key == 'DB_CHARSET') {
                    $this->db_config[$key] = 'utf8mb4';
                } else {
                    $this->log("错误: 无法找到数据库配置: " . $key);
                    return false;
                }
            }
        }

        // 提取表前缀
        if (preg_match("/\\\$table_prefix\s*=\s*['\"]([^'\"]*)['\"]/" , $content, $matches)) {
            $this->db_config['table_prefix'] = $matches[1];
        } else {
            $this->db_config['table_prefix'] = 'wp_';
        }

        $this->log("成功解析wp-config.php配置");
        return true;
    }

    /**
     * 获取数据库配置
     */
    public function getDbConfig() {
        return $this->db_config;
    }

    /**
     * 智能猜测可能的旧URL - 重新设计，更精准的判定逻辑
     */
    public function guessOldUrls() {
        $urls = array();

        // 1. 从数据库获取WordPress配置的URL（原项目核心逻辑）
        $db_urls = $this->getUrlsFromDatabase();
        $urls = array_merge($urls, $db_urls);

        // 2. 获取服务器IP并构建URL（原项目逻辑）
        $ip_urls = $this->getServerIpUrls();
        $urls = array_merge($urls, $ip_urls);

        // 3. 基于当前环境推断可能的旧URL（新增智能逻辑）
        $env_urls = $this->guessUrlsFromCurrentEnvironment();
        $urls = array_merge($urls, $env_urls);

        // 4. 基于站点目录结构推断开发环境URL（新增）
        $dev_urls = $this->guessRelevantDevelopmentUrls();
        $urls = array_merge($urls, $dev_urls);

        // 过滤和排序 - 按相关性排序
        $urls = $this->filterAndRankUrls($urls);

        $this->log("猜测到 " . count($urls) . " 个可能的旧URL");
        return $urls;
    }

    /**
     * 从数据库获取URL（原项目逻辑 + 改进）
     */
    private function getUrlsFromDatabase() {
        $urls = array();

        try {
            $mysqli = new mysqli(
                $this->db_config['DB_HOST'],
                $this->db_config['DB_USER'],
                $this->db_config['DB_PASSWORD'],
                $this->db_config['DB_NAME']
            );

            if (!$mysqli->connect_error) {
                $mysqli->set_charset($this->db_config['DB_CHARSET']);
                $table_prefix = $this->db_config['table_prefix'];

                // 1. 获取siteurl和home选项（原项目逻辑）
                $query = "SELECT option_name, option_value FROM {$table_prefix}options WHERE option_name IN ('siteurl', 'home')";
                $result = $mysqli->query($query);

                if ($result) {
                    while ($row = $result->fetch_assoc()) {
                        if (!empty($row['option_value']) && strpos($row['option_value'], 'http') === 0) {
                            $url = rtrim($row['option_value'], '/');
                            $urls[] = array('url' => $url, 'source' => 'database_' . $row['option_name'], 'priority' => 10);
                        }
                    }
                }

                $mysqli->close();
            }
        } catch (Exception $e) {
            $this->log("警告: 从数据库获取URL失败: " . $e->getMessage());
        }

        return $urls;
    }

    /**
     * 获取服务器IP URL（原项目逻辑改进）
     */
    private function getServerIpUrls() {
        $urls = array();

        // 原项目的逻辑：通过外部服务获取IP
        $external_services = array(
            'https://ip.me/ip',
            'https://ipinfo.io/ip'
        );

        foreach ($external_services as $service) {
            try {
                $context = stream_context_create(array(
                    'http' => array(
                        'timeout' => 3,
                        'user_agent' => 'WordPress URL Replacer'
                    )
                ));

                $server_ip = @file_get_contents($service, false, $context);
                if ($server_ip && filter_var(trim($server_ip), FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
                    $server_ip = trim($server_ip);
                    $urls[] = array('url' => "http://{$server_ip}", 'source' => 'server_ip', 'priority' => 8);
                    $urls[] = array('url' => "https://{$server_ip}", 'source' => 'server_ip', 'priority' => 7);
                    break;
                }
            } catch (Exception $e) {
                continue;
            }
        }

        return $urls;
    }

    /**
     * 基于当前环境推断可能的旧URL
     */
    private function guessUrlsFromCurrentEnvironment() {
        $urls = array();
        $site_name = basename($this->current_site['path']);

        // 如果当前通过某个域名访问，推断可能的旧域名
        if (isset($_SERVER['HTTP_HOST'])) {
            $current_host = $_SERVER['HTTP_HOST'];

            // 如果当前是生产域名，推断可能的测试域名
            if (!in_array($current_host, array('localhost', '127.0.0.1'))) {
                $domain_parts = explode('.', $current_host);
                if (count($domain_parts) >= 2) {
                    $base_domain = $domain_parts[count($domain_parts) - 2] . '.' . $domain_parts[count($domain_parts) - 1];

                    // 常见的测试子域名
                    $test_subdomains = array('test', 'staging', 'dev', 'preview');
                    foreach ($test_subdomains as $subdomain) {
                        $urls[] = array('url' => "https://{$subdomain}.{$base_domain}", 'source' => 'test_subdomain', 'priority' => 6);
                        $urls[] = array('url' => "http://{$subdomain}.{$base_domain}", 'source' => 'test_subdomain', 'priority' => 5);
                    }
                }
            }
        }

        return $urls;
    }

    /**
     * 猜测相关的开发环境URL（只包含最可能的）
     */
    private function guessRelevantDevelopmentUrls() {
        $urls = array();
        $site_name = basename($this->current_site['path']);

        if (empty($site_name) || $site_name == '.') {
            return $urls;
        }

        // 只包含最常见和最相关的开发环境模式
        $dev_patterns = array(
            // 最常见的本地开发模式
            array('url' => "http://localhost/{$site_name}", 'priority' => 9),
            array('url' => "https://localhost/{$site_name}", 'priority' => 8),

            // 本地域名模式
            array('url' => "http://{$site_name}.local", 'priority' => 7),
            array('url' => "https://{$site_name}.local", 'priority' => 6),
            array('url' => "http://{$site_name}.test", 'priority' => 6),

            // 常见端口
            array('url' => "http://localhost:8080/{$site_name}", 'priority' => 5),
            array('url' => "http://localhost:8000/{$site_name}", 'priority' => 5),
        );

        foreach ($dev_patterns as $pattern) {
            $urls[] = array('url' => $pattern['url'], 'source' => 'development', 'priority' => $pattern['priority']);
        }

        return $urls;
    }

    /**
     * 过滤和排序URL
     */
    private function filterAndRankUrls($url_data) {
        // 去重
        $unique_urls = array();
        foreach ($url_data as $item) {
            $url = $item['url'];
            if (!isset($unique_urls[$url])) {
                $unique_urls[$url] = $item;
            } else {
                // 如果已存在，保留优先级更高的
                if ($item['priority'] > $unique_urls[$url]['priority']) {
                    $unique_urls[$url] = $item;
                }
            }
        }

        // 按优先级排序
        uasort($unique_urls, function($a, $b) {
            return $b['priority'] - $a['priority'];
        });

        // 返回包含完整信息的数组
        return array_values($unique_urls);
    }
    
    /**
     * 显示欢迎界面
     */
    public function showWelcome() {
        $this->colorOutput("\n╔══════════════════════════════════════════════════════════════╗\n", 'cyan');
        $this->colorOutput("║              统一的交互式WordPress URL替换脚本               ║\n", 'cyan');
        $this->colorOutput("║                                                              ║\n", 'cyan');
        $this->colorOutput("║  功能特性：                                                  ║\n", 'cyan');
        $this->colorOutput("║  • 智能站点发现和选择                                        ║\n", 'cyan');
        $this->colorOutput("║  • 精准URL猜测和选择                                         ║\n", 'cyan');
        $this->colorOutput("║  • 操作确认和备份功能                                        ║\n", 'cyan');
        $this->colorOutput("║  • 详细日志和回滚支持                                        ║\n", 'cyan');
        $this->colorOutput("║  • 实时进度显示                                              ║\n", 'cyan');
        $this->colorOutput("║                                                              ║\n", 'cyan');
        $this->colorOutput("╚══════════════════════════════════════════════════════════════╝\n", 'cyan');
        echo "\n";
    }
    
    /**
     * 站点发现功能 - 提示用户输入根目录并扫描WordPress站点
     */
    public function discoverSites() {
        $this->colorOutput("🔍 站点发现功能\n\n", 'blue');
        
        // 提示用户输入根目录路径
        while (true) {
            $this->colorOutput("请输入WordPress站点根目录路径（例如：/var/www/ 或 /home/user/sites/）\n", 'yellow');

            $input = $this->getUserInput("或者直接按回车使用默认路径 [/var/www/]: ");
            if (empty($input)) {
                $input = '/var/www/';
            }
            
            // 确保路径以斜杠结尾
            $input = rtrim($input, '/') . '/';
            
            if (is_dir($input)) {
                $this->base_dirs[] = $input;
                $this->log("添加扫描目录: " . $input);
                break;
            } else {
                $this->colorOutput("错误: 目录不存在，请重新输入\n", 'red');
            }
        }
        
        // 询问是否添加更多目录
        while (true) {
            $choice = $this->getUserInput("\n是否添加更多扫描目录？(y/N): ");

            if (strtolower($choice) === 'y') {
                $additional_dir = $this->getUserInput("请输入额外的目录路径: ");
                $additional_dir = rtrim($additional_dir, '/') . '/';
                
                if (is_dir($additional_dir)) {
                    $this->base_dirs[] = $additional_dir;
                    $this->log("添加额外扫描目录: " . $additional_dir);
                } else {
                    $this->colorOutput("警告: 目录不存在，跳过\n", 'yellow');
                }
            } else {
                break;
            }
        }
        
        // 扫描WordPress站点
        $this->scanWordPressSites();
    }
    
    /**
     * 扫描WordPress站点
     */
    private function scanWordPressSites() {
        $this->colorOutput("\n正在扫描WordPress站点...\n", 'blue');
        $this->discovered_sites = array();
        
        foreach ($this->base_dirs as $base_dir) {
            $this->colorOutput("扫描目录: " . $base_dir . "\n", 'cyan');
            
            if (!is_dir($base_dir)) {
                $this->colorOutput("跳过不存在的目录: " . $base_dir . "\n", 'yellow');
                continue;
            }
            
            $items = scandir($base_dir);
            foreach ($items as $item) {
                if ($item == '.' || $item == '..') {
                    continue;
                }
                
                $site_path = $base_dir . $item;
                if (is_dir($site_path) && file_exists($site_path . '/wp-config.php')) {
                    $this->discovered_sites[] = array(
                        'name' => $item,
                        'path' => $site_path,
                        'base_dir' => $base_dir
                    );
                    $this->log("发现WordPress站点: " . $site_path);
                }
            }
        }
        
        $this->displayDiscoveredSites();
    }
    
    /**
     * 显示发现的站点并让用户选择
     */
    private function displayDiscoveredSites() {
        if (empty($this->discovered_sites)) {
            $this->colorOutput("\n❌ 未发现任何WordPress站点\n", 'red');
            $this->colorOutput("请检查输入的目录路径是否正确\n", 'yellow');
            exit(1);
        }
        
        $this->colorOutput("\n✅ 发现以下WordPress站点:\n\n", 'green');
        
        foreach ($this->discovered_sites as $i => $site) {
            $this->colorOutput(sprintf("  %d. %s\n", $i + 1, $site['name']), 'white');
            $this->colorOutput(sprintf("     路径: %s\n", $site['path']), 'cyan');
        }
        
        echo "\n";
        $this->colorOutput("总计: " . count($this->discovered_sites) . " 个站点\n\n", 'blue');
        
        // 让用户选择站点
        $this->selectSite();
    }
    
    /**
     * 站点选择
     */
    private function selectSite() {
        while (true) {
            $choice = $this->getUserInput("请选择要处理的站点 (1-" . count($this->discovered_sites) . "): ");
            
            if (is_numeric($choice) && $choice >= 1 && $choice <= count($this->discovered_sites)) {
                $this->current_site = $this->discovered_sites[$choice - 1];
                $this->log("选择站点: " . $this->current_site['name'] . " (" . $this->current_site['path'] . ")");
                
                $this->colorOutput("\n✅ 已选择站点: " . $this->current_site['name'] . "\n", 'green');
                $this->colorOutput("站点路径: " . $this->current_site['path'] . "\n\n", 'cyan');
                break;
            } else {
                $this->colorOutput("无效选择，请重试\n", 'red');
            }
        }
    }
    
    /**
     * URL猜测与选择功能
     */
    public function urlGuessAndSelect() {
        $this->colorOutput("🎯 智能URL猜测与选择\n\n", 'blue');

        // 猜测旧URL
        $this->colorOutput("正在分析站点并猜测可能的旧URL...\n", 'yellow');
        $old_urls = $this->guessOldUrls();

        if (!empty($old_urls)) {
            $this->colorOutput("\n✅ 发现以下可能的旧URL:\n\n", 'green');

            foreach ($old_urls as $i => $url_info) {
                $url = is_array($url_info) ? $url_info['url'] : $url_info;
                $source = is_array($url_info) ? $url_info['source'] : 'unknown';
                $priority = is_array($url_info) ? $url_info['priority'] : 5;

                $source_desc = $this->getSourceDescription($source);

                $this->colorOutput(sprintf("  %d. %s\n", $i + 1, $url), 'white');
                $this->colorOutput(sprintf("     来源: %s (优先级: %d)\n", $source_desc, $priority), 'cyan');
            }

            // 添加自定义输入选项
            $custom_option = count($old_urls) + 1;
            $this->colorOutput(sprintf("\n  %d. 自定义输入URL\n", $custom_option), 'yellow');

            // 用户选择
            while (true) {
                $choice = $this->getUserInput("\n请选择旧URL (1-" . $custom_option . "): ");

                if (is_numeric($choice) && $choice >= 1 && $choice <= count($old_urls)) {
                    $selected_url_info = $old_urls[$choice - 1];
                    $this->old_url = is_array($selected_url_info) ? $selected_url_info['url'] : $selected_url_info;
                    $this->log("选择旧URL: " . $this->old_url);
                    break;
                } elseif ($choice == $custom_option) {
                    $this->old_url = $this->getCustomUrl("请输入旧URL: ");
                    break;
                } else {
                    $this->colorOutput("无效选择，请重试\n", 'red');
                }
            }
        } else {
            $this->colorOutput("⚠️ 未能自动猜测到旧URL，请手动输入\n", 'yellow');
            $this->old_url = $this->getCustomUrl("请输入旧URL: ");
        }

        // 输入新URL
        $this->new_url = $this->getCustomUrl("请输入新URL: ");

        // 验证URL
        if (!$this->validateUrls()) {
            exit(1);
        }

        $this->colorOutput("\n✅ URL配置完成:\n", 'green');
        $this->colorOutput("旧URL: " . $this->old_url . "\n", 'cyan');
        $this->colorOutput("新URL: " . $this->new_url . "\n", 'cyan');
    }

    /**
     * 获取自定义URL输入
     */
    private function getCustomUrl($prompt) {
        while (true) {
            $url = $this->getUserInput($prompt);

            if (empty($url)) {
                $this->colorOutput("URL不能为空，请重新输入\n", 'red');
                continue;
            }

            if (!filter_var($url, FILTER_VALIDATE_URL) && !preg_match('/^https?:\/\//', $url)) {
                $this->colorOutput("URL格式无效，请输入完整的URL（包含http://或https://）\n", 'red');
                continue;
            }

            return rtrim($url, '/');
        }
    }

    /**
     * 验证URL配置
     */
    private function validateUrls() {
        if (empty($this->old_url) || empty($this->new_url)) {
            $this->colorOutput("❌ 错误: URL不能为空\n", 'red');
            return false;
        }

        if ($this->old_url == $this->new_url) {
            $this->colorOutput("❌ 错误: 新旧URL相同\n", 'red');
            return false;
        }

        return true;
    }

    /**
     * 显示操作确认
     */
    public function showOperationConfirmation() {
        $this->colorOutput("\n" . str_repeat("=", 60) . "\n", 'blue');
        $this->colorOutput("📋 操作确认\n\n", 'blue');

        $this->colorOutput("站点信息:\n", 'bold');
        $this->colorOutput("  站点名称: " . $this->current_site['name'] . "\n", 'white');
        $this->colorOutput("  站点路径: " . $this->current_site['path'] . "\n", 'white');

        $this->colorOutput("\nURL替换信息:\n", 'bold');
        $this->colorOutput("  第一步 - 完整URL替换:\n", 'cyan');
        $this->colorOutput("    旧URL: " . $this->old_url . "\n", 'white');
        $this->colorOutput("    新URL: " . $this->new_url . "\n", 'white');

        // 提取域名用于第二步替换
        $old_domain = $this->extractDomain($this->old_url);
        $new_domain = $this->extractDomain($this->new_url);

        if ($old_domain && $new_domain && $old_domain !== $new_domain) {
            $this->colorOutput("  第二步 - 域名替换:\n", 'cyan');
            $this->colorOutput("    旧域名: " . $old_domain . "\n", 'white');
            $this->colorOutput("    新域名: " . $new_domain . "\n", 'white');

            // 显示替换类型说明
            if (strpos($new_domain, '/') !== false) {
                $this->colorOutput("    说明: 包含路径的域名替换\n", 'yellow');
            }
        }

        $this->colorOutput("\n操作范围:\n", 'bold');
        $this->colorOutput("  ✓ 第一步：完整URL替换（数据库 + 文件）\n", 'green');

        if ($old_domain && $new_domain && $old_domain !== $new_domain) {
            $this->colorOutput("  ✓ 第二步：域名替换（数据库 + 文件）\n", 'green');
        } else {
            $this->colorOutput("  ⏭️  第二步：域名替换（跳过，域名相同）\n", 'yellow');
        }

        $this->colorOutput("\n" . str_repeat("=", 60) . "\n", 'blue');

        // 备份选项
        $this->offerBackupOption();

        // 最终确认
        while (true) {
            $confirm = $this->getUserInput("\n⚠️  确定要执行URL替换操作吗？此操作将修改数据库和文件！(Y/n): ");

            if (strtolower($confirm) === 'y' || empty($confirm)) {
                $this->log("用户确认执行URL替换操作");
                break;
            } elseif (strtolower($confirm) === 'n') {
                $this->colorOutput("❌ 操作已取消\n", 'yellow');
                $this->log("用户取消操作");
                exit(0);
            } else {
                $this->colorOutput("请输入 y 或 n\n", 'red');
            }
        }
    }

    /**
     * 提供备份选项
     */
    private function offerBackupOption() {
        $this->colorOutput("\n💾 数据备份选项\n", 'blue');

        while (true) {
            $backup_choice = $this->getUserInput("是否在操作前创建数据库备份？(Y/n): ");

            if (strtolower($backup_choice) === 'y' || empty($backup_choice)) {
                $this->createDatabaseBackup();
                break;
            } elseif (strtolower($backup_choice) === 'n') {
                $this->colorOutput("⚠️  跳过数据库备份\n", 'yellow');
                $this->log("用户选择跳过数据库备份");
                break;
            } else {
                $this->colorOutput("请输入 y 或 n\n", 'red');
            }
        }
    }

    /**
     * 创建数据库备份
     */
    private function createDatabaseBackup() {
        $this->colorOutput("正在创建数据库备份...\n", 'yellow');

        $backup_filename = sprintf(
            "%s/%s_backup_%s.sql",
            $this->backup_dir,
            $this->current_site['name'],
            date('Y-m-d_H-i-s')
        );

        // 获取数据库配置
        $db_config = $this->db_config;

        $mysqldump_cmd = sprintf(
            "mysqldump -h%s -u%s -p%s %s > %s 2>/dev/null",
            escapeshellarg($db_config['DB_HOST']),
            escapeshellarg($db_config['DB_USER']),
            escapeshellarg($db_config['DB_PASSWORD']),
            escapeshellarg($db_config['DB_NAME']),
            escapeshellarg($backup_filename)
        );

        $return_code = 0;
        exec($mysqldump_cmd, $output, $return_code);

        if ($return_code === 0 && file_exists($backup_filename)) {
            $this->colorOutput("✅ 数据库备份成功: " . $backup_filename . "\n", 'green');
            $this->log("数据库备份成功: " . $backup_filename);
            $this->backup_file = $backup_filename;
        } else {
            $this->colorOutput("❌ 数据库备份失败\n", 'red');
            $this->log("数据库备份失败");

            while (true) {
                $continue_choice = $this->getUserInput("是否继续执行替换操作？(y/N): ");

                if (strtolower($continue_choice) === 'y') {
                    break;
                } elseif (strtolower($continue_choice) === 'n' || empty($continue_choice)) {
                    $this->colorOutput("操作已取消\n", 'yellow');
                    exit(0);
                } else {
                    $this->colorOutput("请输入 y 或 n\n", 'red');
                }
            }
        }
    }

    /**
     * 主要的交互流程
     */
    public function run() {
        $this->showWelcome();
        $this->discoverSites();

        // 解析WordPress配置
        if (!$this->parseWpConfig()) {
            $this->colorOutput("❌ 错误: 无法解析wp-config.php配置\n", 'red');
            exit(1);
        }

        // URL猜测和选择
        $this->urlGuessAndSelect();

        // 显示操作确认
        $this->showOperationConfirmation();

        // 执行替换操作
        $this->executeReplacement();

        // 显示完成信息和后续选项
        $this->showCompletionOptions();
    }

    /**
     * 执行URL替换操作
     */
    public function executeReplacement() {
        $this->colorOutput("\n🚀 开始执行URL替换操作\n\n", 'blue');

        $start_time = microtime(true);

        // 记录操作到历史
        $operation = array(
            'timestamp' => date('Y-m-d H:i:s'),
            'site_name' => $this->current_site['name'],
            'site_path' => $this->current_site['path'],
            'old_url' => $this->old_url,
            'new_url' => $this->new_url,
            'old_domain' => $this->extractDomain($this->old_url),
            'new_domain' => $this->extractDomain($this->new_url),
            'backup_file' => $this->backup_file,
            'status' => 'started',
            'multi_step' => true
        );

        try {
            // 第一步：完整URL替换
            $this->colorOutput("🚀 第一步：执行完整URL替换\n", 'blue');
            $this->colorOutput("正在替换数据库中的完整URL...\n", 'yellow');
            $db_stats_step1 = $this->replaceDatabaseUrls($this->old_url, $this->new_url);
            $this->stats['step1']['db_total'] = $db_stats_step1['total'];
            $this->stats['step1']['db_replaced'] = $db_stats_step1['replace'];

            $this->colorOutput("正在替换文件中的完整URL...\n", 'yellow');
            $file_stats_step1 = $this->replaceFileUrls($this->old_url, $this->new_url);
            $this->stats['step1']['files_processed'] = $file_stats_step1['files_processed'];
            $this->stats['step1']['files_replaced'] = $file_stats_step1['files_replaced'];

            $this->colorOutput("✅ 第一步完成！\n", 'green');

            // 第二步：域名替换（如果域名不同）
            $old_domain = $this->extractDomain($this->old_url);
            $new_domain = $this->extractDomain($this->new_url);

            if ($old_domain && $new_domain && $old_domain !== $new_domain) {
                $this->colorOutput("\n🚀 第二步：执行域名替换\n", 'blue');
                $this->colorOutput("正在替换数据库中的域名...\n", 'yellow');
                $db_stats_step2 = $this->replaceDatabaseUrls($old_domain, $new_domain);
                $this->stats['step2']['db_total'] = $db_stats_step2['total'];
                $this->stats['step2']['db_replaced'] = $db_stats_step2['replace'];

                $this->colorOutput("正在替换文件中的域名...\n", 'yellow');
                $file_stats_step2 = $this->replaceFileUrls($old_domain, $new_domain);
                $this->stats['step2']['files_processed'] = $file_stats_step2['files_processed'];
                $this->stats['step2']['files_replaced'] = $file_stats_step2['files_replaced'];

                $this->colorOutput("✅ 第二步完成！\n", 'green');
            } else {
                $this->colorOutput("\n⏭️  跳过第二步：域名相同或无效\n", 'yellow');
            }

            // 显示统计信息
            $this->showStats();

            $operation['status'] = 'completed';
            $operation['duration'] = round(microtime(true) - $start_time, 2);

            $this->colorOutput("\n🎉 多步骤URL替换操作完成！\n", 'green');
            $this->log("多步骤URL替换操作成功完成");

        } catch (Exception $e) {
            $operation['status'] = 'error';
            $operation['error'] = $e->getMessage();

            $this->colorOutput("\n❌ 执行过程中发生错误: " . $e->getMessage() . "\n", 'red');
            $this->log("执行错误: " . $e->getMessage());
        }

        // 保存操作历史
        $this->operation_history[] = $operation;
        $this->saveOperationHistory();
    }

    /**
     * 保存操作历史
     */
    private function saveOperationHistory() {
        $history_file = './operation_history.json';

        // 读取现有历史
        $existing_history = array();
        if (file_exists($history_file)) {
            $content = file_get_contents($history_file);
            $existing_history = json_decode($content, true) ?: array();
        }

        // 合并新操作
        $existing_history = array_merge($existing_history, $this->operation_history);

        // 保存历史
        file_put_contents($history_file, json_encode($existing_history, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
        $this->log("操作历史已保存");
    }

    /**
     * 显示完成选项
     */
    public function showCompletionOptions() {
        $this->colorOutput("\n" . str_repeat("=", 60) . "\n", 'blue');
        $this->colorOutput("🎉 操作完成！\n\n", 'blue');

        $this->colorOutput("后续选项:\n", 'bold');
        $this->colorOutput("  1. 处理另一个站点\n", 'white');
        $this->colorOutput("  2. 查看操作历史\n", 'white');
        $this->colorOutput("  3. 回滚最近的操作\n", 'white');
        $this->colorOutput("  4. 退出程序\n", 'white');

        while (true) {
            $choice = $this->getUserInput("\n请选择 (1-4): ");

            switch ($choice) {
                case '1':
                    $this->colorOutput("\n重新开始处理新站点...\n", 'blue');
                    $this->discoverSites();
                    return;

                case '2':
                    $this->showOperationHistory();
                    break;

                case '3':
                    $this->offerRollback();
                    break;

                case '4':
                    $this->colorOutput("\n👋 感谢使用！再见！\n", 'green');
                    exit(0);

                default:
                    $this->colorOutput("无效选择，请重试\n", 'red');
            }
        }
    }

    /**
     * 显示操作历史
     */
    private function showOperationHistory() {
        $history_file = './operation_history.json';

        if (!file_exists($history_file)) {
            $this->colorOutput("\n📝 暂无操作历史\n", 'yellow');
            return;
        }

        $history = json_decode(file_get_contents($history_file), true);
        if (empty($history)) {
            $this->colorOutput("\n📝 暂无操作历史\n", 'yellow');
            return;
        }

        $this->colorOutput("\n📝 操作历史:\n\n", 'blue');

        foreach (array_reverse($history) as $i => $operation) {
            $this->colorOutput(sprintf("操作 #%d:\n", count($history) - $i), 'bold');
            $this->colorOutput("  时间: " . $operation['timestamp'] . "\n", 'white');
            $this->colorOutput("  站点: " . $operation['site_name'] . "\n", 'white');

            // 显示多步骤信息
            if (isset($operation['multi_step']) && $operation['multi_step']) {
                $this->colorOutput("  类型: 多步骤URL替换\n", 'cyan');
                $this->colorOutput("  第一步 - 完整URL: " . $operation['old_url'] . " → " . $operation['new_url'] . "\n", 'white');
                if (isset($operation['old_domain']) && isset($operation['new_domain']) &&
                    $operation['old_domain'] !== $operation['new_domain']) {
                    $this->colorOutput("  第二步 - 域名: " . $operation['old_domain'] . " → " . $operation['new_domain'] . "\n", 'white');
                }
            } else {
                $this->colorOutput("  旧URL: " . $operation['old_url'] . "\n", 'white');
                $this->colorOutput("  新URL: " . $operation['new_url'] . "\n", 'white');
            }

            $status_color = $operation['status'] === 'completed' ? 'green' : 'red';
            $this->colorOutput("  状态: " . $operation['status'] . "\n", $status_color);

            if (isset($operation['backup_file'])) {
                $this->colorOutput("  备份: " . $operation['backup_file'] . "\n", 'cyan');
            }

            if (isset($operation['duration'])) {
                $this->colorOutput("  用时: " . $operation['duration'] . "秒\n", 'cyan');
            }

            echo "\n";
        }
    }

    /**
     * 提供回滚选项
     */
    private function offerRollback() {
        $history_file = './operation_history.json';

        if (!file_exists($history_file)) {
            $this->colorOutput("\n⚠️ 无可回滚的操作\n", 'yellow');
            return;
        }

        $history = json_decode(file_get_contents($history_file), true);
        $completed_operations = array_filter($history, function($op) {
            return $op['status'] === 'completed' && isset($op['backup_file']) && file_exists($op['backup_file']);
        });

        if (empty($completed_operations)) {
            $this->colorOutput("\n⚠️ 无可回滚的操作（需要有备份文件）\n", 'yellow');
            return;
        }

        $this->colorOutput("\n🔄 可回滚的操作:\n\n", 'blue');

        $rollback_options = array_values($completed_operations);
        foreach ($rollback_options as $i => $operation) {
            $this->colorOutput(sprintf("  %d. %s - %s (%s -> %s)\n",
                $i + 1,
                $operation['timestamp'],
                $operation['site_name'],
                $operation['old_url'],
                $operation['new_url']
            ), 'white');
        }

        while (true) {
            $choice = $this->getUserInput("\n请选择要回滚的操作 (1-" . count($rollback_options) . ") 或按回车取消: ");

            if (empty($choice)) {
                return;
            }

            if (is_numeric($choice) && $choice >= 1 && $choice <= count($rollback_options)) {
                $operation = $rollback_options[$choice - 1];
                $this->performRollback($operation);
                break;
            } else {
                $this->colorOutput("无效选择，请重试\n", 'red');
            }
        }
    }

    /**
     * 执行回滚操作
     */
    private function performRollback($operation) {
        $this->colorOutput("\n⚠️ 即将回滚以下操作:\n", 'yellow');
        $this->colorOutput("站点: " . $operation['site_name'] . "\n", 'white');
        $this->colorOutput("时间: " . $operation['timestamp'] . "\n", 'white');
        $this->colorOutput("备份文件: " . $operation['backup_file'] . "\n", 'white');

        while (true) {
            $confirm = $this->getUserInput("\n确定要执行回滚吗？这将恢复数据库到操作前的状态！(y/N): ");

            if (strtolower($confirm) === 'y') {
                break;
            } elseif (strtolower($confirm) === 'n' || empty($confirm)) {
                $this->colorOutput("回滚已取消\n", 'yellow');
                return;
            } else {
                $this->colorOutput("请输入 y 或 n\n", 'red');
            }
        }

        // 执行数据库恢复
        $this->colorOutput("\n正在恢复数据库...\n", 'yellow');

        // 需要重新解析数据库配置
        $original_site = $this->current_site;
        $this->current_site = array('path' => $operation['site_path']);
        $this->parseWpConfig();
        $db_config = $this->db_config;
        $this->current_site = $original_site;

        $mysql_cmd = sprintf(
            "mysql -h%s -u%s -p%s %s < %s 2>/dev/null",
            escapeshellarg($db_config['DB_HOST']),
            escapeshellarg($db_config['DB_USER']),
            escapeshellarg($db_config['DB_PASSWORD']),
            escapeshellarg($db_config['DB_NAME']),
            escapeshellarg($operation['backup_file'])
        );

        $return_code = 0;
        exec($mysql_cmd, $output, $return_code);

        if ($return_code === 0) {
            $this->colorOutput("✅ 数据库回滚成功！\n", 'green');
            $this->log("数据库回滚成功: " . $operation['backup_file']);
        } else {
            $this->colorOutput("❌ 数据库回滚失败\n", 'red');
            $this->log("数据库回滚失败");
        }
    }

    /**
     * 替换数据库中的URL - 基于原项目DomainNameChanger类的逻辑，增强错误处理
     */
    public function replaceDatabaseUrls($old_url, $new_url) {
        try {
            // 首先检查数据库连接
            $test_mysqli = new mysqli(
                $this->db_config['DB_HOST'],
                $this->db_config['DB_USER'],
                $this->db_config['DB_PASSWORD'],
                $this->db_config['DB_NAME']
            );

            if ($test_mysqli->connect_error) {
                throw new Exception('数据库连接失败: ' . $test_mysqli->connect_error);
            }

            // 检查并修复可能的日期问题
            $this->fixInvalidDates($test_mysqli);
            $test_mysqli->close();

            // 执行URL替换
            $config = array(
                'change_from' => array($old_url),
                'change_to' => array($new_url),
                'host' => $this->db_config['DB_HOST'],
                'user' => $this->db_config['DB_USER'],
                'pw' => $this->db_config['DB_PASSWORD'],
                'db' => $this->db_config['DB_NAME'],
                'charset' => $this->db_config['DB_CHARSET'],
                'debug' => false,
            );

            $domain_name_changer = new DomainNameChanger($config);
            $status = $domain_name_changer->do_it();

            $this->log(sprintf(
                "数据库URL替换完毕！总数：%s，替换数：%s，用时：%.2f秒",
                $status['total'],
                $status['replace'],
                $status['time_used']
            ));

            return $status;

        } catch (Exception $e) {
            $this->log("数据库URL替换失败: " . $e->getMessage());
            throw $e;
        }
    }

    /**
     * 修复数据库中的无效日期
     */
    private function fixInvalidDates($mysqli) {
        $this->log("检查并修复数据库中的无效日期...");

        $table_prefix = $this->db_config['table_prefix'];

        // 设置SQL模式以允许无效日期
        $mysqli->query("SET SESSION sql_mode = 'ALLOW_INVALID_DATES'");

        // 修复posts表中的无效日期
        $fix_queries = array(
            "UPDATE {$table_prefix}posts SET post_date_gmt = NULL WHERE post_date_gmt = '0000-00-00 00:00:00'",
            "UPDATE {$table_prefix}posts SET post_modified_gmt = NULL WHERE post_modified_gmt = '0000-00-00 00:00:00'",
            "UPDATE {$table_prefix}comments SET comment_date_gmt = NULL WHERE comment_date_gmt = '0000-00-00 00:00:00'"
        );

        $fixed_count = 0;
        foreach ($fix_queries as $query) {
            $result = $mysqli->query($query);
            if ($result && $mysqli->affected_rows > 0) {
                $fixed_count += $mysqli->affected_rows;
            }
        }

        if ($fixed_count > 0) {
            $this->log("修复了 {$fixed_count} 个无效日期记录");
        } else {
            $this->log("未发现需要修复的无效日期");
        }
    }

    /**
     * 替换文件中的URL
     */
    public function replaceFileUrls($old_url, $new_url, $extensions = null) {
        if ($extensions === null) {
            $extensions = array('.css', '.js', '.html', '.htm', '.php', '.json', '.xml');
        }

        $stats = array('files_processed' => 0, 'files_replaced' => 0);

        // 要排除的目录
        $exclude_dirs = array(
            'node_modules', '.git', '.svn', '__pycache__',
            'vendor', 'cache', 'logs', 'tmp', 'temp', 'wp-content/cache'
        );

        $this->scanDirectory($this->current_site['path'], $old_url, $new_url, $extensions, $exclude_dirs, $stats);

        $this->log(sprintf(
            "文件URL替换完成: 处理 %d 个文件，替换 %d 个文件",
            $stats['files_processed'],
            $stats['files_replaced']
        ));

        return $stats;
    }

    /**
     * 递归扫描目录
     */
    private function scanDirectory($dir, $old_url, $new_url, $extensions, $exclude_dirs, &$stats) {
        if (!is_dir($dir)) {
            return;
        }

        $items = scandir($dir);
        foreach ($items as $item) {
            if ($item == '.' || $item == '..') {
                continue;
            }

            $path = $dir . '/' . $item;

            if (is_dir($path)) {
                // 检查是否为排除目录
                $should_exclude = false;
                foreach ($exclude_dirs as $exclude_dir) {
                    if (strpos($path, $exclude_dir) !== false) {
                        $should_exclude = true;
                        break;
                    }
                }

                if (!$should_exclude) {
                    $this->scanDirectory($path, $old_url, $new_url, $extensions, $exclude_dirs, $stats);
                }
            } elseif (is_file($path)) {
                $this->processFile($path, $old_url, $new_url, $extensions, $stats);
            }
        }
    }

    /**
     * 处理单个文件
     */
    private function processFile($file_path, $old_url, $new_url, $extensions, &$stats) {
        // 检查文件扩展名
        $ext = strtolower(pathinfo($file_path, PATHINFO_EXTENSION));
        if (!in_array('.' . $ext, $extensions)) {
            return;
        }

        // 跳过过大的文件（超过10MB）
        if (filesize($file_path) > 10 * 1024 * 1024) {
            return;
        }

        try {
            $content = file_get_contents($file_path);
            if ($content === false) {
                return;
            }

            $stats['files_processed']++;

            // 检查是否包含旧URL
            if (strpos($content, $old_url) !== false) {
                $new_content = str_replace($old_url, $new_url, $content);

                if (file_put_contents($file_path, $new_content) !== false) {
                    $stats['files_replaced']++;
                    $this->log("已替换文件: " . $file_path);
                }
            }
        } catch (Exception $e) {
            $this->log("处理文件失败 " . $file_path . ": " . $e->getMessage());
        }
    }

    /**
     * 显示统计信息
     */
    private function showStats() {
        $end_time = microtime(true);
        $total_time = $end_time - $this->stats['start_time'];

        $this->colorOutput("\n📊 多步骤替换统计信息:\n", 'blue');

        // 第一步统计
        $this->colorOutput("\n🔸 第一步（完整URL替换）:\n", 'cyan');
        $this->colorOutput("  数据库记录总数: " . $this->stats['step1']['db_total'] . "\n", 'white');
        $this->colorOutput("  数据库替换记录数: " . $this->stats['step1']['db_replaced'] . "\n", 'white');
        $this->colorOutput("  处理文件总数: " . $this->stats['step1']['files_processed'] . "\n", 'white');
        $this->colorOutput("  替换文件数: " . $this->stats['step1']['files_replaced'] . "\n", 'white');

        // 第二步统计（如果执行了）
        if ($this->stats['step2']['db_total'] > 0 || $this->stats['step2']['files_processed'] > 0) {
            $this->colorOutput("\n🔸 第二步（域名替换）:\n", 'cyan');
            $this->colorOutput("  数据库记录总数: " . $this->stats['step2']['db_total'] . "\n", 'white');
            $this->colorOutput("  数据库替换记录数: " . $this->stats['step2']['db_replaced'] . "\n", 'white');
            $this->colorOutput("  处理文件总数: " . $this->stats['step2']['files_processed'] . "\n", 'white');
            $this->colorOutput("  替换文件数: " . $this->stats['step2']['files_replaced'] . "\n", 'white');
        }

        // 总计统计
        $total_db_total = $this->stats['step1']['db_total'] + $this->stats['step2']['db_total'];
        $total_db_replaced = $this->stats['step1']['db_replaced'] + $this->stats['step2']['db_replaced'];
        $total_files_processed = $this->stats['step1']['files_processed'] + $this->stats['step2']['files_processed'];
        $total_files_replaced = $this->stats['step1']['files_replaced'] + $this->stats['step2']['files_replaced'];

        $this->colorOutput("\n🔸 总计:\n", 'bold');
        $this->colorOutput("  数据库记录总数: " . $total_db_total . "\n", 'white');
        $this->colorOutput("  数据库替换记录数: " . $total_db_replaced . "\n", 'white');
        $this->colorOutput("  处理文件总数: " . $total_files_processed . "\n", 'white');
        $this->colorOutput("  替换文件数: " . $total_files_replaced . "\n", 'white');
        $this->colorOutput("  总用时: " . round($total_time, 2) . "秒\n", 'white');
    }
}

// ============================================================================
// 序列化处理函数（从wp_url_replacer.php迁移）
// ============================================================================

/**
 * 递归替换函数
 */
if (!function_exists('digui_replace')) {
    function digui_replace($string, $change_from, $change_to) {
        if (is_array($change_to)) { //multi to multi
            foreach ($change_from as $key => $value) {
                if (is_string($string) && strpos($string, $value) !== false) {
                    $string = str_replace($value, $change_to[$key], $string);
                } elseif (is_array($string)) {
                    foreach ($string as $k => $v) {
                        $string[$k] = digui_replace($v, $change_from, $change_to);
                    }
                }
            }
        } else { //multi to single
            foreach ($change_from as $key => $value) {
                if (is_string($string) && strpos($string, $value) !== false) {
                    $string = str_replace($value, $change_to, $string);
                } elseif (is_array($string)) {
                    foreach ($string as $k => $v) {
                        $string[$k] = digui_replace($v, $change_from, $change_to);
                    }
                }
            }
        }
        return $string;
    }
}

/**
 * 递归反序列化
 */
if (!function_exists('digui_maybe_unserialize')) {
    function digui_maybe_unserialize($string, $tries = 0) {
        $unserialize_string = maybe_unserialize($string);
        ++$tries;
        if ($string == $unserialize_string) {
            return array('return' => $string, 'tries' => --$tries);
        } else {
            return digui_maybe_unserialize($unserialize_string, $tries);
        }
    }
}

/**
 * 递归序列化
 */
if (!function_exists('digui_maybe_serialize')) {
    function digui_maybe_serialize($string, $tries) {
        if ($tries > 0) {
            $string = maybe_serialize($string);
            if (--$tries > 0) {
                return digui_maybe_serialize($string, $tries);
            } else {
                return $string;
            }
        }
        return $string;
    }
}

/**
 * JSON检测函数
 */
if (!function_exists('isJson')) {
    function isJson($string) {
        if (!is_string($string)) {
            return false;
        }
        json_decode($string);
        return (json_last_error() == JSON_ERROR_NONE);
    }
}

/**
 * WordPress的maybe_serialize函数
 */
if (!function_exists('maybe_serialize')) {
    function maybe_serialize($data) {
        if (is_array($data) || is_object($data)) {
            return serialize($data);
        }

        if (is_serialized($data, false)) {
            return $data;
        }

        return $data;
    }
}

/**
 * WordPress的maybe_unserialize函数
 */
if (!function_exists('maybe_unserialize')) {
    function maybe_unserialize($original) {
        if (is_serialized($original)) {
            return @unserialize($original);
        }
        return $original;
    }
}

/**
 * WordPress的is_serialized函数
 */
if (!function_exists('is_serialized')) {
    function is_serialized($data, $strict = true) {
        if (!is_string($data)) {
            return false;
        }
        $data = trim($data);
        if ('N;' == $data) {
            return true;
        }
        if (strlen($data) < 4) {
            return false;
        }
        if (':' !== $data[1]) {
            return false;
        }
        if ($strict) {
            $lastc = substr($data, -1);
            if (';' !== $lastc && '}' !== $lastc) {
                return false;
            }
        } else {
            $semicolon = strpos($data, ';');
            $brace     = strpos($data, '}');
            if (false === $semicolon && false === $brace) {
                return false;
            }
            if (false !== $semicolon && $semicolon < 3) {
                return false;
            }
            if (false !== $brace && $brace < 4) {
                return false;
            }
        }
        $token = $data[0];
        switch ($token) {
            case 's':
                if ($strict) {
                    if ('"' !== substr($data, -2, 1)) {
                        return false;
                    }
                } elseif (false === strpos($data, '"')) {
                    return false;
                }
            case 'a':
            case 'O':
                return (bool) preg_match("/^{$token}:[0-9]+:/s", $data);
            case 'b':
            case 'i':
            case 'd':
                $end = $strict ? '$' : '';
                return (bool) preg_match("/^{$token}:[0-9.E-]+;$end/", $data);
        }
        return false;
    }
}

// ============================================================================
// DomainNameChanger类（从wp_url_replacer.php迁移）
// ============================================================================

/**
 * Domain Name Changer - 完全基于原项目的逻辑
 */
if (!class_exists('DomainNameChanger')) {
    class DomainNameChanger {
        protected $mysqli;
        protected $change_from = array();
        protected $change_to = array();
        protected $host, $user, $pw, $db, $charset = null;
        protected $tables = array();
        protected $one_row;
        protected $replace_sql;
        protected $ok = 0;
        protected $count = 0;
        protected $min_print = 1;
        protected $max_print = -1;
        protected $time_start = 0;
        protected $time_end = 0;
        protected $total_query_time = 0; //数据查询时间
        protected $total_update_time = 0; //数据更新时间
        protected $total_replace_time = 0; //数据替换时间
        protected $debug = false;

        protected $get_row_per_query = 10000;

        public function __construct($config) {
            $this->change_from = $config['change_from'];
            $this->change_to = $config['change_to'];
            $this->host = $config['host'];
            $this->user = $config['user'];
            $this->pw = $config['pw'];
            $this->db = $config['db'];
            $this->charset = $config['charset'];
            $this->debug = isset($config['debug']) ? $config['debug'] : false;

            $this->time_start = microtime(true);
            $this->mysqli = new mysqli($this->host, $this->user, $this->pw, $this->db);

            if ($this->mysqli->connect_error) {
                die('数据库连接失败: ' . $this->mysqli->connect_error);
            }

            $this->mysqli->set_charset($this->charset);

            // 设置SQL模式以兼容旧数据
            $this->mysqli->query("SET SESSION sql_mode = 'ALLOW_INVALID_DATES'");
        }

        //获取所有表
        public function get_all_table() {
            $sql = "SHOW TABLES";
            $result = $this->mysqli->query($sql);
            while ($row = $result->fetch_array()) {
                $this->tables[$row[0]] = array();
            }
        }

        //构造表结构
        public function contruct_tables() {
            foreach ($this->tables as $table_name => $table_cols_name_type) {
                $sql = sprintf("SHOW COLUMNS FROM `%s`", $table_name);
                $result = $this->mysqli->query($sql);
                while ($row = $result->fetch_assoc()) {
                    $this->tables[$table_name][$row['Field']] = $row['Type'];
                }
            }
        }

        //判断是否匹配字符串
        protected function is_match_string($table_name) {
            foreach ($this->one_row as $key => $value) {
                if (is_string($value)) {
                    if (is_array($this->change_from)) {
                        foreach ($this->change_from as $change_from_value) {
                            if (strpos($value, $change_from_value) !== false) {
                                return true;
                            }
                        }
                    } else {
                        if (strpos($value, $this->change_from) !== false) {
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        //普通字符串替换
        protected function normal_string_replace($string) {
            if (is_array($this->change_to)) { //multi to multi
                foreach ($this->change_from as $key => $value) {
                    if (strpos($string, $value) !== false) {
                        $string = str_replace($value, $this->change_to[$key], $string);
                    }
                }
            } else { //multi to single
                foreach ($this->change_from as $key => $value) {
                    if (strpos($string, $value) !== false) {
                        $string = str_replace($value, $this->change_to, $string);
                    }
                }
            }
            return $string;
        }

        //序列化字符串替换
        public function serialized_string_replace($matches) {
            $str = $matches[2];
            if (is_array($this->change_to)) { //multi to multi
                foreach ($this->change_from as $key => $value) {
                    if (strpos($str, $value) !== false) { //替换域名长路径
                        $str = str_replace($value, $this->change_to[$key], $str);
                    } else { //其他不用替换
                    }
                }
            } else { //multi to single
                foreach ($this->change_from as $key => $value) {
                    if (strpos($str, $value) !== false) { //替换域名长路径
                        $str = str_replace($value, $this->change_to, $str);
                    } else { //其他不用替换
                    }
                }
            }
            return sprintf("s:%s:\"%s\";", strlen($str), $str);
        }

        //JSON字符串替换
        function json_string_replace($string) {
            if (is_array($this->change_to)) { //multi to multi
                foreach ($this->change_from as $key => $value) {
                    //经过json格式化之后，普通的字符串，前后会加入双引号，所以要使用trim去除。
                    if (strpos($string, $value) !== false) {
                        $string = str_replace($value, $this->change_to[$key], $string);
                    } else {
                        $string = str_replace(trim(json_encode($value), '"'), trim(json_encode($this->change_to[$key]), '"'), $string);
                    }
                }
            } else { //multi to single
                foreach ($this->change_from as $key => $value) {
                    //经过json格式化之后，普通的字符串，前后会加入双引号，所以要使用trim去除。
                    if (strpos($string, $value) !== false) {
                        $string = str_replace($value, $this->change_to, $string);
                    } else {
                        $string = str_replace(trim(json_encode($value), '"'), trim(json_encode($this->change_to), '"'), $string);
                    }
                }
            }
            return $string;
        }

        //替换字符串
        protected function get_replace_string_sql($table_name) {
            $set_sql = array();
            $where_sql = array();
            foreach ($this->one_row as $key => $value) {
                if (is_string($value) and is_serialized($value)) {
                    $unserialize_return = digui_maybe_unserialize($value);
                    $new_value = digui_replace($unserialize_return['return'], $this->change_from, $this->change_to);
                    $new_value = digui_maybe_serialize($new_value, $unserialize_return['tries']);

                    if ($new_value != $value) {
                        $set_sql[] = sprintf("`%s`='%s'", $key, $this->mysqli->real_escape_string($new_value));
                    }
                } elseif (is_string($value) and isJson($value)) {
                    $new_value = $this->json_string_replace($value);
                    if ($new_value != $value) {
                        $set_sql[] = sprintf("`%s`='%s'", $key, $this->mysqli->real_escape_string($new_value));
                    }
                } elseif (is_string($value)) {
                    $new_value = $this->normal_string_replace($value);
                    if ($new_value != $value) {
                        $set_sql[] = sprintf("`%s`='%s'", $key, $this->mysqli->real_escape_string($new_value));
                    }
                }

                if ($value === null) {
                    $where_sql[] = sprintf("`%s` is null ", $key, $key);
                } else {
                    $where_sql[] = sprintf("`%s`='%s'", $key, $this->mysqli->real_escape_string($value));
                }
            }

            if (sizeof($set_sql) >= 1) {
                // 添加日期字段的特殊处理
                $date_fields = array('post_date', 'post_date_gmt', 'post_modified', 'post_modified_gmt', 'comment_date', 'comment_date_gmt');
                foreach ($date_fields as $date_field) {
                    if (isset($this->one_row[$date_field]) && $this->one_row[$date_field] === '0000-00-00 00:00:00') {
                        // 将无效日期替换为NULL或有效日期
                        $set_sql[] = sprintf("`%s`=NULL", $date_field);
                    }
                }

                $this->replace_sql = sprintf("UPDATE `%s` SET %s WHERE %s;", $table_name, implode(',', $set_sql), implode(' AND ', $where_sql));
            } else {
                $this->replace_sql = null;
            }
        }

        //do change domain name
        public function change_domain_name() {
            if ($this->tables) {
                //find and replace contents in each table cols
                foreach ($this->tables as $table_name => $table_cols_name_type) {
                    if (sizeof(array_filter($table_cols_name_type)) >= 1) {
                        $each_table_query_run = 0;

                        $query_time_start = microtime(1);
                        $select_total_sql = sprintf("SELECT COUNT(*) AS total FROM `%s`;", $table_name);
                        $result_total = $this->mysqli->query($select_total_sql);
                        $row = $result_total->fetch_assoc();
                        $total = $row['total'];

                        $query_time_end = microtime(1);
                        $each_table_query_run += ($query_time_end - $query_time_start);

                        $page = 1;

                        while (1) {
                            $offset = $this->get_row_per_query * ($page - 1);

                            $query_time_start = microtime(1);
                            $select_all_col_sql = sprintf("SELECT `%s` FROM `%s` LIMIT %d,%d;", implode('`,`', array_keys($table_cols_name_type)), $table_name, $offset, $this->get_row_per_query);

                            $result = $this->mysqli->query($select_all_col_sql);
                            $current_get = $result->num_rows;

                            $query_time_end = microtime(1);
                            $each_table_query_run += ($query_time_end - $query_time_start);

                            while ($this->one_row = $result->fetch_assoc()) {
                                if ($this->is_match_string($table_name)) {
                                    $replace_time_start = microtime(1);
                                    $this->get_replace_string_sql($table_name);
                                    $replace_time_end = microtime(1);
                                    $this->total_replace_time += $replace_time_end - $replace_time_start;
                                    if ($this->replace_sql) {
                                        $update_time_start = microtime(1);
                                        $update_result = $this->mysqli->query($this->replace_sql);
                                        $update_time_end = microtime(1);
                                        $this->total_update_time += $update_time_end - $update_time_start;

                                        if ($update_result && $this->mysqli->affected_rows > 0) {
                                            $this->ok++;
                                        }
                                    }

                                    //输出一部分，用于调试
                                    $this->count++;
                                    if (($this->count >= $this->min_print && $this->count <= $this->max_print) || $this->max_print === -1) {
                                        continue;
                                    } else {
                                        break 2;
                                    }
                                }
                            }

                            if ($total <= (($page - 1) * $this->get_row_per_query + $current_get)) {
                                break;
                            }

                            $page++;
                        }

                        $this->total_query_time += $each_table_query_run;
                    }
                }
            }
        }

        public function do_it() {
            $this->get_all_table();
            $this->contruct_tables();
            $this->change_domain_name();
            return $this->get_status();
        }

        public function print_status() {
            $this->time_end = microtime(true);
            printf("Total:< %s > , Replace: < %s > , Time Use: < %s >\n", $this->count, $this->ok, ($this->time_end - $this->time_start));
        }

        public function get_status() {
            $this->time_end = microtime(true);
            return array(
                'total' => $this->count,
                'replace' => $this->ok,
                'time_used' => ($this->time_end - $this->time_start)
            );
        }
    }
}

// 主程序入口
if (php_sapi_name() === 'cli') {
    $replacer = new InteractiveURLReplacer();
    $replacer->run();
} else {
    echo "此脚本只能在命令行中运行\n";
    exit(1);
}
