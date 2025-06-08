#!/bin/bash
# 独立的证书管理脚本 - 基于 acme.sh
# 支持 Let's Encrypt 生产/测试证书，DNS验证
# 可独立运行，不依赖主部署脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 脚本信息
SCRIPT_VERSION="1.0.0"
ACME_HOME="/root/.acme.sh"

# 配置变量
DOMAIN=""
EMAIL=""
DNS_PROVIDER=""
DNS_API_KEY=""
CERT_MODE="production"  # production 或 staging

# 日志函数
log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════╗
║                    独立证书管理工具 v1.0                        ║
║                                                                  ║
║  🔐 基于 acme.sh 的证书管理                                      ║
║  🌐 支持 DNS 验证方式                                            ║
║  🧪 支持测试/生产证书切换                                        ║
║  🔄 自动续期配置                                                 ║
║  🗑️ 证书撤销功能                                                 ║
║  📋 批量证书操作                                                 ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo
}

# 检查 acme.sh 安装
check_acme_installation() {
    if [[ ! -d "$ACME_HOME" ]] || [[ ! -f "$ACME_HOME/acme.sh" ]]; then
        log_warning "acme.sh 未安装，正在安装..."
        install_acme_sh
    else
        log_info "acme.sh 已安装"
    fi
}

# 安装 acme.sh
install_acme_sh() {
    log_info "安装 acme.sh..."
    
    # 下载并安装 acme.sh
    curl https://get.acme.sh | sh -s email="$EMAIL"
    
    # 重新加载环境
    source ~/.bashrc
    
    # 设置自动升级
    "$ACME_HOME/acme.sh" --upgrade --auto-upgrade
    
    log_success "acme.sh 安装完成"
}

# 配置 DNS 提供商
configure_dns_provider() {
    echo -e "${CYAN}请选择 DNS 提供商：${NC}"
    echo "1) Cloudflare"
    echo "2) 阿里云 DNS"
    echo "3) 腾讯云 DNS"
    echo "4) AWS Route53"
    echo "5) 其他"
    echo
    read -p "请选择 [1-5]: " dns_choice
    
    case $dns_choice in
        1)
            DNS_PROVIDER="dns_cf"
            echo
            read -p "请输入 Cloudflare API Token: " DNS_API_KEY
            export CF_Token="$DNS_API_KEY"
            ;;
        2)
            DNS_PROVIDER="dns_ali"
            echo
            read -p "请输入阿里云 Access Key ID: " ALI_KEY
            read -p "请输入阿里云 Access Key Secret: " ALI_SECRET
            export Ali_Key="$ALI_KEY"
            export Ali_Secret="$ALI_SECRET"
            ;;
        3)
            DNS_PROVIDER="dns_tencent"
            echo
            read -p "请输入腾讯云 Secret ID: " TENCENT_ID
            read -p "请输入腾讯云 Secret Key: " TENCENT_KEY
            export Tencent_SecretId="$TENCENT_ID"
            export Tencent_SecretKey="$TENCENT_KEY"
            ;;
        4)
            DNS_PROVIDER="dns_aws"
            echo
            read -p "请输入 AWS Access Key ID: " AWS_KEY
            read -p "请输入 AWS Secret Access Key: " AWS_SECRET
            export AWS_ACCESS_KEY_ID="$AWS_KEY"
            export AWS_SECRET_ACCESS_KEY="$AWS_SECRET"
            ;;
        5)
            echo "请参考 acme.sh 文档配置其他 DNS 提供商"
            exit 1
            ;;
        *)
            log_error "无效选择"
            configure_dns_provider
            ;;
    esac
}

# 申请证书
issue_certificate() {
    log_info "申请证书..."
    
    # 构建 acme.sh 命令
    local acme_cmd="$ACME_HOME/acme.sh --issue"
    
    # 添加域名
    acme_cmd="$acme_cmd -d $DOMAIN -d *.$DOMAIN"
    
    # 添加 DNS 验证
    acme_cmd="$acme_cmd --dns $DNS_PROVIDER"
    
    # 选择服务器
    if [[ "$CERT_MODE" == "staging" ]]; then
        acme_cmd="$acme_cmd --server letsencrypt_test"
        log_info "使用 Let's Encrypt Staging 服务器（测试证书）"
    else
        acme_cmd="$acme_cmd --server letsencrypt"
        log_info "使用 Let's Encrypt 生产服务器"
    fi
    
    # 执行命令
    if eval "$acme_cmd"; then
        log_success "证书申请成功"
        
        # 安装证书到指定目录
        install_certificate
    else
        log_error "证书申请失败"
        return 1
    fi
}

# 安装证书
install_certificate() {
    local cert_dir="/opt/matrix/certs"
    mkdir -p "$cert_dir"
    
    log_info "安装证书到 $cert_dir"
    
    "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" \
        --key-file "$cert_dir/privkey.pem" \
        --fullchain-file "$cert_dir/fullchain.pem" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || true"
    
    # 设置权限
    chmod 600 "$cert_dir/privkey.pem"
    chmod 644 "$cert_dir/fullchain.pem"
    
    log_success "证书安装完成"
    log_info "私钥: $cert_dir/privkey.pem"
    log_info "证书链: $cert_dir/fullchain.pem"
}

# 续期证书
renew_certificate() {
    log_info "续期证书..."
    
    if "$ACME_HOME/acme.sh" --renew -d "$DOMAIN" --force; then
        log_success "证书续期成功"
        install_certificate
    else
        log_error "证书续期失败"
        return 1
    fi
}

# 撤销证书
revoke_certificate() {
    echo -e "${RED}警告：此操作将撤销证书，撤销后无法恢复！${NC}"
    read -p "确认撤销证书 $DOMAIN? 输入 'revoke' 确认: " confirm
    
    if [[ "$confirm" != "revoke" ]]; then
        log_info "操作已取消"
        return 0
    fi
    
    log_info "撤销证书..."
    
    if "$ACME_HOME/acme.sh" --revoke -d "$DOMAIN"; then
        log_success "证书撤销成功"
        
        # 删除本地证书文件
        rm -rf "$ACME_HOME/$DOMAIN"
        rm -f "/opt/matrix/certs/privkey.pem"
        rm -f "/opt/matrix/certs/fullchain.pem"
        
        log_info "本地证书文件已删除"
    else
        log_error "证书撤销失败"
        return 1
    fi
}

# 列出证书
list_certificates() {
    log_info "已申请的证书列表："
    echo
    
    "$ACME_HOME/acme.sh" --list
}

# 查看证书信息
show_certificate_info() {
    if [[ -f "/opt/matrix/certs/fullchain.pem" ]]; then
        log_info "证书信息："
        echo
        openssl x509 -in "/opt/matrix/certs/fullchain.pem" -text -noout | grep -E "(Subject:|Issuer:|Not Before:|Not After:|DNS:)"
    else
        log_warning "未找到证书文件"
    fi
}

# 备份证书
backup_certificates() {
    local backup_dir="/opt/matrix/cert-backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    log_info "备份证书到 $backup_dir"
    
    # 备份 acme.sh 目录
    if [[ -d "$ACME_HOME" ]]; then
        cp -r "$ACME_HOME" "$backup_dir/"
    fi
    
    # 备份已安装的证书
    if [[ -d "/opt/matrix/certs" ]]; then
        cp -r "/opt/matrix/certs" "$backup_dir/"
    fi
    
    # 创建备份信息文件
    cat > "$backup_dir/backup_info.txt" << EOF
备份时间: $(date)
域名: $DOMAIN
证书模式: $CERT_MODE
DNS提供商: $DNS_PROVIDER
EOF
    
    log_success "证书备份完成: $backup_dir"
}

# 恢复证书
restore_certificates() {
    echo
    log_info "可用的备份："
    ls -la /opt/matrix/cert-backup/ 2>/dev/null || {
        log_warning "未找到备份文件"
        return 1
    }
    
    echo
    read -p "请输入要恢复的备份目录名: " backup_name
    
    local backup_path="/opt/matrix/cert-backup/$backup_name"
    if [[ ! -d "$backup_path" ]]; then
        log_error "备份目录不存在: $backup_path"
        return 1
    fi
    
    log_info "恢复证书从 $backup_path"
    
    # 恢复 acme.sh 目录
    if [[ -d "$backup_path/.acme.sh" ]]; then
        rm -rf "$ACME_HOME"
        cp -r "$backup_path/.acme.sh" "$ACME_HOME"
    fi
    
    # 恢复已安装的证书
    if [[ -d "$backup_path/certs" ]]; then
        rm -rf "/opt/matrix/certs"
        cp -r "$backup_path/certs" "/opt/matrix/certs"
    fi
    
    log_success "证书恢复完成"
}

# 显示主菜单
show_main_menu() {
    echo -e "${CYAN}请选择操作：${NC}"
    echo
    echo "1) 🔐 申请新证书"
    echo "2) 🔄 续期证书"
    echo "3) 🗑️ 撤销证书"
    echo "4) 📋 列出证书"
    echo "5) 📊 查看证书信息"
    echo "6) 💾 备份证书"
    echo "7) 📤 恢复证书"
    echo "8) ⚙️ 配置 DNS 提供商"
    echo "9) 🧪 切换证书模式"
    echo "0) 🚪 退出"
    echo
    read -p "请选择 [0-9]: " choice
    
    case $choice in
        1) 
            read -p "请输入域名: " DOMAIN
            read -p "请输入邮箱: " EMAIL
            configure_dns_provider
            issue_certificate
            ;;
        2) 
            read -p "请输入域名: " DOMAIN
            renew_certificate
            ;;
        3) 
            read -p "请输入域名: " DOMAIN
            revoke_certificate
            ;;
        4) list_certificates ;;
        5) show_certificate_info ;;
        6) backup_certificates ;;
        7) restore_certificates ;;
        8) configure_dns_provider ;;
        9) 
            echo -e "${CYAN}当前模式: $CERT_MODE${NC}"
            echo "1) 生产模式 (production)"
            echo "2) 测试模式 (staging)"
            read -p "请选择 [1-2]: " mode_choice
            case $mode_choice in
                1) CERT_MODE="production"; log_success "已切换到生产模式" ;;
                2) CERT_MODE="staging"; log_success "已切换到测试模式" ;;
                *) log_error "无效选择" ;;
            esac
            ;;
        0) exit 0 ;;
        *) log_error "无效选项，请重新选择" ;;
    esac
    
    echo
    read -p "按回车键继续..."
    show_main_menu
}

# 主函数
main() {
    show_banner
    
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        exit 1
    fi
    
    # 检查 acme.sh 安装
    check_acme_installation
    
    # 显示主菜单
    show_main_menu
}

# 运行主函数
main "$@"

