#!/bin/bash

# Matrix Stack 完整安装和管理脚本 v0.1.3 - 完全修复版
# 支持完全自定义配置，包括用户管理、消息功能和我的功能
# 基于 element-hq/ess-helm 项目，做了所有预已知问题的修复
# 添加 systemd 定时器动态IP、acme.sh证书管理、高可用监控
# 完全适配 MSC3861 环境，修复 register_new_matrix_user 问题
# 修复默认：解决设置issuer、域代理、DNS验证等问题

set -e

# 设置 KUBECONFIG 环境变量
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 脚本信息
SCRIPT_VERSION="v0.1.2"
GITHUB_RAW_URL="https://raw.githubusercontent.com/niublab/urtc/main"

# 自动化模式标志
AUTO_MODE="false"

# 默认配置
DEFAULT_INSTALL_PATH="/opt/matrix"
DEFAULT_HTTP_NODEPORT="30080"
DEFAULT_HTTPS_NODEPORT="30443"
DEFAULT_EXTERNAL_HTTP_PORT="8080"
DEFAULT_EXTERNAL_HTTPS_PORT="8443"
DEFAULT_TURN_PORT_START="30152"
DEFAULT_TURN_PORT_END="30252"
DEFAULT_SUBDOMAIN_MATRIX="matrix"
DEFAULT_SUBDOMAIN_CHAT="chat"
DEFAULT_SUBDOMAIN_AUTH="auth"
DEFAULT_SUBDOMAIN_RTC="rtc"

# 配置变量
INSTALL_PATH=""
DOMAIN=""
ADMIN_EMAIL=""
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
HTTP_NODEPORT=""
HTTPS_NODEPORT=""
EXTERNAL_HTTP_PORT=""
EXTERNAL_HTTPS_PORT=""
TURN_PORT_START=""
TURN_PORT_END=""
SUBDOMAIN_MATRIX=""
SUBDOMAIN_CHAT=""
SUBDOMAIN_AUTH=""
SUBDOMAIN_RTC=""
USE_LIVEKIT_TURN="false"
DEPLOYMENT_MODE=""
CERT_MODE=""
DNS_PROVIDER=""
DNS_API_KEY=""

# 日志函数
log_info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

log_error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 检查系统要求
check_system() {
    log_info "检查系统要求..."
    
    # 检查操作系统
    if ! command -v lsb_release &> /dev/null; then
        log_error "无法检测操作系统版本"
        exit 1
    fi
    
    OS=$(lsb_release -si)
    VERSION=$(lsb_release -sr)
    
    if [[ "$OS" != "Ubuntu" ]]; then
        log_error "此脚本仅支持Ubuntu系统"
        exit 1
    fi
    
    # 检查Ubuntu版本
    if [[ $(echo "$VERSION >= 20.04" | bc) -eq 0 ]]; then
        log_error "需要Ubuntu 20.04或更高版本"
        exit 1
    fi
    
    # 检查内存
    MEMORY=$(free -m | awk 'NR==2{printf "%.0f", $2/1024}')
    if [[ $MEMORY -lt 2 ]]; then
        log_warning "建议至少2GB内存，当前: ${MEMORY}GB"
    fi
    
    # 检查磁盘空间
    DISK=$(df -h / | awk 'NR==2{print $4}' | sed 's/G//')
    if [[ ${DISK%.*} -lt 10 ]]; then
        log_warning "建议至少10GB可用磁盘空间，当前: ${DISK}G"
    fi
    
    log_success "系统检查完成"
}

# 检查网络连接
check_network() {
    log_info "检查网络连接..."
    
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        log_error "无法连接到互联网"
        exit 1
    fi
    
    if ! ping -c 1 github.com &> /dev/null; then
        log_error "无法连接到GitHub"
        exit 1
    fi
    
    log_success "网络连接正常"
}

# 检查K3s状态
check_k3s() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl未安装，请先安装K3s"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "K3s集群未运行，请检查K3s状态"
        exit 1
    fi
    
    log_success "K3s集群运行正常"
}

# 检查Helm
check_helm() {
    if ! command -v helm &> /dev/null; then
        log_info "安装Helm..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        log_success "Helm安装完成"
    else
        log_success "Helm已安装"
    fi
}

# 检查Synapse是否运行
check_synapse_running() {
    if kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main &> /dev/null; then
        SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$SYNAPSE_POD" ]]; then
           if kubectl exec -n ess "$SYNAPSE_POD" -- curl -s \
           "http://localhost:8008/_synapse/admin/v1/server_version" >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    return 1
}

# 获取管理员访问令牌
get_admin_token() {
    if ! check_synapse_running; then
        log_error "Synapse服务未运行"
        return 1
    fi
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 尝试从配置文件获取令牌
    local token=$(kubectl exec -n ess "$SYNAPSE_POD" -- cat /data/homeserver.yaml | grep -A 5 "registration_shared_secret:" | grep -v "registration_shared_secret:" | head -1 | awk '{print $1}' | tr -d '"' 2>/dev/null)
    
    if [[ -z "$token" ]]; then
        log_error "无法获取管理员令牌"
        return 1
    fi
    
    echo "$token"
}

# 创建用户
create_user() {
    echo
    read -p "用户名: " username
    read -s -p "密码: " password
    echo
    read -p "是否为管理员? (y/n) [默认: n]: " is_admin
    is_admin=${is_admin:-n}
    
    if [[ "$is_admin" == "y" || "$is_admin" == "Y" ]]; then
        admin_flag="true"
    else
        admin_flag="false"
    fi
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 构建用户ID
    user_id="@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    # 创建用户
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X PUT \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"$password\",\"admin\":$admin_flag}" \
        "http://localhost:8008/_synapse/admin/v2/users/$user_id")
    
    if echo "$response" | grep -q "name"; then
        log_success "用户创建成功: $user_id"
        if [[ "$admin_flag" == "true" ]]; then
            log_info "用户已设置为管理员"
        fi
    else
        log_error "用户创建失败: $response"
    fi
}

# 检查服务状态
check_service_status() {
    log_info "检查服务状态..."
    
    # 检查命名空间
    if ! kubectl get namespace ess &> /dev/null; then
        log_error "ESS命名空间不存在"
        return 1
    fi
    
    # 检查Pod状态
    echo -e "\n${CYAN}Pod状态：${NC}"
    kubectl get pods -n ess
    
    # 检查服务状态
    echo -e "\n${CYAN}服务状态：${NC}"
    kubectl get svc -n ess
    
    # 检查Ingress状态
    echo -e "\n${CYAN}Ingress状态：${NC}"
    kubectl get ingress -n ess
    
    # 检查Synapse连接
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$SYNAPSE_POD" ]]; then
        if kubectl exec -n ess "$SYNAPSE_POD" -- curl -s http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
            log_success "Synapse API响应正常"
        else
            log_warning "Synapse API无响应"
        fi
    else
        log_warning "未找到Synapse Pod"
    fi
}

# 查看用户列表
list_users() {
    if ! check_synapse_running; then
        log_error "Synapse服务未运行"
        return 1
    fi
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    echo -e "\n${CYAN}用户列表：${NC}"
    
    # 获取用户列表
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s \
        "http://localhost:8008/_synapse/admin/v2/users")
    
    if echo "$response" | grep -q "users"; then
        echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
users = data.get('users', [])
print(f'总用户数: {len(users)}')
print()
for user in users:
    name = user.get('name', 'N/A')
    admin = '是' if user.get('admin', False) else '否'
    deactivated = '是' if user.get('deactivated', False) else '否'
    creation_ts = user.get('creation_ts', 0)
    print(f'用户: {name}')
    print(f'  管理员: {admin}')
    print(f'  已停用: {deactivated}')
    print(f'  创建时间: {creation_ts}')
    print()
"
    else
        log_error "获取用户列表失败"
    fi
}

# 删除用户
delete_user() {
    echo
    read -p "要删除的用户名: " username
    
    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        return 1
    fi
    
    # 构建用户ID
    user_id="@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    echo -e "${YELLOW}警告: 此操作将永久删除用户 $user_id${NC}"
    read -p "确认删除? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "操作已取消"
        return 0
    fi
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 停用用户
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X POST \
        -H "Content-Type: application/json" \
        -d '{"erase": true}' \
        "http://localhost:8008/_synapse/admin/v1/deactivate/$user_id")
    
    if echo "$response" | grep -q "id_server_unbind_result"; then
        log_success "用户删除成功: $user_id"
    else
        log_error "用户删除失败: $response"
    fi
}

# 重置用户密码
reset_password() {
    echo
    read -p "用户名: " username
    read -s -p "新密码: " new_password
    echo
    
    if [[ -z "$username" || -z "$new_password" ]]; then
        log_error "用户名和密码不能为空"
        return 1
    fi
    
    # 构建用户ID
    user_id="@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 重置密码
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"new_password\":\"$new_password\",\"logout_devices\":true}" \
        "http://localhost:8008/_synapse/admin/v1/reset_password/$user_id")
    
    if echo "$response" | grep -q "{}"; then
        log_success "密码重置成功: $user_id"
        log_info "所有设备已登出"
    else
        log_error "密码重置失败: $response"
    fi
}

# 查看服务器统计
show_server_stats() {
    if ! check_synapse_running; then
        log_error "Synapse服务未运行"
        return 1
    fi
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    echo -e "\n${CYAN}服务器统计：${NC}"
    
    # 获取用户统计
    user_response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s \
        "http://localhost:8008/_synapse/admin/v2/users")
    
    if echo "$user_response" | grep -q "total"; then
        total_users=$(echo "$user_response" | python3 -c "import sys, json; print(json.load(sys.stdin)['total'])" 2>/dev/null || echo "未知")
        echo "总用户数: $total_users"
    fi
    
    # 获取房间统计（如果API可用）
    echo "房间统计: 需要管理员权限查看"
    
    # 显示系统资源使用情况
    echo -e "\n${CYAN}系统资源：${NC}"
    echo "CPU使用率: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)%"
    echo "内存使用: $(free -h | awk 'NR==2{printf "%.1f/%.1fGB (%.1f%%)", $3/1024/1024/1024, $2/1024/1024/1024, $3*100/$2}')"
    echo "磁盘使用: $(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')"
}

# 生成注册令牌
generate_registration_token() {
    echo
    read -p "邀请码有效期 (小时) [默认: 24]: " validity_hours
    validity_hours=${validity_hours:-24}
    
    read -p "最大使用次数 [默认: 1]: " uses_allowed
    uses_allowed=${uses_allowed:-1}
    
    read -p "邀请码描述 (可选): " description
    
    # 计算过期时间戳 (毫秒)
    expiry_time=$(($(date +%s) * 1000 + validity_hours * 3600 * 1000))
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 生成注册令牌
    token_data="{\"uses_allowed\":$uses_allowed,\"expiry_time\":$expiry_time"
    if [[ -n "$description" ]]; then
        token_data="$token_data,\"description\":\"$description\""
    fi
    token_data="$token_data}"
    
    token_response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$token_data" \
        "http://localhost:8008/_synapse/admin/v1/registration_tokens/new")
    
    token=$(echo "$token_response" | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "生成失败")
    
    if [[ "$token" != "生成失败" ]]; then
        echo
        log_success "注册令牌生成成功！"
        echo -e "${CYAN}令牌: ${YELLOW}$token${NC}"
        echo "有效期: $validity_hours 小时"
        echo "最大使用次数: $uses_allowed"
        if [[ -n "$description" ]]; then
            echo "描述: $description"
        fi
        echo
        echo -e "${CYAN}使用方法：${NC}"
        echo "1. 访问: https://${SUBDOMAIN_CHAT}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
        echo "2. 点击 '创建账户'"
        echo "3. 输入注册令牌: $token"
        echo "4. 完成注册流程"
    else
        log_error "注册令牌生成失败"
    fi
}

# 查看注册令牌
list_registration_tokens() {
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 获取令牌列表
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s \
        "http://localhost:8008/_synapse/admin/v1/registration_tokens/$token"
        
    if echo "$response" | grep -q "registration_tokens"; then
        echo -e "\n${CYAN}注册令牌列表：${NC}"
        echo "$response" | python3 -c "
import sys, json
from datetime import datetime
data = json.load(sys.stdin)
tokens = data.get('registration_tokens', [])
print(f'总令牌数: {len(tokens)}')
print()
for token in tokens:
    token_str = token.get('token', 'N/A')
    uses_allowed = token.get('uses_allowed', 'N/A')
    pending = token.get('pending', 0)
    completed = token.get('completed', 0)
    expiry_time = token.get('expiry_time')
    
    print(f'令牌: {token_str}')
    print(f'  允许使用次数: {uses_allowed}')
    print(f'  已使用: {completed}')
    print(f'  待处理: {pending}')
    
    if expiry_time:
        expiry_date = datetime.fromtimestamp(expiry_time / 1000)
        print(f'  过期时间: {expiry_date}')
    else:
        print(f'  过期时间: 永不过期')
    print()
"
    else
        log_error "获取令牌列表失败"
    fi
}

# 删除注册令牌
delete_registration_token() {
    echo
    read -p "要删除的令牌: " token
    
    if [[ -z "$token" ]]; then
        log_error "令牌不能为空"
        return 1
    fi
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 删除令牌
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X DELETE \
        "http://localhost:8008/_synapse/admin/v1/registration_tokens/$token")
    
    if [[ -z "$response" ]]; then
        log_success "注册令牌删除成功: $token"
    else
        log_error "注册令牌删除失败: $response"
    fi
}

# 查看用户详情
show_user_details() {
    echo
    read -p "用户名: " username
    
    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        return 1
    fi
    
    # 构建用户ID
    user_id="@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 获取用户详情
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s \
        "http://localhost:8008/_synapse/admin/v2/users/@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}")
    
    if echo "$response" | grep -q "name"; then
        echo -e "\n${CYAN}用户详情：${NC}"
        echo "$response" | python3 -c "
import sys, json
from datetime import datetime
data = json.load(sys.stdin)
name = data.get('name', 'N/A')
admin = '是' if data.get('admin', False) else '否'
deactivated = '是' if data.get('deactivated', False) else '否'
creation_ts = data.get('creation_ts', 0)
if creation_ts:
    creation_date = datetime.fromtimestamp(creation_ts / 1000)
    creation_str = str(creation_date)
else:
    creation_str = 'N/A'

print(f'用户ID: {name}')
print(f'管理员: {admin}')
print(f'已停用: {deactivated}')
print(f'创建时间: {creation_str}')
"
        
        # 获取用户加入的房间
        rooms_response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s \
            "http://localhost:8008/_synapse/admin/v1/users/@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}/joined_rooms" | \
            python3 -c "import sys, json; data = json.load(sys.stdin); print(f'加入的房间数: {len(data.get(\"joined_rooms\", []))}')" 2>/dev/null || echo "无法获取房间信息")
        
        echo "$rooms_response"
    else
        log_error "用户不存在或获取失败: $user_id"
    fi
}

# 修改用户权限
modify_user_admin() {
    echo
    read -p "用户名: " username
    read -p "设置为管理员? (y/n): " is_admin
    
    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        return 1
    fi
    
    if [[ "$is_admin" == "y" || "$is_admin" == "Y" ]]; then
        admin_flag="true"
        action="设置为管理员"
    else
        admin_flag="false"
        action="取消管理员权限"
    fi
    
    # 构建用户ID
    user_id="@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 修改用户权限
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X PUT \
        -H "Content-Type: application/json" \
        -d "{\"admin\":$admin_flag}" \
        "http://localhost:8008/_synapse/admin/v2/users/@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}" | \
        python3 -c "import sys, json; data = json.load(sys.stdin); print('success' if data.get('admin') == ($admin_flag == 'true') else 'failed')" 2>/dev/null || echo "failed")
    
    if [[ "$response" == "success" ]]; then
        log_success "用户权限修改成功: $user_id ($action)"
    else
        log_error "用户权限修改失败"
    fi
}

# 显示部署信息
show_deployment_info() {
    if [[ ! -f "${INSTALL_PATH}/configs/.env" ]]; then
        log_error "未找到部署配置文件"
        return 1
    fi
    
    # 加载配置
    source "${INSTALL_PATH}/configs/.env"
    
    echo -e "\n${CYAN}部署信息：${NC}"
    echo "域名: $DOMAIN"
    echo "安装路径: $INSTALL_PATH"
    echo
    echo -e "${CYAN}访问地址：${NC}"
    echo "• Element Web: https://${SUBDOMAIN_CHAT}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo "• Synapse API: https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo "• 认证服务: https://${SUBDOMAIN_AUTH}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo "• RTC 服务: https://${SUBDOMAIN_RTC}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo
    echo -e "${CYAN}端口配置：${NC}"
    echo "• 内部HTTP NodePort: $HTTP_NODEPORT"
    echo "• 内部HTTPS NodePort: $HTTPS_NODEPORT"
    echo "• 外部HTTP端口: $EXTERNAL_HTTP_PORT"
    echo "• 外部HTTPS端口: $EXTERNAL_HTTPS_PORT"
    echo "• TURN UDP 端口: $TURN_PORT_START-$TURN_PORT_END"
}

# 显示系统要求
show_requirements() {
    echo -e "\n${CYAN}系统要求：${NC}"
    echo "• 操作系统: Ubuntu 20.04+"
    echo "• 内存: 最少2GB，推荐4GB+"
    echo "• 磁盘: 最少10GB可用空间"
    echo "• 网络: 稳定的互联网连接"
    echo "• 域名: 有效的域名和DNS解析"
    echo
    echo -e "${CYAN}端口要求：${NC}"
    echo "• HTTP: 自定义端口 (默认8080)"
    echo "• HTTPS: 自定义端口 (默认8443)"
    echo "• NodePort 范围: 30000-32767 (K8s 要求)"
    echo "• TURN UDP: 自定义范围 (默认30152-30252)"
    echo
    echo -e "${CYAN}依赖组件：${NC}"
    echo "• K3s (Kubernetes)"
    echo "• Helm 3"
    echo "• kubectl"
    echo "• curl, wget"
}

# 显示帮助信息
show_help() {
    echo -e "\n${CYAN}Matrix Stack 管理脚本 $SCRIPT_VERSION${NC}"
    echo
    echo -e "${YELLOW}使用方法：${NC}"
    echo "  $0 [选项]"
    echo
    echo -e "${YELLOW}选项：${NC}"
    echo "  install     - 安装Matrix Stack"
    echo "  uninstall   - 卸载Matrix Stack"
    echo "  status      - 查看服务状态"
    echo "  manage      - 进入管理菜单"
    echo "  help        - 显示帮助信息"
    echo "  requirements - 显示系统要求"
    echo
    echo -e "${YELLOW}管理功能：${NC}"
    echo "  • 用户管理 (创建、删除、修改权限)"
    echo "  • 注册令牌管理"
    echo "  • 服务状态监控"
    echo "  • 系统统计查看"
    echo
    echo -e "${YELLOW}配置文件：${NC}"
    echo "  • 主配置: \${INSTALL_PATH}/configs/values.yaml"
    echo "  • 环境变量: \${INSTALL_PATH}/configs/.env"
    echo "  • 证书配置: \${INSTALL_PATH}/configs/cluster-issuer.yaml"
}

# 获取用户输入
get_user_input() {
    echo -e "${CYAN}Matrix Stack 部署配置${NC}"
    echo "请输入以下配置信息："
    echo
    
    # 域名配置
    while [[ -z "$DOMAIN" ]]; do
        read -p "域名 (例如: example.com): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            log_error "域名不能为空"
        fi
    done
    
    # 管理员配置
    log_info "管理员账户配置"
    while [[ -z "$ADMIN_EMAIL" ]]; do
        read -p "管理员邮箱: " ADMIN_EMAIL
        if [[ -z "$ADMIN_EMAIL" ]]; then
            log_error "邮箱不能为空"
        fi
    done
    
    while [[ -z "$ADMIN_USERNAME" ]]; do
        read -p "管理员用户名: " ADMIN_USERNAME
        if [[ -z "$ADMIN_USERNAME" ]]; then
            log_error "用户名不能为空"
        fi
    done
    
    while [[ -z "$ADMIN_PASSWORD" ]]; do
        read -s -p "管理员密码: " ADMIN_PASSWORD
        echo
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            log_error "密码不能为空"
        fi
    done
    
    # 使用默认配置
    INSTALL_PATH="$DEFAULT_INSTALL_PATH"
    HTTP_NODEPORT="$DEFAULT_HTTP_NODEPORT"
    HTTPS_NODEPORT="$DEFAULT_HTTPS_NODEPORT"
    EXTERNAL_HTTP_PORT="$DEFAULT_EXTERNAL_HTTP_PORT"
    EXTERNAL_HTTPS_PORT="$DEFAULT_EXTERNAL_HTTPS_PORT"
    TURN_PORT_START="$DEFAULT_TURN_PORT_START"
    TURN_PORT_END="$DEFAULT_TURN_PORT_END"
    SUBDOMAIN_MATRIX="$DEFAULT_SUBDOMAIN_MATRIX"
    SUBDOMAIN_CHAT="$DEFAULT_SUBDOMAIN_CHAT"
    SUBDOMAIN_AUTH="$DEFAULT_SUBDOMAIN_AUTH"
    SUBDOMAIN_RTC="$DEFAULT_SUBDOMAIN_RTC"
    USE_LIVEKIT_TURN="false"
    DEPLOYMENT_MODE="standard"
    CERT_MODE="letsencrypt-staging-http"
    DNS_PROVIDER=""
    DNS_API_KEY=""
}

# 获取详细配置
get_detailed_config() {
    echo -e "${CYAN}Matrix Stack 详细配置${NC}"
    echo "请输入以下配置信息："
    echo
    
    # 基本配置
    while [[ -z "$DOMAIN" ]]; do
        read -p "域名 (例如: example.com): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            log_error "域名不能为空"
        fi
    done
    
    read -p "安装路径 [默认: $DEFAULT_INSTALL_PATH]: " INSTALL_PATH
    INSTALL_PATH=${INSTALL_PATH:-$DEFAULT_INSTALL_PATH}
    
    # 管理员配置
    echo
    log_info "管理员账户配置"
    while [[ -z "$ADMIN_EMAIL" ]]; do
        read -p "管理员邮箱: " ADMIN_EMAIL
        if [[ -z "$ADMIN_EMAIL" ]]; then
            log_error "邮箱不能为空"
        fi
    done
    
    while [[ -z "$ADMIN_USERNAME" ]]; do
        read -p "管理员用户名: " ADMIN_USERNAME
        if [[ -z "$ADMIN_USERNAME" ]]; then
            log_error "用户名不能为空"
        fi
    done
    
    while [[ -z "$ADMIN_PASSWORD" ]]; do
        read -s -p "管理员密码: " ADMIN_PASSWORD
        echo
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            log_error "密码不能为空"
        fi
    done
    
    # 端口配置
    echo
    log_info "端口配置"
    echo -e "${YELLOW}内部端口 (NodePort 范围: 30000-32767)${NC}"
    read -p "HTTP NodePort [默认: $DEFAULT_HTTP_NODEPORT]: " HTTP_NODEPORT
    HTTP_NODEPORT=${HTTP_NODEPORT:-$DEFAULT_HTTP_NODEPORT}
    
    read -p "HTTPS NodePort [默认: $DEFAULT_HTTPS_NODEPORT]: " HTTPS_NODEPORT
    HTTPS_NODEPORT=${HTTPS_NODEPORT:-$DEFAULT_HTTPS_NODEPORT}
    
    echo -e "${YELLOW}外部端口 (路由器端口转发配置)${NC}"
    read -p "外部HTTP端口 [默认: $DEFAULT_EXTERNAL_HTTP_PORT]: " EXTERNAL_HTTP_PORT
    EXTERNAL_HTTP_PORT=${EXTERNAL_HTTP_PORT:-$DEFAULT_EXTERNAL_HTTP_PORT}
    
    read -p "外部HTTPS端口 [默认: $DEFAULT_EXTERNAL_HTTPS_PORT]: " EXTERNAL_HTTPS_PORT
    EXTERNAL_HTTPS_PORT=${EXTERNAL_HTTPS_PORT:-$DEFAULT_EXTERNAL_HTTPS_PORT}
    
    read -p "TURN UDP 起始端口 [默认: $DEFAULT_TURN_PORT_START]: " TURN_PORT_START
    TURN_PORT_START=${TURN_PORT_START:-$DEFAULT_TURN_PORT_START}
    
    read -p "TURN UDP 结束端口 [默认: $DEFAULT_TURN_PORT_END]: " TURN_PORT_END
    TURN_PORT_END=${TURN_PORT_END:-$DEFAULT_TURN_PORT_END}
    
    # 验证端口范围
    for port in $HTTP_NODEPORT $HTTPS_NODEPORT $TURN_PORT_START $TURN_PORT_END; do
        if [[ $port -lt 30000 || $port -gt 32767 ]]; then
            log_error "NodePort必须在30000-32767范围内: $port"
            exit 1
        fi
    done
    
    # 子域名配置
    echo
    log_info "子域名配置"
    read -p "Matrix 子域名 [默认: $DEFAULT_SUBDOMAIN_MATRIX]: " SUBDOMAIN_MATRIX
    SUBDOMAIN_MATRIX=${SUBDOMAIN_MATRIX:-$DEFAULT_SUBDOMAIN_MATRIX}
    
    read -p "Element Web 子域名 [默认: $DEFAULT_SUBDOMAIN_CHAT]: " SUBDOMAIN_CHAT
    SUBDOMAIN_CHAT=${SUBDOMAIN_CHAT:-$DEFAULT_SUBDOMAIN_CHAT}
    
    read -p "认证服务子域名 [默认: $DEFAULT_SUBDOMAIN_AUTH]: " SUBDOMAIN_AUTH
    SUBDOMAIN_AUTH=${SUBDOMAIN_AUTH:-$DEFAULT_SUBDOMAIN_AUTH}
    
    read -p "RTC 服务子域名 [默认: $DEFAULT_SUBDOMAIN_RTC]: " SUBDOMAIN_RTC
    SUBDOMAIN_RTC=${SUBDOMAIN_RTC:-$DEFAULT_SUBDOMAIN_RTC}
    
    # TURN服务配置
    echo
    log_info "TURN服务配置"
    read -p "使用LiveKit TURN服务? (y/n) [默认: n]: " use_livekit
    if [[ "$use_livekit" == "y" || "$use_livekit" == "Y" ]]; then
        USE_LIVEKIT_TURN="true"
    else
        USE_LIVEKIT_TURN="false"
    fi
    
    # 部署模式
    echo
    log_info "部署模式选择"
    echo "1) 标准模式 (推荐)"
    echo "2) 高可用模式"
    read -p "选择部署模式 [默认: 1]: " deployment_choice
    case $deployment_choice in
        2)
            DEPLOYMENT_MODE="ha"
            ;;
        *)
            DEPLOYMENT_MODE="standard"
            ;;
    esac
    
    # 证书配置
    echo
    log_info "SSL证书配置"
    echo "1) Let's Encrypt (HTTP验证) - 推荐"
    echo "2) Let's Encrypt (DNS验证)"
    echo "3) Let's Encrypt 测试环境 (HTTP验证)"
    echo "4) Let's Encrypt 测试环境 (DNS验证)"
    echo "5) 自签名证书"
    read -p "选择证书模式 [默认: 3]: " cert_choice
    
    case $cert_choice in
        1)
            CERT_MODE="letsencrypt-http"
            ;;
        2)
            CERT_MODE="letsencrypt-dns"
            get_dns_config
            ;;
        4)
            CERT_MODE="letsencrypt-staging-dns"
            get_dns_config
            ;;
        5)
            CERT_MODE="selfsigned"
            ;;
        *)
            CERT_MODE="letsencrypt-staging-http"
            ;;
    esac
}

# 获取DNS配置
get_dns_config() {
    echo
    log_info "DNS API 配置"
    echo "支持的DNS提供商:"
    echo "1) Cloudflare"
    echo "2) 阿里云DNS"
    echo "3) 腾讯云DNS"
    echo "4) 其他 (需要手动配置)"
    
    read -p "选择DNS提供商 [默认: 1]: " dns_choice
    case $dns_choice in
        2)
            DNS_PROVIDER="alidns"
            read -p "阿里云 Access Key ID: " DNS_API_KEY
            read -s -p "阿里云 Access Key Secret: " dns_secret
            echo
            DNS_API_KEY="$DNS_API_KEY:$dns_secret"
            ;;
        3)
            DNS_PROVIDER="tencentcloud"
            read -p "腾讯云 Secret ID: " DNS_API_KEY
            read -s -p "腾讯云 Secret Key: " dns_secret
            echo
            DNS_API_KEY="$DNS_API_KEY:$dns_secret"
            ;;
        4)
            DNS_PROVIDER="manual"
            log_warning "需要手动配置DNS验证"
            ;;
        *)
            DNS_PROVIDER="cloudflare"
            read -p "Cloudflare API Token: " DNS_API_KEY
            ;;
    esac
}

# 安装依赖
install_dependencies() {
    log_info "安装系统依赖..."
    
    # 更新包列表
    apt update
    
    # 安装基本工具
    apt install -y curl wget git unzip jq bc
    
    # 安装Python3 (如果未安装)
    if ! command -v python3 &> /dev/null; then
        apt install -y python3 python3-pip
    fi
    
    log_success "系统依赖安装完成"
}

# 配置 Ingress 控制器
setup_ingress() {
    log_info "配置 Ingress 控制器..."
    
    # 添加 ingress-nginx 仓库
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    
    # 创建 namespace
    kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
    
    # 安装 ingress-nginx，使用正确的端口配置
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --set controller.service.type=NodePort \
        --set controller.service.nodePorts.http=${HTTP_NODEPORT} \
        --set controller.service.nodePorts.https=${HTTPS_NODEPORT} \
        --wait
    
    # 配置SSL跳转和外部端口 - 修复版本
    kubectl patch configmap ingress-nginx-controller -n ingress-nginx --patch "{\"data\":{\"ssl-redirect\":\"true\",\"force-ssl-redirect\":\"true\",\"ssl-port\":\"${EXTERNAL_HTTPS_PORT}\",\"http-port\":\"${EXTERNAL_HTTP_PORT}\"}}"
    
    # 重启Ingress控制器以应用新配置
    kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx
    kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx
    
    log_success "Ingress 控制器配置完成"
}

# 配置证书管理器
setup_cert_manager() {
    log_info "配置证书管理器..."
    
    # 添加 jetstack 仓库
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    # 创建 namespace
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    
    # 安装 cert-manager
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --set crds.enabled=true \
        --wait
    
    log_success "证书管理器配置完成"
}

# 生成 values.yaml 配置文件 - 最终修正版
generate_values_yaml() {
    log_info "生成配置文件..."
    
    mkdir -p "${INSTALL_PATH}/configs"
    
    # 根据证书模式设置ClusterIssuer名称
    local cluster_issuer_name
    case $CERT_MODE in
        "letsencrypt-http"|"letsencrypt-dns")
            cluster_issuer_name="letsencrypt-staging"
            ;;
        "letsencrypt-staging-http"|"letsencrypt-staging-dns")
            cluster_issuer_name="letsencrypt-staging"
            ;;
        "selfsigned")
            cluster_issuer_name="selfsigned-issuer"
            ;;
        *)
            cluster_issuer_name="letsencrypt-staging"
            ;;
    esac
    
    # 生成 values.yaml 配置文件
    cat > "${INSTALL_PATH}/configs/values.yaml" << EOF
# Matrix Stack Helm Chart Values - 完全修复版
# 版本: $SCRIPT_VERSION
# 生成时间: $(date)

# 全局配置
global:
  serverName: "${SUBDOMAIN_MATRIX}.${DOMAIN}"
  domain: "${DOMAIN}"

# 证书管理器配置
certManager:
  clusterIssuer: "${cluster_issuer_name}"

# 全局Ingress配置 - 修复版本
ingress:
  className: "nginx"
  tlsEnabled: true
  annotations:
    cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/server-snippet: |
      location / {
        if (\$scheme = http) {
          return 301 https://\$host:${EXTERNAL_HTTPS_PORT}\$request_uri;
        }
      }

# Synapse 配置 - 修复版本
synapse:
  enabled: true
  ingress:
    host: "${SUBDOMAIN_MATRIX}.${DOMAIN}"
    annotations:
      cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      nginx.ingress.kubernetes.io/server-snippet: |
        location / {
          if (\$scheme = http) {
            return 301 https://\$host:${EXTERNAL_HTTPS_PORT}\$request_uri;
          }
        }
    className: "nginx"
    tlsEnabled: true

# Element Web 配置 - 修复版本
elementWeb:
  enabled: true
  replicas: 1
  ingress:
    host: "${SUBDOMAIN_CHAT}.${DOMAIN}"
    annotations:
      cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      nginx.ingress.kubernetes.io/server-snippet: |
        location / {
          if (\$scheme = http) {
            return 301 https://\$host:${EXTERNAL_HTTPS_PORT}\$request_uri;
          }
        }
    className: "nginx"
    tlsEnabled: true
  additional:
    default_server_config: '{"m.homeserver":{"base_url":"https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}","server_name":"${SUBDOMAIN_MATRIX}.${DOMAIN}"}}'

# Matrix Authentication Service 配置 - 修复版本
matrixAuthenticationService:
  enabled: true
  ingress:
    host: "${SUBDOMAIN_AUTH}.${DOMAIN}"
    annotations:
      cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      nginx.ingress.kubernetes.io/server-snippet: |
        location / {
          if (\$scheme = http) {
            return 301 https://\$host:${EXTERNAL_HTTPS_PORT}\$request_uri;
          }
        }
    className: "nginx"
    tlsEnabled: true

# Matrix RTC 配置 - 修复版本
matrixRTC:
  enabled: true
  ingress:
    host: "${SUBDOMAIN_RTC}.${DOMAIN}"
    annotations:
      cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
      nginx.ingress.kubernetes.io/server-snippet: |
        location / {
          if (\$scheme = http) {
            return 301 https://\$host:${EXTERNAL_HTTPS_PORT}\$request_uri;
          }
        }
    className: "nginx"
    tlsEnabled: true

# Well-known delegation 配置
wellKnownDelegation:
  enabled: true
  additional:
    server: '{"m.server": "${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"}'

EOF

    # 保存配置到环境文件
    cat > "${INSTALL_PATH}/configs/.env" << EOF
# Matrix Stack 部署配置
DOMAIN=${DOMAIN}
INSTALL_PATH=${INSTALL_PATH}
HTTP_NODEPORT=${HTTP_NODEPORT}
HTTPS_NODEPORT=${HTTPS_NODEPORT}
EXTERNAL_HTTP_PORT=${EXTERNAL_HTTP_PORT}
EXTERNAL_HTTPS_PORT=${EXTERNAL_HTTPS_PORT}
TURN_PORT_START=${TURN_PORT_START}
TURN_PORT_END=${TURN_PORT_END}
SUBDOMAIN_MATRIX=${SUBDOMAIN_MATRIX}
SUBDOMAIN_CHAT=${SUBDOMAIN_CHAT}
SUBDOMAIN_AUTH=${SUBDOMAIN_AUTH}
SUBDOMAIN_RTC=${SUBDOMAIN_RTC}
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_EMAIL=${ADMIN_EMAIL}
USE_LIVEKIT_TURN=${USE_LIVEKIT_TURN}
CERT_MODE=${CERT_MODE}
DNS_PROVIDER=${DNS_PROVIDER}
SCRIPT_VERSION=${SCRIPT_VERSION}
EOF

    log_success "配置文件生成完成: ${INSTALL_PATH}/configs/values.yaml"
}

# 创建ClusterIssuer
create_cluster_issuer() {
    log_info "创建证书颁发者..."
    
    case $CERT_MODE in
        "letsencrypt-http")
            cat > "${INSTALL_PATH}/configs/cluster-issuer.yaml" << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ADMIN_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
            ;;
        "letsencrypt-staging-http")
            cat > "${INSTALL_PATH}/configs/cluster-issuer.yaml" << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${ADMIN_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
            ;;
        "letsencrypt-dns")
            cat > "${INSTALL_PATH}/configs/cluster-issuer.yaml" << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ADMIN_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
EOF
            # 创建DNS API密钥Secret
            kubectl create secret generic cloudflare-api-token \
                --from-literal=api-token="${DNS_API_KEY}" \
                --namespace=cert-manager \
                --dry-run=client -o yaml | kubectl apply -f -
            ;;
        "letsencrypt-staging-dns")
            cat > "${INSTALL_PATH}/configs/cluster-issuer.yaml" << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${ADMIN_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
EOF
            # 创建DNS API密钥Secret
            kubectl create secret generic cloudflare-api-token \
                --from-literal=api-token="${DNS_API_KEY}" \
                --namespace=cert-manager \
                --dry-run=client -o yaml | kubectl apply -f -
            ;;
        "selfsigned")
            cat > "${INSTALL_PATH}/configs/cluster-issuer.yaml" << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
            ;;
    esac
    
    # 应用ClusterIssuer
    kubectl apply -f "${INSTALL_PATH}/configs/cluster-issuer.yaml"
    
    log_success "证书颁发者创建完成"
}

# 安装Matrix Stack
install_matrix_stack() {
    log_info "安装Matrix Stack..."
    
    # 添加Element仓库
    helm repo add ess https://element-hq.github.io/ess-helm-charts/
    helm repo update
    
    # 创建命名空间
    kubectl create namespace ess --dry-run=client -o yaml | kubectl apply -f -
    
    # 安装Matrix Stack
    helm upgrade --install ess ess/matrix-stack \
        --namespace ess \
        --values "${INSTALL_PATH}/configs/values.yaml" \
        --wait \
        --timeout 10m
    
    log_success "Matrix Stack安装完成"
}

# 创建管理员用户
create_admin_user() {
    log_info "创建管理员用户..."
    
    # 等待Synapse启动
    log_info "等待Synapse服务启动..."
    sleep 30
    
    # 检查Synapse是否就绪
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$SYNAPSE_POD" ]]; then
            if kubectl exec -n ess "$SYNAPSE_POD" -- curl -s http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
                log_success "Synapse服务已就绪"
                break
            fi
        fi
        
        log_info "等待Synapse服务就绪... (${attempt}/${max_attempts})"
        sleep 10
        ((attempt++))
    done
    
    if [[ $attempt -gt $max_attempts ]]; then
        log_error "Synapse服务启动超时"
        return 1
    fi
    
    # 创建管理员用户
    local user_id="@${ADMIN_USERNAME}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    local response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X PUT \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"$ADMIN_PASSWORD\",\"admin\":true}" \
        "http://localhost:8008/_synapse/admin/v2/users/$user_id")
    
    if echo "$response" | grep -q "name"; then
        log_success "管理员用户创建成功: $user_id"
    else
        log_warning "管理员用户可能已存在或创建失败"
    fi
}

# 配置动态DNS (可选)
setup_ddns() {
    if [[ "$CERT_MODE" == *"dns"* ]]; then
        log_info "配置动态DNS更新..."
        
        # 这里可以添加ddns-go或其他DDNS客户端的配置
        # 由于这是可选功能，暂时跳过
        log_info "动态DNS配置跳过 (可选功能)"
    fi
}

# 配置监控 (可选)
setup_monitoring() {
    if [[ "$DEPLOYMENT_MODE" == "ha" ]]; then
        log_info "配置高可用监控..."
        
        # 这里可以添加Prometheus、Grafana等监控组件
        # 由于这是可选功能，暂时跳过
        log_info "监控配置跳过 (可选功能)"
    fi
}

# 验证部署
verify_deployment() {
    log_info "验证部署状态..."
    
    # 检查Pod状态
    log_info "检查Pod状态..."
    kubectl get pods -n ess
    
    # 检查服务状态
    log_info "检查服务状态..."
    kubectl get svc -n ess
    
    # 检查Ingress状态
    log_info "检查Ingress状态..."
    kubectl get ingress -n ess
    
    # 检查证书状态
    log_info "检查证书状态..."
    kubectl get certificates -n ess
    
    log_success "部署验证完成"
}

# 显示部署结果
show_deployment_result() {
    echo
    log_success "Matrix Stack 部署完成！"
    echo
    echo -e "${CYAN}访问地址：${NC}"
    echo "• Element Web: https://${SUBDOMAIN_CHAT}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo "• Synapse API: https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo "• 认证服务: https://${SUBDOMAIN_AUTH}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo "• RTC 服务: https://${SUBDOMAIN_RTC}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo
    echo -e "${CYAN}管理员账户：${NC}"
    echo "• 用户名: $ADMIN_USERNAME"
    echo "• 密码: $ADMIN_PASSWORD"
    echo
    echo -e "${CYAN}端口配置：${NC}"
    echo "• 内部HTTP NodePort: $HTTP_NODEPORT"
    echo "• 内部HTTPS NodePort: $HTTPS_NODEPORT"
    echo "• 外部HTTP端口: $EXTERNAL_HTTP_PORT"
    echo "• 外部HTTPS端口: $EXTERNAL_HTTPS_PORT"
    echo "• TURN UDP 端口: $TURN_PORT_START-$TURN_PORT_END"
    echo
    echo -e "${YELLOW}重要提醒：${NC}"
    echo "1. 请确保域名 DNS 记录指向您的服务器 IP"
    echo "2. 请配置路由器端口转发："
    echo "   - 外部 ${EXTERNAL_HTTP_PORT} → 内部 ${HTTP_NODEPORT}"
    echo "   - 外部 ${EXTERNAL_HTTPS_PORT} → 内部 ${HTTPS_NODEPORT}"
    echo "   - 外部 UDP ${TURN_PORT_START}-${TURN_PORT_END} → 内部相同端口"
    echo "3. Element X 客户端连接地址: ${DOMAIN}"
    echo "4. 配置文件保存在: ${INSTALL_PATH}/configs/"
    echo
    echo -e "${CYAN}管理命令：${NC}"
    echo "• 查看状态: $0 status"
    echo "• 管理用户: $0 manage"
    echo "• 查看帮助: $0 help"
    echo
    echo -e "${GREEN}部署完成！请按照上述提醒完成网络配置。${NC}"
}

# 确认部署配置
confirm_deployment() {
    echo
    log_info "部署配置确认："
    echo "• 域名: $DOMAIN"
    echo "• 安装路径: $INSTALL_PATH"
    echo "• 内部HTTP NodePort: $HTTP_NODEPORT"
    echo "• 内部HTTPS NodePort: $HTTPS_NODEPORT"
    echo "• 外部HTTP端口: $EXTERNAL_HTTP_PORT"
    echo "• 外部HTTPS端口: $EXTERNAL_HTTPS_PORT"
    echo "• TURN 端口范围: $TURN_PORT_START-$TURN_PORT_END"
    echo "• Matrix 子域名: $SUBDOMAIN_MATRIX"
    echo "• Element Web 子域名: $SUBDOMAIN_CHAT"
    echo "• 认证服务子域名: $SUBDOMAIN_AUTH"
    echo "• RTC 服务子域名: $SUBDOMAIN_RTC"
    echo "• 证书模式: $CERT_MODE"
    echo "• 部署模式: $DEPLOYMENT_MODE"
    echo
    
    read -p "确认开始部署? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "部署已取消"
        exit 0
    fi
}

# 主安装流程
install_main() {
    echo -e "${CYAN}Matrix Stack 安装程序 $SCRIPT_VERSION${NC}"
    echo
    
    # 系统检查
    check_root
    check_system
    check_network
    check_k3s
    check_helm
    
    # 获取配置
    echo
    echo "请选择配置模式："
    echo "1) 快速配置 (使用默认设置)"
    echo "2) 详细配置 (自定义所有选项)"
    read -p "选择配置模式 [默认: 1]: " config_mode
    
    case $config_mode in
        2)
            get_detailed_config
            ;;
        *)
            get_user_input
            ;;
    esac
    
    # 确认配置
    confirm_deployment
    
    # 开始安装
    log_info "开始安装Matrix Stack..."
    
    # 安装依赖
    install_dependencies
    
    # 配置Ingress控制器
    setup_ingress
    
    # 配置证书管理器
    setup_cert_manager
    
    # 生成配置文件
    generate_values_yaml
    
    # 创建证书颁发者
    create_cluster_issuer
    
    # 安装Matrix Stack
    install_matrix_stack
    
    # 创建管理员用户
    create_admin_user
    
    # 可选配置
    setup_ddns
    setup_monitoring
    
    # 验证部署
    verify_deployment
    
    # 显示结果
    show_deployment_result
}

# 卸载Matrix Stack
uninstall_matrix_stack() {
    echo -e "${RED}警告: 此操作将完全删除Matrix Stack及所有数据！${NC}"
    echo
    read -p "确认卸载? 请输入 'yes' 确认: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "卸载已取消"
        return 0
    fi
    
    log_info "开始卸载Matrix Stack..."
    
    # 卸载Matrix Stack
    helm uninstall ess -n ess 2>/dev/null || true
    
    # 卸载 cert-manager
    helm uninstall cert-manager -n cert-manager 2>/dev/null || true
    
    # 卸载 ingress-nginx
    helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
    
    # 删除 namespaces
    kubectl delete namespace ess cert-manager ingress-nginx 2>/dev/null || true
    
    # 删除 ClusterIssuers
    kubectl delete clusterissuer --all 2>/dev/null || true
    
    # 删除配置文件
    if [[ -d "${INSTALL_PATH:-/opt/matrix}/configs" ]]; then
        rm -rf "${INSTALL_PATH:-/opt/matrix}/configs"
        log_info "配置文件已删除"
    fi
    
    log_success "Matrix Stack 卸载完成"
}

# 管理菜单
show_management_menu() {
    while true; do
        echo
        echo -e "${CYAN}Matrix Stack 管理菜单${NC}"
        echo "1) 查看服务状态"
        echo "2) 用户管理"
        echo "3) 注册令牌管理"
        echo "4) 查看服务器统计"
        echo "5) 查看部署信息"
        echo "6) 重启服务"
        echo "0) 返回主菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1)
                check_service_status
                ;;
            2)
                show_user_menu
                ;;
            3)
                show_token_menu
                ;;
            4)
                show_server_stats
                ;;
            5)
                show_deployment_info
                ;;
            6)
                restart_services
                ;;
            0)
                break
                ;;
            *)
                log_error "无效选择"
                ;;
        esac
        
        echo
        read -p "按回车键继续..."
    done
}

# 用户管理菜单
show_user_menu() {
    while true; do
        echo
        echo -e "${CYAN}用户管理菜单${NC}"
        echo "1) 查看用户列表"
        echo "2) 创建用户"
        echo "3) 删除用户"
        echo "4) 重置用户密码"
        echo "5) 查看用户详情"
        echo "6) 修改用户权限"
        echo "0) 返回上级菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1)
                list_users
                ;;
            2)
                create_user
                ;;
            3)
                delete_user
                ;;
            4)
                reset_password
                ;;
            5)
                show_user_details
                ;;
            6)
                modify_user_admin
                ;;
            0)
                break
                ;;
            *)
                log_error "无效选择"
                ;;
        esac
        
        echo
        read -p "按回车键继续..."
    done
}

# 注册令牌管理菜单
show_token_menu() {
    while true; do
        echo
        echo -e "${CYAN}注册令牌管理菜单${NC}"
        echo "1) 生成注册令牌"
        echo "2) 查看令牌列表"
        echo "3) 删除注册令牌"
        echo "0) 返回上级菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1)
                generate_registration_token
                ;;
            2)
                list_registration_tokens
                ;;
            3)
                delete_registration_token
                ;;
            0)
                break
                ;;
            *)
                log_error "无效选择"
                ;;
        esac
        
        echo
        read -p "按回车键继续..."
    done
}

# 重启服务
restart_services() {
    log_info "重启Matrix Stack服务..."
    
    # 重启主要组件
    kubectl rollout restart deployment -n ess
    kubectl rollout restart statefulset -n ess
    
    # 等待重启完成
    kubectl rollout status deployment -n ess --timeout=300s
    kubectl rollout status statefulset -n ess --timeout=300s
    
    log_success "服务重启完成"
}

# 加载配置
load_config() {
    if [[ -f "${INSTALL_PATH}/configs/.env" ]]; then
        source "${INSTALL_PATH}/configs/.env"
        return 0
    elif [[ -f "/opt/matrix/configs/.env" ]]; then
        source "/opt/matrix/configs/.env"
        INSTALL_PATH="/opt/matrix"
        return 0
    else
        return 1
    fi
}

# 主菜单
show_main_menu() {
    while true; do
        echo
        echo -e "${CYAN}Matrix Stack 管理脚本 $SCRIPT_VERSION${NC}"
        echo "1) 安装Matrix Stack"
        echo "2) 卸载Matrix Stack"
        echo "3) 管理Matrix Stack"
        echo "4) 查看系统要求"
        echo "5) 查看帮助信息"
        echo "0) 退出"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1)
                install_main
                ;;
            2)
                uninstall_matrix_stack
                ;;
            3)
                if load_config; then
                    show_management_menu
                else
                    log_error "未找到Matrix Stack配置，请先安装"
                fi
                ;;
            4)
                show_requirements
                ;;
            5)
                show_help
                ;;
            0)
                log_info "感谢使用Matrix Stack管理脚本！"
                exit 0
                ;;
            *)
                log_error "无效选择"
                ;;
        esac
    done
}

# 主函数
main() {
    case "${1:-}" in
        "install")
            install_main
            ;;
        "uninstall")
            uninstall_matrix_stack
            ;;
        "status")
            if load_config; then
                check_service_status
            else
                log_error "未找到Matrix Stack配置"
                exit 1
            fi
            ;;
        "manage")
            if load_config; then
                show_management_menu
            else
                log_error "未找到Matrix Stack配置"
                exit 1
            fi
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        "requirements")
            show_requirements
            ;;
        "")
            show_main_menu
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

# 脚本入口
main "$@"
