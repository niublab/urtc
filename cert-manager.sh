#!/bin/bash
# 独立证书管理脚本
# 支持Let's Encrypt生产和测试证书的申请、更新和撤销
# 基于cert-manager和acme.sh双重支持

set -euo pipefail

# 脚本信息
CERT_SCRIPT_VERSION="1.0"
CERT_SCRIPT_NAME="Matrix Certificate Management Script"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 路径定义
MATRIX_HOME="/opt/matrix"
MATRIX_CONFIG="$MATRIX_HOME/config"
MATRIX_SSL="$MATRIX_HOME/ssl"
ENV_FILE="$MATRIX_HOME/.env"
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

# 日志函数
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# 加载环境变量
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        source "$ENV_FILE"
        set +a
    else
        error "环境配置文件不存在: $ENV_FILE"
        exit 1
    fi
}

# 获取环境变量
get_env() {
    local key="$1"
    local default="$2"
    
    if [[ -f "$ENV_FILE" ]] && grep -q "^$key=" "$ENV_FILE"; then
        grep "^$key=" "$ENV_FILE" | cut -d'=' -f2-
    else
        echo "$default"
    fi
}

# 检查依赖
check_dependencies() {
    log "检查依赖..."
    
    # 检查kubectl
    if ! command -v kubectl &> /dev/null; then
        error "kubectl未安装或不在PATH中"
        exit 1
    fi
    
    # 检查K3s是否运行
    if ! kubectl get nodes &>/dev/null; then
        error "无法连接到Kubernetes集群"
        exit 1
    fi
    
    # 检查cert-manager
    if ! kubectl get namespace cert-manager &>/dev/null; then
        warn "cert-manager未安装，某些功能可能不可用"
    fi
    
    log "依赖检查完成"
}

# 安装acme.sh
install_acme_sh() {
    log "安装acme.sh..."
    
    if [[ -d ~/.acme.sh ]]; then
        log "acme.sh已安装，跳过安装"
        return 0
    fi
    
    # 下载并安装acme.sh
    curl https://get.acme.sh | sh -s email=$(get_env "ADMIN_USERNAME" "admin")@$(get_env "DOMAIN_NAME" "example.com")
    
    # 重新加载环境
    source ~/.bashrc
    
    log "acme.sh安装完成"
}

# 配置acme.sh Cloudflare API
configure_acme_cloudflare() {
    log "配置acme.sh Cloudflare API..."
    
    local cf_token=$(get_env "CLOUDFLARE_API_TOKEN" "")
    
    if [[ -z "$cf_token" ]]; then
        error "Cloudflare API Token未配置"
        exit 1
    fi
    
    # 设置Cloudflare API Token
    export CF_Token="$cf_token"
    
    # 保存到acme.sh配置
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    
    log "acme.sh Cloudflare配置完成"
}

# 使用acme.sh申请证书
issue_cert_acme() {
    local domain="$1"
    local cert_type="$2"  # production 或 staging
    
    log "使用acme.sh申请证书: $domain ($cert_type)"
    
    # 设置ACME服务器
    local acme_server=""
    case $cert_type in
        "production")
            acme_server="letsencrypt"
            ;;
        "staging")
            acme_server="letsencrypt_test"
            ;;
        *)
            error "无效的证书类型: $cert_type"
            return 1
            ;;
    esac
    
    # 生成子域名列表
    local subdomains=(
        "$(get_env "APP_SUBDOMAIN" "app").$domain"
        "$(get_env "LIVE_SUBDOMAIN" "live").$domain"
        "$(get_env "MAS_SUBDOMAIN" "mas").$domain"
        "$(get_env "RTC_SUBDOMAIN" "rtc").$domain"
        "$(get_env "JWT_SUBDOMAIN" "jwt").$domain"
        "$(get_env "MATRIX_SUBDOMAIN" "matrix").$domain"
    )
    
    # 构建域名参数
    local domain_args="-d $domain"
    for subdomain in "${subdomains[@]}"; do
        domain_args="$domain_args -d $subdomain"
    done
    
    # 申请证书
    ~/.acme.sh/acme.sh --issue \
        $domain_args \
        --dns dns_cf \
        --server $acme_server \
        --force
    
    if [[ $? -eq 0 ]]; then
        log "证书申请成功: $domain"
        
        # 安装证书到指定目录
        install_cert_acme "$domain"
    else
        error "证书申请失败: $domain"
        return 1
    fi
}

# 安装acme.sh证书
install_cert_acme() {
    local domain="$1"
    
    log "安装证书: $domain"
    
    # 创建证书目录
    mkdir -p "$MATRIX_SSL/$domain"
    
    # 安装证书
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file "$MATRIX_SSL/$domain/key.pem" \
        --fullchain-file "$MATRIX_SSL/$domain/fullchain.pem" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || true"
    
    # 设置权限
    chmod 600 "$MATRIX_SSL/$domain/key.pem"
    chmod 644 "$MATRIX_SSL/$domain/fullchain.pem"
    
    log "证书安装完成: $domain"
}

# 续期acme.sh证书
renew_cert_acme() {
    local domain="$1"
    
    log "续期证书: $domain"
    
    ~/.acme.sh/acme.sh --renew -d "$domain" --force
    
    if [[ $? -eq 0 ]]; then
        log "证书续期成功: $domain"
        install_cert_acme "$domain"
    else
        error "证书续期失败: $domain"
        return 1
    fi
}

# 撤销acme.sh证书
revoke_cert_acme() {
    local domain="$1"
    
    log "撤销证书: $domain"
    
    read -p "确认撤销证书 $domain? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "操作已取消"
        return 0
    fi
    
    ~/.acme.sh/acme.sh --revoke -d "$domain"
    
    if [[ $? -eq 0 ]]; then
        log "证书撤销成功: $domain"
        
        # 删除本地证书文件
        rm -rf "$MATRIX_SSL/$domain"
        
        # 删除acme.sh证书记录
        ~/.acme.sh/acme.sh --remove -d "$domain"
    else
        error "证书撤销失败: $domain"
        return 1
    fi
}

# 列出acme.sh证书
list_certs_acme() {
    log "acme.sh证书列表:"
    
    if [[ -d ~/.acme.sh ]]; then
        ~/.acme.sh/acme.sh --list
    else
        warn "acme.sh未安装"
    fi
}

# 查看cert-manager证书状态
check_cert_manager_status() {
    log "cert-manager证书状态:"
    
    if kubectl get namespace cert-manager &>/dev/null; then
        echo
        echo "ClusterIssuer状态:"
        kubectl get clusterissuer
        
        echo
        echo "Certificate状态:"
        kubectl get certificates -A
        
        echo
        echo "CertificateRequest状态:"
        kubectl get certificaterequests -A
        
        echo
        echo "Challenge状态:"
        kubectl get challenges -A 2>/dev/null || echo "无活动的Challenge"
    else
        warn "cert-manager未安装"
    fi
}

# 强制续期cert-manager证书
force_renew_cert_manager() {
    local namespace="$1"
    local cert_name="$2"
    
    log "强制续期cert-manager证书: $cert_name"
    
    # 删除证书，触发重新申请
    kubectl delete certificate "$cert_name" -n "$namespace"
    
    log "证书已删除，将自动重新申请"
}

# 切换证书类型
switch_cert_type() {
    echo
    echo "当前证书类型: $(get_env "CERT_TYPE" "production")"
    echo "1) 切换到生产证书 (Let's Encrypt)"
    echo "2) 切换到测试证书 (Let's Encrypt Staging)"
    echo "0) 取消"
    
    read -p "请选择 [0-2]: " choice
    
    case $choice in
        1)
            # 更新环境变量
            sed -i 's/^CERT_TYPE=.*/CERT_TYPE=production/' "$ENV_FILE"
            sed -i 's|^ACME_SERVER=.*|ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory|' "$ENV_FILE"
            
            # 更新cert-manager ClusterIssuer
            update_cluster_issuer "https://acme-v02.api.letsencrypt.org/directory"
            
            log "已切换到生产证书模式"
            ;;
        2)
            # 更新环境变量
            sed -i 's/^CERT_TYPE=.*/CERT_TYPE=staging/' "$ENV_FILE"
            sed -i 's|^ACME_SERVER=.*|ACME_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory|' "$ENV_FILE"
            
            # 更新cert-manager ClusterIssuer
            update_cluster_issuer "https://acme-staging-v02.api.letsencrypt.org/directory"
            
            log "已切换到测试证书模式"
            ;;
        0)
            log "操作已取消"
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

# 更新ClusterIssuer
update_cluster_issuer() {
    local acme_server="$1"
    
    log "更新ClusterIssuer配置..."
    
    local admin_email=$(get_env "ADMIN_USERNAME" "admin")@$(get_env "DOMAIN_NAME" "example.com")
    
    cat > "$MATRIX_CONFIG/cluster-issuer.yaml" << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-issuer
spec:
  acme:
    server: $acme_server
    email: $admin_email
    privateKeySecretRef:
      name: letsencrypt-issuer
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token-secret
            key: api-token
EOF
    
    kubectl apply -f "$MATRIX_CONFIG/cluster-issuer.yaml"
    
    log "ClusterIssuer配置已更新"
}

# 证书信息查看
view_cert_info() {
    local cert_file="$1"
    
    if [[ ! -f "$cert_file" ]]; then
        error "证书文件不存在: $cert_file"
        return 1
    fi
    
    log "证书信息: $cert_file"
    
    # 显示证书详细信息
    openssl x509 -in "$cert_file" -text -noout | grep -E "(Subject:|Issuer:|Not Before:|Not After :|DNS:)"
    
    # 检查证书有效期
    local expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
    local expiry_timestamp=$(date -d "$expiry_date" +%s)
    local current_timestamp=$(date +%s)
    local days_left=$(( (expiry_timestamp - current_timestamp) / 86400 ))
    
    echo
    if [[ $days_left -gt 30 ]]; then
        log "证书有效期剩余: $days_left 天"
    elif [[ $days_left -gt 7 ]]; then
        warn "证书有效期剩余: $days_left 天 (建议续期)"
    else
        error "证书有效期剩余: $days_left 天 (需要立即续期)"
    fi
}

# 批量证书操作
batch_cert_operations() {
    echo
    echo "批量证书操作:"
    echo "1) 批量申请所有域名证书"
    echo "2) 批量续期所有证书"
    echo "3) 批量检查证书状态"
    echo "0) 返回"
    
    read -p "请选择 [0-3]: " choice
    
    load_env
    local domain=$(get_env "DOMAIN_NAME" "example.com")
    local cert_type=$(get_env "CERT_TYPE" "production")
    
    case $choice in
        1)
            log "批量申请证书..."
            issue_cert_acme "$domain" "$cert_type"
            ;;
        2)
            log "批量续期证书..."
            ~/.acme.sh/acme.sh --renew-all --force
            ;;
        3)
            log "批量检查证书状态..."
            list_certs_acme
            check_cert_manager_status
            
            # 检查本地证书文件
            if [[ -d "$MATRIX_SSL" ]]; then
                echo
                log "本地证书文件:"
                find "$MATRIX_SSL" -name "*.pem" -exec echo "检查: {}" \; -exec view_cert_info {} \;
            fi
            ;;
        0)
            return
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

# 证书备份和恢复
cert_backup_restore() {
    echo
    echo "证书备份和恢复:"
    echo "1) 备份所有证书"
    echo "2) 恢复证书备份"
    echo "3) 查看备份列表"
    echo "0) 返回"
    
    read -p "请选择 [0-3]: " choice
    
    case $choice in
        1)
            log "备份证书..."
            local backup_date=$(date +"%Y%m%d_%H%M%S")
            local backup_dir="$MATRIX_HOME/backup/certs_$backup_date"
            
            mkdir -p "$backup_dir"
            
            # 备份acme.sh证书
            if [[ -d ~/.acme.sh ]]; then
                cp -r ~/.acme.sh "$backup_dir/"
            fi
            
            # 备份本地证书文件
            if [[ -d "$MATRIX_SSL" ]]; then
                cp -r "$MATRIX_SSL" "$backup_dir/"
            fi
            
            # 备份cert-manager配置
            kubectl get clusterissuer -o yaml > "$backup_dir/clusterissuer.yaml" 2>/dev/null || true
            kubectl get certificates -A -o yaml > "$backup_dir/certificates.yaml" 2>/dev/null || true
            
            # 压缩备份
            cd "$MATRIX_HOME/backup"
            tar czf "certs_$backup_date.tar.gz" "certs_$backup_date"
            rm -rf "certs_$backup_date"
            
            log "证书备份完成: certs_$backup_date.tar.gz"
            ;;
        2)
            log "可用证书备份:"
            ls -la "$MATRIX_HOME/backup"/certs_*.tar.gz 2>/dev/null | awk '{print $9, $5, $6, $7, $8}' || echo "无备份文件"
            
            echo
            read -p "请输入要恢复的备份文件名 (不含.tar.gz): " backup_name
            
            local backup_file="$MATRIX_HOME/backup/${backup_name}.tar.gz"
            if [[ -f "$backup_file" ]]; then
                read -p "确认恢复备份 $backup_name? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    cd "$MATRIX_HOME/backup"
                    tar xzf "$backup_file"
                    
                    # 恢复acme.sh
                    if [[ -d "${backup_name}/.acme.sh" ]]; then
                        cp -r "${backup_name}/.acme.sh" ~/
                    fi
                    
                    # 恢复本地证书
                    if [[ -d "${backup_name}/ssl" ]]; then
                        cp -r "${backup_name}/ssl" "$MATRIX_HOME/"
                    fi
                    
                    rm -rf "$backup_name"
                    log "证书恢复完成"
                fi
            else
                error "备份文件不存在"
            fi
            ;;
        3)
            log "证书备份列表:"
            ls -la "$MATRIX_HOME/backup"/certs_*.tar.gz 2>/dev/null | awk '{print $9, $5, $6, $7, $8}' | column -t || echo "无备份文件"
            ;;
        0)
            return
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

# 主菜单
main_menu() {
    while true; do
        echo
        echo "=================================="
        echo "$CERT_SCRIPT_NAME v$CERT_SCRIPT_VERSION"
        echo "=================================="
        echo "1) 安装和配置acme.sh"
        echo "2) 申请证书 (acme.sh)"
        echo "3) 续期证书 (acme.sh)"
        echo "4) 撤销证书 (acme.sh)"
        echo "5) 查看证书列表"
        echo "6) 检查cert-manager状态"
        echo "7) 强制续期cert-manager证书"
        echo "8) 切换证书类型"
        echo "9) 查看证书详细信息"
        echo "10) 批量证书操作"
        echo "11) 证书备份和恢复"
        echo "0) 退出"
        echo
        
        read -p "请选择操作 [0-11]: " choice
        
        case $choice in
            1)
                install_acme_sh
                configure_acme_cloudflare
                ;;
            2)
                load_env
                local domain=$(get_env "DOMAIN_NAME" "example.com")
                local cert_type=$(get_env "CERT_TYPE" "production")
                
                echo
                read -p "请输入域名 [默认: $domain]: " input_domain
                domain=${input_domain:-$domain}
                
                echo "1) 生产证书"
                echo "2) 测试证书"
                read -p "请选择证书类型 [1-2]: " type_choice
                
                case $type_choice in
                    1) cert_type="production" ;;
                    2) cert_type="staging" ;;
                    *) cert_type="production" ;;
                esac
                
                issue_cert_acme "$domain" "$cert_type"
                ;;
            3)
                echo
                read -p "请输入要续期的域名: " domain
                renew_cert_acme "$domain"
                ;;
            4)
                echo
                read -p "请输入要撤销的域名: " domain
                revoke_cert_acme "$domain"
                ;;
            5)
                list_certs_acme
                ;;
            6)
                check_cert_manager_status
                ;;
            7)
                echo
                kubectl get certificates -A --no-headers | awk '{print NR") "$2" (namespace: "$1")'
                read -p "请输入证书编号: " cert_num
                
                cert_info=$(kubectl get certificates -A --no-headers | sed -n "${cert_num}p")
                if [[ -n "$cert_info" ]]; then
                    namespace=$(echo "$cert_info" | awk '{print $1}')
                    cert_name=$(echo "$cert_info" | awk '{print $2}')
                    force_renew_cert_manager "$namespace" "$cert_name"
                else
                    error "无效的证书编号"
                fi
                ;;
            8)
                switch_cert_type
                ;;
            9)
                echo
                echo "选择证书文件:"
                if [[ -d "$MATRIX_SSL" ]]; then
                    find "$MATRIX_SSL" -name "*.pem" | nl
                    read -p "请输入文件编号: " file_num
                    cert_file=$(find "$MATRIX_SSL" -name "*.pem" | sed -n "${file_num}p")
                    if [[ -n "$cert_file" ]]; then
                        view_cert_info "$cert_file"
                    else
                        error "无效的文件编号"
                    fi
                else
                    warn "证书目录不存在"
                fi
                ;;
            10)
                batch_cert_operations
                ;;
            11)
                cert_backup_restore
                ;;
            0)
                log "感谢使用证书管理脚本！"
                exit 0
                ;;
            *)
                error "无效选择，请重新输入"
                ;;
        esac
    done
}

# 主程序入口
main() {
    # 检查依赖
    check_dependencies
    
    # 加载环境变量
    load_env
    
    # 显示欢迎信息
    echo
    echo "=================================="
    echo "$CERT_SCRIPT_NAME v$CERT_SCRIPT_VERSION"
    echo "支持Let's Encrypt生产和测试证书"
    echo "基于cert-manager和acme.sh"
    echo "=================================="
    
    # 进入主菜单
    main_menu
}

# 启动主程序
main "$@"

