#!/bin/bash
# Matrix Stack 完整部署和管理脚本
# 基于 Element Server Suite (ESS) Community Edition
# 支持动态IP环境和内网部署
# 版本: 2.0 Enhanced

set -euo pipefail

# 脚本信息
SCRIPT_VERSION="2.0"
SCRIPT_NAME="Matrix Stack Deployment Script"
SCRIPT_AUTHOR="Enhanced by AI Assistant"
SCRIPT_DATE=$(date +"%Y-%m-%d")

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 路径定义
MATRIX_HOME="/opt/matrix"
MATRIX_DATA="$MATRIX_HOME/data"
MATRIX_CONFIG="$MATRIX_HOME/config"
MATRIX_BACKUP="$MATRIX_HOME/backup"
MATRIX_SSL="$MATRIX_HOME/ssl"
MATRIX_LOGS="$MATRIX_HOME/logs"
ENV_FILE="$MATRIX_HOME/.env"
VALUES_FILE="$MATRIX_CONFIG/values.yaml"
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

# 默认配置
DEFAULT_HTTP_PORT="8080"
DEFAULT_HTTPS_PORT="8443"
DEFAULT_FEDERATION_PORT="8448"
DEFAULT_NAMESPACE="ess"
DEFAULT_RELEASE_NAME="matrix-stack"

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

# 检查是否为root用户
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "此脚本不应以root用户运行，请使用普通用户"
        exit 1
    fi
}

# 检查系统要求
check_system_requirements() {
    log "检查系统要求..."
    
    # 检查操作系统
    if ! grep -q "Debian\|Ubuntu" /etc/os-release; then
        error "此脚本仅支持 Debian/Ubuntu 系统"
        exit 1
    fi
    
    # 检查内存
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $mem_gb -lt 6 ]]; then
        warn "系统内存少于6GB，可能影响性能"
    fi
    
    # 检查磁盘空间
    local disk_gb=$(df -BG / | awk 'NR==2{print $4}' | sed 's/G//')
    if [[ $disk_gb -lt 50 ]]; then
        warn "根分区可用空间少于50GB，可能影响运行"
    fi
    
    # 检查网络连接
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        error "无法连接到互联网，请检查网络配置"
        exit 1
    fi
    
    log "系统要求检查完成"
}

# 安装必要的软件包
install_dependencies() {
    log "安装必要的软件包..."
    
    sudo apt-get update
    sudo apt-get install -y \
        curl \
        wget \
        git \
        jq \
        openssl \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        unzip \
        htop \
        tree \
        nano \
        vim
    
    log "软件包安装完成"
}

# 创建目录结构
create_directories() {
    log "创建目录结构..."
    
    sudo mkdir -p "$MATRIX_HOME" "$MATRIX_DATA" "$MATRIX_CONFIG" "$MATRIX_BACKUP" "$MATRIX_SSL" "$MATRIX_LOGS"
    sudo chown -R $USER:$USER "$MATRIX_HOME"
    chmod 755 "$MATRIX_HOME"
    
    log "目录结构创建完成"
}

# 生成随机密钥
generate_secret() {
    local length=${1:-32}
    openssl rand -hex $length
}

# 生成强密码
generate_password() {
    local length=${1:-16}
    openssl rand -base64 $length | tr -d "=+/" | cut -c1-$length
}

# 加载环境变量
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        source "$ENV_FILE"
        set +a
    fi
}

# 保存环境变量
save_env() {
    local key="$1"
    local value="$2"
    
    if [[ -f "$ENV_FILE" ]]; then
        if grep -q "^$key=" "$ENV_FILE"; then
            sed -i "s/^$key=.*/$key=$value/" "$ENV_FILE"
        else
            echo "$key=$value" >> "$ENV_FILE"
        fi
    else
        echo "$key=$value" > "$ENV_FILE"
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

# 验证域名格式
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# 验证端口号
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        return 1
    fi
    return 0
}

# 检查端口是否被占用
check_port() {
    local port="$1"
    if netstat -tuln | grep -q ":$port "; then
        return 1
    fi
    return 0
}

# 配置向导
configuration_wizard() {
    log "开始配置向导..."
    
    # 域名配置
    while true; do
        read -p "请输入您的主域名 (例如: example.com): " domain
        if validate_domain "$domain"; then
            save_env "DOMAIN_NAME" "$domain"
            break
        else
            error "域名格式无效，请重新输入"
        fi
    done
    
    # Cloudflare API配置
    read -p "请输入Cloudflare API Token (用于DNS验证): " cf_token
    save_env "CLOUDFLARE_API_TOKEN" "$cf_token"
    
    # 管理员账户配置
    read -p "请输入管理员用户名: " admin_user
    save_env "ADMIN_USERNAME" "$admin_user"
    
    read -s -p "请输入管理员密码 (留空自动生成): " admin_pass
    echo
    if [[ -z "$admin_pass" ]]; then
        admin_pass=$(generate_password 16)
        log "自动生成管理员密码: $admin_pass"
    fi
    save_env "ADMIN_PASSWORD" "$admin_pass"
    
    # 端口配置
    read -p "HTTP端口 (默认$DEFAULT_HTTP_PORT): " http_port
    http_port=${http_port:-$DEFAULT_HTTP_PORT}
    if validate_port "$http_port"; then
        save_env "HTTP_PORT" "$http_port"
    else
        error "端口号无效，使用默认值"
        save_env "HTTP_PORT" "$DEFAULT_HTTP_PORT"
    fi
    
    read -p "HTTPS端口 (默认$DEFAULT_HTTPS_PORT): " https_port
    https_port=${https_port:-$DEFAULT_HTTPS_PORT}
    if validate_port "$https_port"; then
        save_env "HTTPS_PORT" "$https_port"
    else
        error "端口号无效，使用默认值"
        save_env "HTTPS_PORT" "$DEFAULT_HTTPS_PORT"
    fi
    
    read -p "联邦端口 (默认$DEFAULT_FEDERATION_PORT): " fed_port
    fed_port=${fed_port:-$DEFAULT_FEDERATION_PORT}
    if validate_port "$fed_port"; then
        save_env "FEDERATION_PORT" "$fed_port"
    else
        error "端口号无效，使用默认值"
        save_env "FEDERATION_PORT" "$DEFAULT_FEDERATION_PORT"
    fi
    
    # 子域名配置
    echo
    log "配置子域名前缀 (直接回车使用默认值):"
    
    read -p "Element Web子域名前缀 (默认: app): " app_subdomain
    save_env "APP_SUBDOMAIN" "${app_subdomain:-app}"
    
    read -p "LiveKit子域名前缀 (默认: live): " live_subdomain
    save_env "LIVE_SUBDOMAIN" "${live_subdomain:-live}"
    
    read -p "MAS子域名前缀 (默认: mas): " mas_subdomain
    save_env "MAS_SUBDOMAIN" "${mas_subdomain:-mas}"
    
    read -p "RTC子域名前缀 (默认: rtc): " rtc_subdomain
    save_env "RTC_SUBDOMAIN" "${rtc_subdomain:-rtc}"
    
    read -p "JWT服务子域名前缀 (默认: jwt): " jwt_subdomain
    save_env "JWT_SUBDOMAIN" "${jwt_subdomain:-jwt}"
    
    read -p "Matrix联邦子域名前缀 (默认: matrix): " matrix_subdomain
    save_env "MATRIX_SUBDOMAIN" "${matrix_subdomain:-matrix}"
    
    # 高可用配置
    echo
    log "选择部署模式:"
    echo "1) 开发调试部署 (所有服务单副本)"
    echo "2) 测试环境部署 (关键服务多副本)"
    echo "3) 生产环境部署 (所有服务多副本)"
    echo "4) 自定义配置"
    
    read -p "请选择 [1-4]: " deploy_mode
    case $deploy_mode in
        1)
            save_env "DEPLOY_MODE" "development"
            save_env "SYNAPSE_REPLICAS" "1"
            save_env "ELEMENT_REPLICAS" "1"
            save_env "HAPROXY_REPLICAS" "1"
            save_env "MAS_REPLICAS" "1"
            save_env "LIVEKIT_REPLICAS" "1"
            ;;
        2)
            save_env "DEPLOY_MODE" "testing"
            save_env "SYNAPSE_REPLICAS" "2"
            save_env "ELEMENT_REPLICAS" "2"
            save_env "HAPROXY_REPLICAS" "2"
            save_env "MAS_REPLICAS" "1"
            save_env "LIVEKIT_REPLICAS" "2"
            ;;
        3)
            save_env "DEPLOY_MODE" "production"
            save_env "SYNAPSE_REPLICAS" "2"
            save_env "ELEMENT_REPLICAS" "2"
            save_env "HAPROXY_REPLICAS" "2"
            save_env "MAS_REPLICAS" "2"
            save_env "LIVEKIT_REPLICAS" "2"
            ;;
        4)
            read -p "Synapse副本数 (默认1): " synapse_replicas
            save_env "SYNAPSE_REPLICAS" "${synapse_replicas:-1}"
            
            read -p "Element Web副本数 (默认1): " element_replicas
            save_env "ELEMENT_REPLICAS" "${element_replicas:-1}"
            
            read -p "HAProxy副本数 (默认1): " haproxy_replicas
            save_env "HAPROXY_REPLICAS" "${haproxy_replicas:-1}"
            
            read -p "MAS副本数 (默认1): " mas_replicas
            save_env "MAS_REPLICAS" "${mas_replicas:-1}"
            
            read -p "LiveKit副本数 (默认1): " livekit_replicas
            save_env "LIVEKIT_REPLICAS" "${livekit_replicas:-1}"
            
            save_env "DEPLOY_MODE" "custom"
            ;;
        *)
            warn "无效选择，使用测试环境配置"
            save_env "DEPLOY_MODE" "testing"
            save_env "SYNAPSE_REPLICAS" "2"
            save_env "ELEMENT_REPLICAS" "2"
            save_env "HAPROXY_REPLICAS" "2"
            save_env "MAS_REPLICAS" "1"
            save_env "LIVEKIT_REPLICAS" "2"
            ;;
    esac
    
    # 证书配置
    echo
    log "选择证书类型:"
    echo "1) Let's Encrypt 生产证书 (推荐)"
    echo "2) Let's Encrypt 测试证书 (staging)"
    
    read -p "请选择 [1-2]: " cert_type
    case $cert_type in
        1)
            save_env "CERT_TYPE" "production"
            save_env "ACME_SERVER" "https://acme-v02.api.letsencrypt.org/directory"
            ;;
        2)
            save_env "CERT_TYPE" "staging"
            save_env "ACME_SERVER" "https://acme-staging-v02.api.letsencrypt.org/directory"
            ;;
        *)
            warn "无效选择，使用生产证书"
            save_env "CERT_TYPE" "production"
            save_env "ACME_SERVER" "https://acme-v02.api.letsencrypt.org/directory"
            ;;
    esac
    
    # 生成密钥
    log "生成系统密钥..."
    save_env "DATABASE_PASSWORD" "$(generate_secret 32)"
    save_env "LIVEKIT_API_KEY" "$(generate_secret 16)"
    save_env "LIVEKIT_SECRET_KEY" "$(generate_secret 32)"
    save_env "JWT_SECRET" "$(generate_secret 32)"
    save_env "SYNAPSE_MACAROON_SECRET" "$(generate_secret 32)"
    save_env "SYNAPSE_REGISTRATION_SHARED_SECRET" "$(generate_secret 32)"
    save_env "MAS_ENCRYPTION_SECRET" "$(generate_secret 32)"
    
    # 生成Synapse签名密钥
    local signing_key="ed25519 $(openssl rand -base64 32)"
    save_env "SYNAPSE_SIGNING_KEY" "$signing_key"
    
    log "配置向导完成"
}

# 安装K3s
install_k3s() {
    log "安装K3s..."
    
    if command -v k3s &> /dev/null; then
        log "K3s已安装，跳过安装步骤"
        return 0
    fi
    
    # 下载并安装K3s
    curl -sfL https://get.k3s.io | sh -s - \
        --write-kubeconfig-mode 644 \
        --disable traefik \
        --disable servicelb \
        --node-port-range=30000-32767
    
    # 等待K3s启动
    log "等待K3s启动..."
    local timeout=60
    local count=0
    while ! kubectl get nodes &>/dev/null; do
        if [[ $count -ge $timeout ]]; then
            error "K3s启动超时"
            exit 1
        fi
        sleep 5
        ((count+=5))
    done
    
    # 配置kubectl
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $USER:$USER ~/.kube/config
    
    log "K3s安装完成"
}

# 安装Helm
install_helm() {
    log "安装Helm..."
    
    if command -v helm &> /dev/null; then
        log "Helm已安装，跳过安装步骤"
        return 0
    fi
    
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    log "Helm安装完成"
}

# 安装cert-manager
install_cert_manager() {
    log "安装cert-manager..."
    
    # 检查是否已安装
    if kubectl get namespace cert-manager &>/dev/null; then
        log "cert-manager已安装，跳过安装步骤"
        return 0
    fi
    
    # 添加Helm仓库
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    # 安装cert-manager
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.13.0 \
        --set installCRDs=true
    
    # 等待cert-manager启动
    log "等待cert-manager启动..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
    
    log "cert-manager安装完成"
}

# 配置cert-manager ClusterIssuer
configure_cert_manager() {
    log "配置cert-manager..."
    
    load_env
    
    local acme_server=$(get_env "ACME_SERVER" "https://acme-v02.api.letsencrypt.org/directory")
    local cf_token=$(get_env "CLOUDFLARE_API_TOKEN" "")
    local admin_email=$(get_env "ADMIN_USERNAME" "admin")@$(get_env "DOMAIN_NAME" "example.com")
    
    if [[ -z "$cf_token" ]]; then
        error "Cloudflare API Token未配置"
        exit 1
    fi
    
    # 创建Cloudflare API Token Secret
    kubectl create secret generic cloudflare-api-token-secret \
        --from-literal=api-token="$cf_token" \
        --namespace cert-manager \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # 创建ClusterIssuer
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
    
    log "cert-manager配置完成"
}

# 生成MAS配置
generate_mas_config() {
    log "生成MAS配置..."
    
    load_env
    
    local domain=$(get_env "DOMAIN_NAME" "example.com")
    local mas_subdomain=$(get_env "MAS_SUBDOMAIN" "mas")
    local database_password=$(get_env "DATABASE_PASSWORD" "")
    local mas_encryption_secret=$(get_env "MAS_ENCRYPTION_SECRET" "")
    
    # 使用官方工具生成MAS配置
    docker run --rm -it \
        ghcr.io/element-hq/matrix-authentication-service:latest \
        config generate > "$MATRIX_CONFIG/mas-config-template.yaml"
    
    # 修改配置文件
    cat > "$MATRIX_CONFIG/mas-config.yaml" << EOF
# Matrix Authentication Service Configuration
# Generated by setup script

http:
  public_base: https://$mas_subdomain.$domain/
  issuer: https://$mas_subdomain.$domain/
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
      binds:
        - address: "[::]:8080"

database:
  host: postgresql
  port: 5432
  username: mas
  password: $database_password
  database: mas
  ssl_mode: prefer

matrix:
  homeserver: $domain
  secret: $(get_env "SYNAPSE_REGISTRATION_SHARED_SECRET" "")
  endpoint: "http://synapse:8008"

secrets:
  encryption: $mas_encryption_secret
  keys:
    - kid: "$(date +%s)"
      key: |
$(openssl genrsa 2048 2>/dev/null | sed 's/^/        /')

branding:
  service_name: "Matrix Authentication Service"
  
upstream_oauth2:
  providers: []

experimental:
  access_token_ttl: 300
  compat_token_ttl: 300
EOF
    
    log "MAS配置生成完成"
}

# 生成Helm values文件
generate_values_file() {
    log "生成Helm values文件..."
    
    load_env
    
    local domain=$(get_env "DOMAIN_NAME" "example.com")
    local app_subdomain=$(get_env "APP_SUBDOMAIN" "app")
    local live_subdomain=$(get_env "LIVE_SUBDOMAIN" "live")
    local mas_subdomain=$(get_env "MAS_SUBDOMAIN" "mas")
    local rtc_subdomain=$(get_env "RTC_SUBDOMAIN" "rtc")
    local jwt_subdomain=$(get_env "JWT_SUBDOMAIN" "jwt")
    local matrix_subdomain=$(get_env "MATRIX_SUBDOMAIN" "matrix")
    local https_port=$(get_env "HTTPS_PORT" "8443")
    local federation_port=$(get_env "FEDERATION_PORT" "8448")
    
    # 下载官方values.yaml作为基础
    curl -s https://raw.githubusercontent.com/element-hq/ess-helm/main/charts/matrix-stack/values.yaml > "$MATRIX_CONFIG/values-template.yaml"
    
    # 生成自定义values.yaml
    cat > "$VALUES_FILE" << EOF
# Matrix Stack Helm Values
# Generated by setup script

global:
  domain: $domain
  
# PostgreSQL配置
postgresql:
  enabled: true
  auth:
    postgresPassword: $(get_env "DATABASE_PASSWORD" "")
    username: synapse
    password: $(get_env "DATABASE_PASSWORD" "")
    database: synapse
  primary:
    persistence:
      enabled: true
      size: 20Gi

# Synapse配置
synapse:
  enabled: true
  replicaCount: $(get_env "SYNAPSE_REPLICAS" "1")
  
  config:
    serverName: $domain
    publicBaseurl: https://$matrix_subdomain.$domain:$https_port
    
    database:
      host: postgresql
      port: 5432
      user: synapse
      database: synapse
      password:
        value: $(get_env "DATABASE_PASSWORD" "")
    
    signingKey:
      value: "$(get_env "SYNAPSE_SIGNING_KEY" "")"
    
    macaroon:
      value: $(get_env "SYNAPSE_MACAROON_SECRET" "")
    
    registrationSharedSecret:
      value: $(get_env "SYNAPSE_REGISTRATION_SHARED_SECRET" "")
  
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-issuer
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    hosts:
      - host: $matrix_subdomain.$domain
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: synapse-tls
        hosts:
          - $matrix_subdomain.$domain

# Element Web配置
elementweb:
  enabled: true
  replicaCount: $(get_env "ELEMENT_REPLICAS" "1")
  
  config:
    default_server_config:
      m.homeserver:
        base_url: https://$matrix_subdomain.$domain:$https_port
        server_name: $domain
      m.identity_server:
        base_url: https://$mas_subdomain.$domain:$https_port
    
    brand: "Matrix Video Conference"
    
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-issuer
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    hosts:
      - host: $app_subdomain.$domain
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: elementweb-tls
        hosts:
          - $app_subdomain.$domain

# Matrix Authentication Service配置
mas:
  enabled: true
  replicaCount: $(get_env "MAS_REPLICAS" "1")
  
  config:
    existingSecret: mas-config
  
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-issuer
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    hosts:
      - host: $mas_subdomain.$domain
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: mas-tls
        hosts:
          - $mas_subdomain.$domain

# HAProxy配置
haproxy:
  enabled: true
  replicaCount: $(get_env "HAPROXY_REPLICAS" "1")
  
  service:
    type: NodePort
    ports:
      http:
        port: 80
        nodePort: 30080
      https:
        port: 443
        nodePort: 30443
      federation:
        port: 8448
        nodePort: 30448

# LiveKit配置
livekit:
  enabled: true
  replicaCount: $(get_env "LIVEKIT_REPLICAS" "1")
  
  config:
    domain: $live_subdomain.$domain
    api_key: $(get_env "LIVEKIT_API_KEY" "")
    api_secret: $(get_env "LIVEKIT_SECRET_KEY" "")
    
    turn:
      enabled: true
      domain: $live_subdomain.$domain
      tls_port: 5349
      udp_port: 3478
  
  service:
    type: NodePort
    ports:
      http:
        nodePort: 30152
      rtc_tcp:
        nodePort: 30153
      turn_udp:
        nodePort: 30154
  
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-issuer
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    hosts:
      - host: $live_subdomain.$domain
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: livekit-tls
        hosts:
          - $live_subdomain.$domain

# JWT Service配置
jwt-service:
  enabled: true
  
  config:
    livekit_url: wss://$live_subdomain.$domain
    livekit_key: $(get_env "LIVEKIT_API_KEY" "")
    livekit_secret: $(get_env "LIVEKIT_SECRET_KEY" "")
  
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-issuer
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    hosts:
      - host: $jwt_subdomain.$domain
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: jwt-service-tls
        hosts:
          - $jwt_subdomain.$domain

# Matrix RTC Backend配置
matrix-rtc:
  enabled: true
  
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-issuer
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    hosts:
      - host: $rtc_subdomain.$domain
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: matrix-rtc-tls
        hosts:
          - $rtc_subdomain.$domain
EOF
    
    log "Helm values文件生成完成"
}

# 部署Matrix Stack
deploy_matrix_stack() {
    log "部署Matrix Stack..."
    
    # 创建命名空间
    kubectl create namespace "$DEFAULT_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # 创建MAS配置Secret
    kubectl create secret generic mas-config \
        --from-file=config.yaml="$MATRIX_CONFIG/mas-config.yaml" \
        --namespace "$DEFAULT_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # 添加ESS Helm仓库
    helm repo add ess-helm oci://ghcr.io/element-hq/ess-helm
    helm repo update
    
    # 部署Matrix Stack
    helm upgrade --install "$DEFAULT_RELEASE_NAME" ess-helm/matrix-stack \
        --namespace "$DEFAULT_NAMESPACE" \
        --values "$VALUES_FILE" \
        --timeout 20m \
        --wait
    
    log "Matrix Stack部署完成"
}

# 等待服务就绪
wait_for_services() {
    log "等待服务就绪..."
    
    local timeout=600
    local count=0
    
    while ! kubectl get pods -n "$DEFAULT_NAMESPACE" | grep -q "Running"; do
        if [[ $count -ge $timeout ]]; then
            error "服务启动超时"
            exit 1
        fi
        sleep 10
        ((count+=10))
        log "等待中... ($count/$timeout 秒)"
    done
    
    # 等待所有Pod就绪
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance="$DEFAULT_RELEASE_NAME" -n "$DEFAULT_NAMESPACE" --timeout=600s
    
    log "所有服务已就绪"
}

# 创建管理员用户
create_admin_user() {
    log "创建管理员用户..."
    
    load_env
    
    local admin_user=$(get_env "ADMIN_USERNAME" "admin")
    local admin_pass=$(get_env "ADMIN_PASSWORD" "")
    
    if [[ -z "$admin_pass" ]]; then
        error "管理员密码未设置"
        exit 1
    fi
    
    # 等待Synapse就绪
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=synapse -n "$DEFAULT_NAMESPACE" --timeout=300s
    
    # 创建管理员用户
    kubectl exec -n "$DEFAULT_NAMESPACE" deployment/synapse -- \
        register_new_matrix_user \
        -c /data/homeserver.yaml \
        -u "$admin_user" \
        -p "$admin_pass" \
        -a
    
    log "管理员用户创建完成: @$admin_user:$(get_env "DOMAIN_NAME" "example.com")"
}

# 配置动态IP监控
setup_ip_monitoring() {
    log "配置动态IP监控..."
    
    # 创建IP检查脚本
    cat > "$MATRIX_CONFIG/check-ip.sh" << 'EOF'
#!/bin/bash
# 动态IP检查和服务更新脚本

MATRIX_HOME="/opt/matrix"
ENV_FILE="$MATRIX_HOME/.env"
IP_FILE="$MATRIX_HOME/.current_ip"
LOG_FILE="$MATRIX_HOME/logs/ip-check.log"

# 加载环境变量
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

# 日志函数
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 获取当前公网IP
get_current_ip() {
    curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com
}

# 检查IP是否变化
check_ip_change() {
    local current_ip=$(get_current_ip)
    local stored_ip=""
    
    if [[ -f "$IP_FILE" ]]; then
        stored_ip=$(cat "$IP_FILE")
    fi
    
    if [[ "$current_ip" != "$stored_ip" ]]; then
        log_message "IP地址变化: $stored_ip -> $current_ip"
        echo "$current_ip" > "$IP_FILE"
        
        # 触发证书更新（如果需要）
        trigger_cert_renewal
        
        # 重启相关服务（如果需要）
        restart_services_if_needed
        
        log_message "IP变化处理完成"
    else
        log_message "IP地址未变化: $current_ip"
    fi
}

# 触发证书续期
trigger_cert_renewal() {
    log_message "触发证书续期检查..."
    
    # 检查证书是否需要更新
    kubectl get certificates -n ess -o json | jq -r '.items[] | select(.status.conditions[]?.type == "Ready" and .status.conditions[]?.status == "False") | .metadata.name' | while read cert; do
        if [[ -n "$cert" ]]; then
            log_message "重新申请证书: $cert"
            kubectl delete certificate "$cert" -n ess
            kubectl apply -f /opt/matrix/config/cluster-issuer.yaml
        fi
    done
}

# 重启服务（如果需要）
restart_services_if_needed() {
    log_message "检查是否需要重启服务..."
    
    # 这里可以添加需要在IP变化时重启的服务
    # 例如：重启HAProxy以更新配置
    # kubectl rollout restart deployment/haproxy -n ess
}

# 主函数
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log_message "开始IP检查"
    check_ip_change
    log_message "IP检查完成"
}

main "$@"
EOF
    
    chmod +x "$MATRIX_CONFIG/check-ip.sh"
    
    # 创建systemd服务
    sudo tee /etc/systemd/system/matrix-ip-check.service > /dev/null << EOF
[Unit]
Description=Matrix IP Check Service
After=network.target

[Service]
Type=oneshot
User=$USER
ExecStart=$MATRIX_CONFIG/check-ip.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # 创建systemd定时器
    sudo tee /etc/systemd/system/matrix-ip-check.timer > /dev/null << EOF
[Unit]
Description=Matrix IP Check Timer
Requires=matrix-ip-check.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # 启用并启动定时器
    sudo systemctl daemon-reload
    sudo systemctl enable matrix-ip-check.timer
    sudo systemctl start matrix-ip-check.timer
    
    log "动态IP监控配置完成"
}

# 显示部署信息
show_deployment_info() {
    log "部署完成！"
    
    load_env
    
    local domain=$(get_env "DOMAIN_NAME" "example.com")
    local app_subdomain=$(get_env "APP_SUBDOMAIN" "app")
    local https_port=$(get_env "HTTPS_PORT" "8443")
    local admin_user=$(get_env "ADMIN_USERNAME" "admin")
    local admin_pass=$(get_env "ADMIN_PASSWORD" "")
    
    echo
    echo "=================================="
    echo "Matrix 视频会议系统部署信息"
    echo "=================================="
    echo
    echo "访问地址:"
    echo "  Element Web: https://$app_subdomain.$domain:$https_port"
    echo "  Matrix用户ID格式: @username:$domain"
    echo
    echo "管理员账户:"
    echo "  用户名: @$admin_user:$domain"
    echo "  密码: $admin_pass"
    echo
    echo "配置文件位置:"
    echo "  主配置: $ENV_FILE"
    echo "  Helm Values: $VALUES_FILE"
    echo "  数据目录: $MATRIX_DATA"
    echo "  备份目录: $MATRIX_BACKUP"
    echo
    echo "管理命令:"
    echo "  查看状态: kubectl get pods -n $DEFAULT_NAMESPACE"
    echo "  查看日志: kubectl logs -f deployment/synapse -n $DEFAULT_NAMESPACE"
    echo "  重启脚本: $0"
    echo
    echo "=================================="
}

# 检查服务状态
check_service_status() {
    log "检查服务状态..."
    
    echo
    echo "Kubernetes集群状态:"
    kubectl get nodes
    
    echo
    echo "Matrix服务状态:"
    kubectl get pods -n "$DEFAULT_NAMESPACE" -o wide
    
    echo
    echo "服务访问地址:"
    kubectl get ingress -n "$DEFAULT_NAMESPACE"
    
    echo
    echo "证书状态:"
    kubectl get certificates -n "$DEFAULT_NAMESPACE"
    
    echo
    echo "存储状态:"
    kubectl get pvc -n "$DEFAULT_NAMESPACE"
}

# 用户管理菜单
user_management_menu() {
    while true; do
        echo
        echo "=================================="
        echo "用户管理"
        echo "=================================="
        echo "1) 创建新用户"
        echo "2) 删除用户"
        echo "3) 重置用户密码"
        echo "4) 设置/取消管理员权限"
        echo "5) 查看用户列表"
        echo "6) 生成注册邀请码"
        echo "0) 返回主菜单"
        echo
        
        read -p "请选择操作 [0-6]: " choice
        
        case $choice in
            1) create_user ;;
            2) delete_user ;;
            3) reset_user_password ;;
            4) manage_admin_privileges ;;
            5) list_users ;;
            6) generate_registration_token ;;
            0) break ;;
            *) error "无效选择，请重新输入" ;;
        esac
    done
}

# 创建用户
create_user() {
    echo
    read -p "请输入用户名: " username
    read -s -p "请输入密码 (留空自动生成): " password
    echo
    
    if [[ -z "$password" ]]; then
        password=$(generate_password 12)
        log "自动生成密码: $password"
    fi
    
    read -p "是否设为管理员? [y/N]: " is_admin
    
    local admin_flag=""
    if [[ "$is_admin" =~ ^[Yy]$ ]]; then
        admin_flag="-a"
    fi
    
    kubectl exec -n "$DEFAULT_NAMESPACE" deployment/synapse -- \
        register_new_matrix_user \
        -c /data/homeserver.yaml \
        -u "$username" \
        -p "$password" \
        $admin_flag
    
    load_env
    local domain=$(get_env "DOMAIN_NAME" "example.com")
    log "用户创建完成: @$username:$domain"
}

# 删除用户
delete_user() {
    echo
    read -p "请输入要删除的用户名: " username
    read -p "确认删除用户 $username? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        kubectl exec -n "$DEFAULT_NAMESPACE" deployment/synapse -- \
            python -m synapse.app.admin_cmd \
            -c /data/homeserver.yaml \
            delete-user "@$username:$(get_env "DOMAIN_NAME" "example.com")"
        
        log "用户删除完成: $username"
    else
        log "操作已取消"
    fi
}

# 重置用户密码
reset_user_password() {
    echo
    read -p "请输入用户名: " username
    read -s -p "请输入新密码 (留空自动生成): " password
    echo
    
    if [[ -z "$password" ]]; then
        password=$(generate_password 12)
        log "自动生成密码: $password"
    fi
    
    kubectl exec -n "$DEFAULT_NAMESPACE" deployment/synapse -- \
        python -m synapse.app.admin_cmd \
        -c /data/homeserver.yaml \
        reset-password "@$username:$(get_env "DOMAIN_NAME" "example.com")" "$password"
    
    log "密码重置完成"
}

# 管理管理员权限
manage_admin_privileges() {
    echo
    read -p "请输入用户名: " username
    echo "1) 设置为管理员"
    echo "2) 取消管理员权限"
    read -p "请选择 [1-2]: " action
    
    local domain=$(get_env "DOMAIN_NAME" "example.com")
    local user_id="@$username:$domain"
    
    case $action in
        1)
            kubectl exec -n "$DEFAULT_NAMESPACE" deployment/synapse -- \
                python -c "
import psycopg2
conn = psycopg2.connect(
    host='postgresql',
    database='synapse',
    user='synapse',
    password='$(get_env "DATABASE_PASSWORD" "")'
)
cur = conn.cursor()
cur.execute('UPDATE users SET admin = 1 WHERE name = %s', ('$user_id',))
conn.commit()
conn.close()
print('管理员权限设置完成')
"
            ;;
        2)
            kubectl exec -n "$DEFAULT_NAMESPACE" deployment/synapse -- \
                python -c "
import psycopg2
conn = psycopg2.connect(
    host='postgresql',
    database='synapse',
    user='synapse',
    password='$(get_env "DATABASE_PASSWORD" "")'
)
cur = conn.cursor()
cur.execute('UPDATE users SET admin = 0 WHERE name = %s', ('$user_id',))
conn.commit()
conn.close()
print('管理员权限取消完成')
"
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

# 列出用户
list_users() {
    echo
    log "用户列表:"
    
    kubectl exec -n "$DEFAULT_NAMESPACE" deployment/synapse -- \
        python -c "
import psycopg2
conn = psycopg2.connect(
    host='postgresql',
    database='synapse',
    user='synapse',
    password='$(get_env "DATABASE_PASSWORD" "")'
)
cur = conn.cursor()
cur.execute('SELECT name, admin, creation_ts FROM users ORDER BY creation_ts')
rows = cur.fetchall()
print('用户名\t\t\t管理员\t创建时间')
print('-' * 60)
for row in rows:
    admin_status = '是' if row[1] else '否'
    print(f'{row[0]}\t{admin_status}\t{row[2]}')
conn.close()
"
}

# 生成注册邀请码
generate_registration_token() {
    echo
    read -p "邀请码有效期(天) [默认7]: " validity_days
    validity_days=${validity_days:-7}
    
    read -p "最大使用次数 [默认1]: " max_uses
    max_uses=${max_uses:-1}
    
    local token=$(kubectl exec -n "$DEFAULT_NAMESPACE" deployment/synapse -- \
        python -c "
import requests
import json

# 获取管理员访问令牌
admin_token = '$(get_env "SYNAPSE_REGISTRATION_SHARED_SECRET" "")'

# 创建注册令牌
url = 'http://localhost:8008/_synapse/admin/v1/registration_tokens/new'
headers = {'Authorization': f'Bearer {admin_token}'}
data = {
    'length': 16,
    'uses_allowed': $max_uses,
    'expiry_time': $(date -d "+$validity_days days" +%s)000
}

response = requests.post(url, headers=headers, json=data)
if response.status_code == 200:
    token_data = response.json()
    print(token_data['token'])
else:
    print('ERROR: Failed to create token')
")
    
    if [[ "$token" != "ERROR:"* ]]; then
        log "注册邀请码: $token"
        log "有效期: $validity_days 天"
        log "最大使用次数: $max_uses"
        
        # 保存到文件
        echo "$token" >> "$MATRIX_DATA/registration_tokens.txt"
    else
        error "生成邀请码失败"
    fi
}

# 系统管理菜单
system_management_menu() {
    while true; do
        echo
        echo "=================================="
        echo "系统管理"
        echo "=================================="
        echo "1) 查看系统状态"
        echo "2) 重启服务"
        echo "3) 更新组件"
        echo "4) 查看日志"
        echo "5) 证书管理"
        echo "6) 配置管理"
        echo "7) 性能监控"
        echo "0) 返回主菜单"
        echo
        
        read -p "请选择操作 [0-7]: " choice
        
        case $choice in
            1) check_service_status ;;
            2) restart_services ;;
            3) update_components ;;
            4) view_logs ;;
            5) certificate_management ;;
            6) configuration_management ;;
            7) performance_monitoring ;;
            0) break ;;
            *) error "无效选择，请重新输入" ;;
        esac
    done
}

# 重启服务
restart_services() {
    echo
    echo "选择要重启的服务:"
    echo "1) Synapse"
    echo "2) Element Web"
    echo "3) MAS"
    echo "4) LiveKit"
    echo "5) HAProxy"
    echo "6) 所有服务"
    echo "0) 取消"
    
    read -p "请选择 [0-6]: " choice
    
    case $choice in
        1) kubectl rollout restart deployment/synapse -n "$DEFAULT_NAMESPACE" ;;
        2) kubectl rollout restart deployment/elementweb -n "$DEFAULT_NAMESPACE" ;;
        3) kubectl rollout restart deployment/mas -n "$DEFAULT_NAMESPACE" ;;
        4) kubectl rollout restart deployment/livekit -n "$DEFAULT_NAMESPACE" ;;
        5) kubectl rollout restart deployment/haproxy -n "$DEFAULT_NAMESPACE" ;;
        6) 
            kubectl rollout restart deployment -n "$DEFAULT_NAMESPACE"
            log "所有服务重启中..."
            ;;
        0) log "操作已取消" ;;
        *) error "无效选择" ;;
    esac
}

# 更新组件
update_components() {
    echo
    log "检查组件更新..."
    
    # 更新Helm仓库
    helm repo update
    
    # 检查是否有新版本
    helm list -n "$DEFAULT_NAMESPACE"
    
    read -p "是否更新Matrix Stack? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        helm upgrade "$DEFAULT_RELEASE_NAME" ess-helm/matrix-stack \
            --namespace "$DEFAULT_NAMESPACE" \
            --values "$VALUES_FILE" \
            --timeout 20m
        
        log "组件更新完成"
    fi
}

# 查看日志
view_logs() {
    echo
    echo "选择要查看的服务日志:"
    echo "1) Synapse"
    echo "2) Element Web"
    echo "3) MAS"
    echo "4) LiveKit"
    echo "5) HAProxy"
    echo "6) PostgreSQL"
    echo "0) 返回"
    
    read -p "请选择 [0-6]: " choice
    
    case $choice in
        1) kubectl logs -f deployment/synapse -n "$DEFAULT_NAMESPACE" ;;
        2) kubectl logs -f deployment/elementweb -n "$DEFAULT_NAMESPACE" ;;
        3) kubectl logs -f deployment/mas -n "$DEFAULT_NAMESPACE" ;;
        4) kubectl logs -f deployment/livekit -n "$DEFAULT_NAMESPACE" ;;
        5) kubectl logs -f deployment/haproxy -n "$DEFAULT_NAMESPACE" ;;
        6) kubectl logs -f deployment/postgresql -n "$DEFAULT_NAMESPACE" ;;
        0) return ;;
        *) error "无效选择" ;;
    esac
}

# 证书管理
certificate_management() {
    echo
    echo "=================================="
    echo "证书管理"
    echo "=================================="
    echo "1) 查看证书状态"
    echo "2) 强制续期证书"
    echo "3) 切换证书类型"
    echo "4) 查看证书详情"
    echo "0) 返回"
    
    read -p "请选择操作 [0-4]: " choice
    
    case $choice in
        1) 
            kubectl get certificates -n "$DEFAULT_NAMESPACE"
            kubectl get certificaterequests -n "$DEFAULT_NAMESPACE"
            ;;
        2)
            echo "选择要续期的证书:"
            kubectl get certificates -n "$DEFAULT_NAMESPACE" --no-headers | awk '{print NR") "$1}'
            read -p "请输入证书编号: " cert_num
            cert_name=$(kubectl get certificates -n "$DEFAULT_NAMESPACE" --no-headers | sed -n "${cert_num}p" | awk '{print $1}')
            if [[ -n "$cert_name" ]]; then
                kubectl delete certificate "$cert_name" -n "$DEFAULT_NAMESPACE"
                log "证书 $cert_name 已删除，将自动重新申请"
            fi
            ;;
        3)
            echo "当前证书类型: $(get_env "CERT_TYPE" "production")"
            echo "1) 切换到生产证书"
            echo "2) 切换到测试证书"
            read -p "请选择 [1-2]: " cert_choice
            case $cert_choice in
                1)
                    save_env "CERT_TYPE" "production"
                    save_env "ACME_SERVER" "https://acme-v02.api.letsencrypt.org/directory"
                    ;;
                2)
                    save_env "CERT_TYPE" "staging"
                    save_env "ACME_SERVER" "https://acme-staging-v02.api.letsencrypt.org/directory"
                    ;;
            esac
            configure_cert_manager
            log "证书类型已切换，请重新部署以生效"
            ;;
        4)
            kubectl describe certificates -n "$DEFAULT_NAMESPACE"
            ;;
        0) return ;;
        *) error "无效选择" ;;
    esac
}

# 配置管理
configuration_management() {
    echo
    echo "=================================="
    echo "配置管理"
    echo "=================================="
    echo "1) 查看当前配置"
    echo "2) 修改域名配置"
    echo "3) 修改端口配置"
    echo "4) 修改副本数配置"
    echo "5) 重新生成配置文件"
    echo "0) 返回"
    
    read -p "请选择操作 [0-5]: " choice
    
    case $choice in
        1)
            if [[ -f "$ENV_FILE" ]]; then
                cat "$ENV_FILE"
            else
                error "配置文件不存在"
            fi
            ;;
        2)
            read -p "请输入新的主域名: " new_domain
            if validate_domain "$new_domain"; then
                save_env "DOMAIN_NAME" "$new_domain"
                log "域名配置已更新，请重新生成配置文件并部署"
            else
                error "域名格式无效"
            fi
            ;;
        3)
            read -p "HTTP端口 [当前: $(get_env "HTTP_PORT" "8080")]: " new_http_port
            read -p "HTTPS端口 [当前: $(get_env "HTTPS_PORT" "8443")]: " new_https_port
            read -p "联邦端口 [当前: $(get_env "FEDERATION_PORT" "8448")]: " new_fed_port
            
            [[ -n "$new_http_port" ]] && save_env "HTTP_PORT" "$new_http_port"
            [[ -n "$new_https_port" ]] && save_env "HTTPS_PORT" "$new_https_port"
            [[ -n "$new_fed_port" ]] && save_env "FEDERATION_PORT" "$new_fed_port"
            
            log "端口配置已更新"
            ;;
        4)
            echo "当前副本数配置:"
            echo "Synapse: $(get_env "SYNAPSE_REPLICAS" "1")"
            echo "Element Web: $(get_env "ELEMENT_REPLICAS" "1")"
            echo "HAProxy: $(get_env "HAPROXY_REPLICAS" "1")"
            echo "MAS: $(get_env "MAS_REPLICAS" "1")"
            echo "LiveKit: $(get_env "LIVEKIT_REPLICAS" "1")"
            echo
            
            read -p "Synapse副本数: " synapse_replicas
            read -p "Element Web副本数: " element_replicas
            read -p "HAProxy副本数: " haproxy_replicas
            read -p "MAS副本数: " mas_replicas
            read -p "LiveKit副本数: " livekit_replicas
            
            [[ -n "$synapse_replicas" ]] && save_env "SYNAPSE_REPLICAS" "$synapse_replicas"
            [[ -n "$element_replicas" ]] && save_env "ELEMENT_REPLICAS" "$element_replicas"
            [[ -n "$haproxy_replicas" ]] && save_env "HAPROXY_REPLICAS" "$haproxy_replicas"
            [[ -n "$mas_replicas" ]] && save_env "MAS_REPLICAS" "$mas_replicas"
            [[ -n "$livekit_replicas" ]] && save_env "LIVEKIT_REPLICAS" "$livekit_replicas"
            
            log "副本数配置已更新"
            ;;
        5)
            read -p "确认重新生成所有配置文件? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                generate_mas_config
                generate_values_file
                log "配置文件已重新生成"
            fi
            ;;
        0) return ;;
        *) error "无效选择" ;;
    esac
}

# 性能监控
performance_monitoring() {
    echo
    echo "=================================="
    echo "性能监控"
    echo "=================================="
    
    # 系统资源使用情况
    echo "系统资源使用情况:"
    echo "CPU使用率:"
    top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1
    
    echo "内存使用情况:"
    free -h
    
    echo "磁盘使用情况:"
    df -h
    
    echo
    echo "Kubernetes资源使用情况:"
    kubectl top nodes 2>/dev/null || echo "metrics-server未安装"
    kubectl top pods -n "$DEFAULT_NAMESPACE" 2>/dev/null || echo "metrics-server未安装"
    
    echo
    echo "服务连接数:"
    kubectl get pods -n "$DEFAULT_NAMESPACE" -o wide
}

# 备份和恢复菜单
backup_restore_menu() {
    while true; do
        echo
        echo "=================================="
        echo "备份和恢复"
        echo "=================================="
        echo "1) 立即备份"
        echo "2) 恢复数据"
        echo "3) 查看备份列表"
        echo "4) 删除旧备份"
        echo "5) 自动备份配置"
        echo "0) 返回主菜单"
        echo
        
        read -p "请选择操作 [0-5]: " choice
        
        case $choice in
            1) create_backup ;;
            2) restore_backup ;;
            3) list_backups ;;
            4) cleanup_backups ;;
            5) configure_auto_backup ;;
            0) break ;;
            *) error "无效选择，请重新输入" ;;
        esac
    done
}

# 创建备份
create_backup() {
    log "开始创建备份..."
    
    local backup_date=$(date +"%Y%m%d_%H%M%S")
    local backup_dir="$MATRIX_BACKUP/backup_$backup_date"
    
    mkdir -p "$backup_dir"
    
    # 备份配置文件
    log "备份配置文件..."
    cp -r "$MATRIX_CONFIG" "$backup_dir/"
    cp "$ENV_FILE" "$backup_dir/"
    
    # 备份数据库
    log "备份数据库..."
    kubectl exec -n "$DEFAULT_NAMESPACE" deployment/postgresql -- \
        pg_dumpall -U postgres > "$backup_dir/database_backup.sql"
    
    # 备份持久化数据
    log "备份持久化数据..."
    kubectl get pvc -n "$DEFAULT_NAMESPACE" -o name | while read pvc; do
        pvc_name=$(echo $pvc | cut -d'/' -f2)
        kubectl exec -n "$DEFAULT_NAMESPACE" deployment/postgresql -- \
            tar czf - /var/lib/postgresql/data > "$backup_dir/${pvc_name}_data.tar.gz" 2>/dev/null || true
    done
    
    # 创建备份信息文件
    cat > "$backup_dir/backup_info.txt" << EOF
备份时间: $(date)
备份版本: $SCRIPT_VERSION
域名: $(get_env "DOMAIN_NAME" "unknown")
部署模式: $(get_env "DEPLOY_MODE" "unknown")
Kubernetes版本: $(kubectl version --short 2>/dev/null | head -1)
Helm版本: $(helm version --short 2>/dev/null)
EOF
    
    # 压缩备份
    log "压缩备份文件..."
    cd "$MATRIX_BACKUP"
    tar czf "backup_$backup_date.tar.gz" "backup_$backup_date"
    rm -rf "backup_$backup_date"
    
    log "备份创建完成: backup_$backup_date.tar.gz"
}

# 恢复备份
restore_backup() {
    echo
    log "可用备份列表:"
    list_backups
    
    echo
    read -p "请输入要恢复的备份文件名 (不含.tar.gz): " backup_name
    
    local backup_file="$MATRIX_BACKUP/${backup_name}.tar.gz"
    
    if [[ ! -f "$backup_file" ]]; then
        error "备份文件不存在: $backup_file"
        return 1
    fi
    
    read -p "确认恢复备份 $backup_name? 这将覆盖当前数据 [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "操作已取消"
        return 0
    fi
    
    log "开始恢复备份..."
    
    # 解压备份
    cd "$MATRIX_BACKUP"
    tar xzf "$backup_file"
    
    local restore_dir="$MATRIX_BACKUP/$backup_name"
    
    # 恢复配置文件
    log "恢复配置文件..."
    cp -r "$restore_dir/config/"* "$MATRIX_CONFIG/"
    cp "$restore_dir/.env" "$ENV_FILE"
    
    # 恢复数据库
    log "恢复数据库..."
    kubectl exec -i -n "$DEFAULT_NAMESPACE" deployment/postgresql -- \
        psql -U postgres < "$restore_dir/database_backup.sql"
    
    # 重启服务
    log "重启服务..."
    kubectl rollout restart deployment -n "$DEFAULT_NAMESPACE"
    
    # 清理临时文件
    rm -rf "$restore_dir"
    
    log "备份恢复完成"
}

# 列出备份
list_backups() {
    if [[ -d "$MATRIX_BACKUP" ]]; then
        ls -la "$MATRIX_BACKUP"/*.tar.gz 2>/dev/null | awk '{print $9, $5, $6, $7, $8}' | column -t
    else
        log "没有找到备份文件"
    fi
}

# 清理旧备份
cleanup_backups() {
    echo
    read -p "保留最近几个备份? [默认5]: " keep_count
    keep_count=${keep_count:-5}
    
    log "清理旧备份，保留最近 $keep_count 个..."
    
    cd "$MATRIX_BACKUP"
    ls -t backup_*.tar.gz 2>/dev/null | tail -n +$((keep_count + 1)) | xargs rm -f
    
    log "旧备份清理完成"
}

# 配置自动备份
configure_auto_backup() {
    echo
    echo "当前自动备份配置:"
    if systemctl is-enabled matrix-backup.timer &>/dev/null; then
        echo "状态: 已启用"
        systemctl status matrix-backup.timer --no-pager
    else
        echo "状态: 未启用"
    fi
    
    echo
    echo "1) 启用自动备份"
    echo "2) 禁用自动备份"
    echo "3) 修改备份计划"
    echo "0) 返回"
    
    read -p "请选择 [0-3]: " choice
    
    case $choice in
        1)
            # 创建备份脚本
            cat > "$MATRIX_CONFIG/backup.sh" << EOF
#!/bin/bash
cd "$(dirname "$0")/.."
./setup.sh --backup-only
EOF
            chmod +x "$MATRIX_CONFIG/backup.sh"
            
            # 创建systemd服务
            sudo tee /etc/systemd/system/matrix-backup.service > /dev/null << EOF
[Unit]
Description=Matrix Backup Service
After=network.target

[Service]
Type=oneshot
User=$USER
ExecStart=$MATRIX_CONFIG/backup.sh
StandardOutput=journal
StandardError=journal
EOF
            
            # 创建systemd定时器
            sudo tee /etc/systemd/system/matrix-backup.timer > /dev/null << EOF
[Unit]
Description=Matrix Backup Timer
Requires=matrix-backup.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
            
            sudo systemctl daemon-reload
            sudo systemctl enable matrix-backup.timer
            sudo systemctl start matrix-backup.timer
            
            log "自动备份已启用 (每日执行)"
            ;;
        2)
            sudo systemctl stop matrix-backup.timer
            sudo systemctl disable matrix-backup.timer
            log "自动备份已禁用"
            ;;
        3)
            read -p "请输入新的备份计划 (cron格式，如 '0 2 * * *' 表示每日2点): " schedule
            sudo sed -i "s/OnCalendar=.*/OnCalendar=$schedule/" /etc/systemd/system/matrix-backup.timer
            sudo systemctl daemon-reload
            sudo systemctl restart matrix-backup.timer
            log "备份计划已更新"
            ;;
        0) return ;;
        *) error "无效选择" ;;
    esac
}

# 清理和卸载菜单
cleanup_menu() {
    while true; do
        echo
        echo "=================================="
        echo "清理和卸载"
        echo "=================================="
        echo "1) 清理临时文件"
        echo "2) 清理旧日志"
        echo "3) 卸载Matrix Stack"
        echo "4) 卸载K3s"
        echo "5) 完全卸载 (包含数据)"
        echo "0) 返回主菜单"
        echo
        
        read -p "请选择操作 [0-5]: " choice
        
        case $choice in
            1) cleanup_temp_files ;;
            2) cleanup_old_logs ;;
            3) uninstall_matrix_stack ;;
            4) uninstall_k3s ;;
            5) complete_uninstall ;;
            0) break ;;
            *) error "无效选择，请重新输入" ;;
        esac
    done
}

# 清理临时文件
cleanup_temp_files() {
    log "清理临时文件..."
    
    # 清理Docker临时文件
    docker system prune -f 2>/dev/null || true
    
    # 清理Kubernetes临时文件
    kubectl delete pods --field-selector=status.phase=Succeeded -A 2>/dev/null || true
    kubectl delete pods --field-selector=status.phase=Failed -A 2>/dev/null || true
    
    # 清理系统临时文件
    sudo apt-get autoremove -y
    sudo apt-get autoclean
    
    log "临时文件清理完成"
}

# 清理旧日志
cleanup_old_logs() {
    log "清理旧日志..."
    
    # 清理系统日志
    sudo journalctl --vacuum-time=7d
    
    # 清理应用日志
    find "$MATRIX_LOGS" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    
    log "旧日志清理完成"
}

# 卸载Matrix Stack
uninstall_matrix_stack() {
    echo
    read -p "确认卸载Matrix Stack? 这将删除所有服务但保留数据 [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "卸载Matrix Stack..."
        
        helm uninstall "$DEFAULT_RELEASE_NAME" -n "$DEFAULT_NAMESPACE" || true
        kubectl delete namespace "$DEFAULT_NAMESPACE" || true
        
        log "Matrix Stack卸载完成"
    else
        log "操作已取消"
    fi
}

# 卸载K3s
uninstall_k3s() {
    echo
    read -p "确认卸载K3s? 这将删除整个Kubernetes集群 [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "卸载K3s..."
        
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
        
        log "K3s卸载完成"
    else
        log "操作已取消"
    fi
}

# 完全卸载
complete_uninstall() {
    echo
    warn "这将完全删除所有Matrix相关的数据和配置！"
    read -p "确认完全卸载? 请输入 'DELETE ALL' 确认: " confirm
    
    if [[ "$confirm" == "DELETE ALL" ]]; then
        log "开始完全卸载..."
        
        # 停止所有服务
        sudo systemctl stop matrix-ip-check.timer 2>/dev/null || true
        sudo systemctl stop matrix-backup.timer 2>/dev/null || true
        
        # 卸载Matrix Stack
        helm uninstall "$DEFAULT_RELEASE_NAME" -n "$DEFAULT_NAMESPACE" 2>/dev/null || true
        kubectl delete namespace "$DEFAULT_NAMESPACE" 2>/dev/null || true
        
        # 卸载cert-manager
        helm uninstall cert-manager -n cert-manager 2>/dev/null || true
        kubectl delete namespace cert-manager 2>/dev/null || true
        
        # 卸载K3s
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
        
        # 删除数据目录
        sudo rm -rf "$MATRIX_HOME"
        
        # 删除systemd服务
        sudo rm -f /etc/systemd/system/matrix-*.service
        sudo rm -f /etc/systemd/system/matrix-*.timer
        sudo systemctl daemon-reload
        
        log "完全卸载完成"
    else
        log "操作已取消"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo
        echo "=================================="
        echo "$SCRIPT_NAME v$SCRIPT_VERSION"
        echo "=================================="
        echo "1) 环境检查和准备"
        echo "2) 配置向导"
        echo "3) 安装K3s"
        echo "4) 安装cert-manager"
        echo "5) 部署Matrix Stack"
        echo "6) 创建管理员用户"
        echo "7) 配置动态IP监控"
        echo "8) 查看部署信息"
        echo "9) 检查服务状态"
        echo "10) 用户管理"
        echo "11) 系统管理"
        echo "12) 备份和恢复"
        echo "13) 清理和卸载"
        echo "0) 退出"
        echo
        
        read -p "请选择操作 [0-13]: " choice
        
        case $choice in
            1) 
                check_system_requirements
                install_dependencies
                create_directories
                ;;
            2) configuration_wizard ;;
            3) install_k3s ;;
            4) 
                install_helm
                install_cert_manager
                configure_cert_manager
                ;;
            5)
                generate_mas_config
                generate_values_file
                deploy_matrix_stack
                wait_for_services
                ;;
            6) create_admin_user ;;
            7) setup_ip_monitoring ;;
            8) show_deployment_info ;;
            9) check_service_status ;;
            10) user_management_menu ;;
            11) system_management_menu ;;
            12) backup_restore_menu ;;
            13) cleanup_menu ;;
            0) 
                log "感谢使用Matrix部署脚本！"
                exit 0
                ;;
            *) error "无效选择，请重新输入" ;;
        esac
    done
}

# 命令行参数处理
case "${1:-}" in
    --backup-only)
        create_backup
        exit 0
        ;;
    --check-ip)
        source "$MATRIX_CONFIG/check-ip.sh"
        exit 0
        ;;
    --version)
        echo "$SCRIPT_NAME v$SCRIPT_VERSION"
        exit 0
        ;;
    --help)
        echo "用法: $0 [选项]"
        echo "选项:"
        echo "  --backup-only    仅执行备份操作"
        echo "  --check-ip       检查IP变化"
        echo "  --version        显示版本信息"
        echo "  --help           显示帮助信息"
        exit 0
        ;;
esac

# 主程序入口
main() {
    # 检查root权限
    check_root
    
    # 加载环境变量
    load_env
    
    # 显示欢迎信息
    echo
    echo "=================================="
    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
    echo "基于 Element Server Suite (ESS)"
    echo "支持动态IP和内网部署"
    echo "=================================="
    
    # 进入主菜单
    main_menu
}

# 启动主程序
main "$@"

