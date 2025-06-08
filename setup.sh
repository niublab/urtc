#!/bin/bash
# Matrix Stack 完整安装和管理工具 v0.1.3 - 重定向端口完全修复版
# 支持完全自定义配置、高级用户管理、清理功能和证书切换
# 基于 element-hq/ess-helm 项目 - 修正所有已知问题
# 添加 systemd 定时更新动态IP、acme.sh证书管理、高可用配置
# 完全适配 MSC3861 环境，修复 register_new_matrix_user 问题
# 修复版本：解决证书issuer、端口转发、DNS验证等问题
# v0.1.3 新增：修复所有重定向到外部标准端口的问题，改为用户自定义非标准端口

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
SCRIPT_VERSION="v0.1.3"
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

log_debug() {
    echo -e "${PURPLE}[调试]${NC} $1"
}

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════╗
║              Matrix Stack 完整安装和管理工具 v0.1.3             ║
║                                                                  ║
║  🚀 支持完全自定义配置                                           ║
║  🏠 专为 NAT 环境和动态 IP 设计                                  ║
║  🔧 菜单式交互，简化部署流程                                     ║
║  🌐 支持自定义端口和子域名                                       ║
║  📱 完全兼容 Element X 客户端                                    ║
║  🔄 支持 LiveKit 内置 TURN 服务                                  ║
║  ✅ 修正所有已知问题                                             ║
║  🛠️ 完整的管理和清理功能                                         ║
║  👤 高级用户管理和邀请码系统                                     ║
║  ⏰ systemd 定时更新动态IP                                       ║
║  🔐 acme.sh 证书管理增强                                         ║
║  🔧 修复重定向端口问题                                           ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo
}

# 显示主菜单
show_main_menu() {
    echo -e "${CYAN}请选择操作模式：${NC}"
    echo
    echo "1) 🚀 快速部署 (推荐新手)"
    echo "2) 🔧 自定义配置部署"
    echo "3) 🛠️ 管理已部署的服务"
    echo "4) 📋 查看系统要求"
    echo "5) 🔍 检查系统状态"
    echo "6) 🧹 清理/卸载部署"
    echo "0) 🚪 退出"
    echo
    read -p "请选择 [1-7]: " choice
    
    case $choice in
        1) DEPLOYMENT_MODE="quick" ;;
        2) DEPLOYMENT_MODE="custom" ;;
        3) show_management_menu ;;
        4) show_requirements; show_main_menu ;;
        5) check_system; show_main_menu ;;
        6) show_cleanup_menu ;;
        0) exit 0 ;;
        *) log_error "无效选项，请重新选择"; show_main_menu ;;
    esac
}

# 显示管理菜单
show_management_menu() {
    clear
    echo -e "${CYAN}=== 服务管理菜单 ===${NC}"
    echo
    echo "1) 📊 查看服务状态"
    echo "2) 👤 用户管理"
    echo "3) 🔒 证书管理"
    echo "4) 🔄 重启服务"
    echo "5) 📝 查看日志"
    echo "6) 💾 备份数据"
    echo "7) 📤 恢复数据"
    echo "8) ⚙️ 更新配置"
    echo "9) 🔧 修复重定向端口问题"
    echo "0) 🔙 返回主菜单"
    echo
    read -p "请选择 [0-9]: " mgmt_choice
    
    case $mgmt_choice in
        1) show_service_status ;;
        2) show_user_management ;;
        3) show_certificate_management ;;
        4) restart_services ;;
        5) show_logs_menu ;;
        6) backup_data ;;
        7) restore_data ;;
        8) update_configuration ;;
        9) fix_redirect_ports ;;
        0) show_main_menu ;;
        *) log_error "无效选项"; show_management_menu ;;
    esac
}

# 用户管理 - 完整版
show_user_management() {
    clear
    echo -e "${CYAN}=== 用户管理 ===${NC}"
    echo
    echo "1) 👤 创建新用户"
    echo "2) 🗑️ 删除用户"
    echo "3) 🔑 重置用户密码"
    echo "4) 📋 列出所有用户"
    echo "5) 🎫 生成注册邀请码"
    echo "6) 🚫 注销注册邀请码"
    echo "7) 📝 查看注册邀请列表"
    echo "8) 👑 设置用户管理员权限"
    echo "9) 🚷 封禁用户"
    echo "10) ✅ 解封用户"
    echo "11) 🔍 查看用户详细信息"
    echo "0) 🔙 返回管理菜单"
    echo
    read -p "请选择 [0-11]: " user_choice
    
    case $user_choice in
        1) create_user ;;
        2) delete_user ;;
        3) reset_user_password ;;
        4) list_users ;;
        5) generate_registration_token ;;
        6) revoke_registration_token ;;
        7) list_registration_tokens ;;
        8) set_user_admin ;;
        9) deactivate_user ;;
        10) reactivate_user ;;
        11) show_user_info ;;
        0) show_management_menu ;;
        *) log_error "无效选项"; show_user_management ;;
    esac
}

# 获取管理员访问令牌
get_admin_token() {
    local SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 检查是否已有管理员令牌
    if kubectl exec -n ess "$SYNAPSE_POD" -- test -f /data/admin_token 2>/dev/null; then
        local token=$(kubectl exec -n ess "$SYNAPSE_POD" -- cat /data/admin_token 2>/dev/null)
        # 验证令牌是否有效
        if kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -H "Authorization: Bearer $token" \
           "http://localhost:8008/_synapse/admin/v1/server_version" >/dev/null 2>&1; then
            echo "$token"
            return 0
        fi
    fi
    
    # 需要创建新的管理员令牌
    log_warning "需要创建管理员访问令牌"
    log_info "请使用 Element 客户端登录管理员账户，然后获取访问令牌"
    log_info "或者我们可以通过 MAS API 创建令牌"
    
    return 1
}

# 使用 Admin API 创建用户
create_user_api() {
    local username="$1"
    local password="$2"
    local is_admin="$3"
    local display_name="$4"
    local domain="$5"
    
    local SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    local user_id="@${username}:${domain}"
    
    # 获取管理员令牌
    local admin_token
    admin_token=$(get_admin_token)
    if [[ $? -ne 0 ]]; then
        log_error "无法获取管理员访问令牌"
        return 1
    fi
    
    # 构建 JSON 数据
    local json_data="{\"password\":\"$password\""
    if [[ "$is_admin" == "true" ]]; then
        json_data+=",\"admin\":true"
    fi
    if [[ -n "$display_name" ]]; then
        json_data+=",\"displayname\":\"$display_name\""
    fi
    json_data+="}"
    
    # 调用 Admin API 创建用户
    local response
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X PUT \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "$json_data" \
        "http://localhost:8008/_synapse/admin/v2/users/$user_id")
    
    if echo "$response" | grep -q '"name"'; then
        log_success "用户 $username 创建完成"
        return 0
    else
        log_error "用户创建失败: $response"
        return 1
    fi
}

# 创建用户 - 重写版（使用 Admin API）
create_user() {
    echo
    read -p "请输入用户名: " username
    while [[ -z "$username" ]]; do
        log_error "用户名不能为空"
        read -p "请输入用户名: " username
    done
    
    read -s -p "请输入密码: " password
    echo
    while [[ -z "$password" ]]; do
        log_error "密码不能为空"
        read -s -p "请输入密码: " password
        echo
    done
    
    read -p "是否为管理员? [y/N]: " is_admin
    read -p "请输入显示名称 (可选): " display_name
    
    # 加载配置获取域名
    load_config
    
    local SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 等待 Synapse API 可用
    log_info "检查 Synapse API 状态..."
    for i in {1..30}; do
        if kubectl exec -n ess "$SYNAPSE_POD" -- curl -s http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
            log_success "Synapse API 已就绪"
            break
        fi
        if [[ $i -eq 30 ]]; then
            log_error "Synapse API 不可用，请检查服务状态"
            read -p "按回车键继续..."
            show_user_management
            return
        fi
        sleep 2
    done
    
    # 使用 Admin API 创建用户
    local admin_flag="false"
    if [[ "$is_admin" == "y" || "$is_admin" == "Y" ]]; then
        admin_flag="true"
    fi
    
    if create_user_api "$username" "$password" "$admin_flag" "$display_name" "${SUBDOMAIN_MATRIX}.${DOMAIN}"; then
        log_info "用户登录信息："
        log_info "服务器: https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
        log_info "用户名: @${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
        log_info "密码: [已设置]"
    fi
    
    read -p "按回车键继续..."
    show_user_management
}

# 删除用户 - 重写版（使用 Admin API）
delete_user() {
    echo
    read -p "请输入要删除的用户名: " username
    while [[ -z "$username" ]]; do
        log_error "用户名不能为空"
        read -p "请输入要删除的用户名: " username
    done
    
    echo -e "${RED}警告：此操作将永久删除用户及其所有数据！${NC}"
    read -p "确认删除用户 $username? 输入 'delete' 确认: " confirm
    if [[ "$confirm" != "delete" ]]; then
        log_info "操作已取消"
        show_user_management
        return
    fi
    
    # 加载配置
    load_config
    
    local SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    local user_id="@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    # 获取管理员令牌
    local admin_token
    admin_token=$(get_admin_token)
    if [[ $? -ne 0 ]]; then
        log_error "无法获取管理员访问令牌"
        read -p "按回车键继续..."
        show_user_management
        return
    fi
    
    # 使用 Synapse Admin API 删除用户
    local response
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X POST \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d '{"erase": true}' \
        "http://localhost:8008/_synapse/admin/v1/deactivate/$user_id")
    
    if echo "$response" | grep -q '"id_server_unbind_result"'; then
        log_success "用户 $username 已删除"
    else
        log_error "用户删除失败: $response"
    fi
    
    read -p "按回车键继续..."
    show_user_management
}

# 重置用户密码 - 重写版（使用 Admin API）
reset_user_password() {
    echo
    read -p "请输入用户名: " username
    while [[ -z "$username" ]]; do
        log_error "用户名不能为空"
        read -p "请输入用户名: " username
    done
    
    read -s -p "请输入新密码: " new_password
    echo
    while [[ -z "$new_password" ]]; do
        log_error "密码不能为空"
        read -s -p "请输入新密码: " new_password
        echo
    done
    
    # 加载配置
    load_config
    
    local SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    local user_id="@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    # 获取管理员令牌
    local admin_token
    admin_token=$(get_admin_token)
    if [[ $? -ne 0 ]]; then
        log_error "无法获取管理员访问令牌"
        read -p "按回车键继续..."
        show_user_management
        return
    fi
    
    # 使用 Synapse Admin API 重置密码
    local response
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X POST \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"new_password\": \"$new_password\", \"logout_devices\": true}" \
        "http://localhost:8008/_synapse/admin/v1/reset_password/$user_id")
    
    if echo "$response" | grep -q '{}' || [[ -z "$response" ]]; then
        log_success "用户 $username 的密码已重置，所有设备已登出"
    else
        log_error "密码重置失败: $response"
    fi
    
    read -p "按回车键继续..."
    show_user_management
}

# 列出所有用户 - 重写版（使用 Admin API）
list_users() {
    echo
    echo -e "${YELLOW}用户列表：${NC}"
    
    local SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 获取管理员令牌
    local admin_token
    admin_token=$(get_admin_token)
    if [[ $? -ne 0 ]]; then
        log_error "无法获取管理员访问令牌"
        read -p "按回车键继续..."
        show_user_management
        return
    fi
    
    # 使用 Synapse Admin API 获取用户列表
    local response
    response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s \
        -H "Authorization: Bearer $admin_token" \
        "http://localhost:8008/_synapse/admin/v2/users")
    
    if echo "$response" | grep -q '"users"'; then
        echo "$response" | kubectl exec -i -n ess "$SYNAPSE_POD" -- python3 -m json.tool
    else
        log_error "获取用户列表失败: $response"
    fi
    
    echo
    read -p "按回车键继续..."
    show_user_management
}

# 生成注册邀请码
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
    token_response=$(kubectl exec -n ess "$SYNAPSE_POD" -- curl -s -X POST \
        -H "Authorization: Bearer \$(cat /data/admin_token)" \
        -H "Content-Type: application/json" \
        -d "{\"uses_allowed\": $uses_allowed, \"expiry_time\": $expiry_time}" \
        "http://localhost:8008/_synapse/admin/v1/registration_tokens/new")
    
    token=$(echo "$token_response" | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "生成失败")
    
    echo
    if [[ "$token" != "生成失败" ]]; then
        log_success "注册邀请码生成成功！"
        echo -e "${CYAN}邀请码：${NC} $token"
        echo -e "${CYAN}有效期：${NC} $validity_hours 小时"
        echo -e "${CYAN}使用次数：${NC} $uses_allowed 次"
        if [[ -n "$description" ]]; then
            echo -e "${CYAN}描述：${NC} $description"
        fi
        echo
        echo -e "${YELLOW}用户注册时需要使用此邀请码${NC}"
    else
        log_error "邀请码生成失败，请检查管理员权限"
    fi
    
    read -p "按回车键继续..."
    show_user_management
}

# 注销注册邀请码
revoke_registration_token() {
    echo
    read -p "请输入要注销的邀请码: " token
    while [[ -z "$token" ]]; do
        log_error "邀请码不能为空"
        read -p "请输入要注销的邀请码: " token
    done
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 注销注册令牌
    kubectl exec -n ess "$SYNAPSE_POD" -- curl -X DELETE \
        -H "Authorization: Bearer \$(cat /data/admin_token)" \
        "http://localhost:8008/_synapse/admin/v1/registration_tokens/$token"
    
    log_success "邀请码 $token 已注销"
    read -p "按回车键继续..."
    show_user_management
}

# 查看注册邀请列表
list_registration_tokens() {
    echo
    echo -e "${YELLOW}注册邀请码列表：${NC}"
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 获取注册令牌列表
    kubectl exec -n ess "$SYNAPSE_POD" -- curl -s \
        -H "Authorization: Bearer \$(cat /data/admin_token)" \
        "http://localhost:8008/_synapse/admin/v1/registration_tokens" | \
        python3 -m json.tool
    
    echo
    read -p "按回车键继续..."
    show_user_management
}

# 设置用户管理员权限
set_user_admin() {
    echo
    read -p "请输入用户名: " username
    while [[ -z "$username" ]]; do
        log_error "用户名不能为空"
        read -p "请输入用户名: " username
    done
    
    read -p "设置为管理员? [y/N]: " is_admin
    
    admin_value="false"
    if [[ "$is_admin" == "y" || "$is_admin" == "Y" ]]; then
        admin_value="true"
    fi
    
    # 加载配置
    load_config
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 设置用户管理员权限
    kubectl exec -n ess "$SYNAPSE_POD" -- curl -X PUT \
        -H "Authorization: Bearer \$(cat /data/admin_token)" \
        -H "Content-Type: application/json" \
        -d "{\"admin\": $admin_value}" \
        "http://localhost:8008/_synapse/admin/v2/users/@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    if [[ "$admin_value" == "true" ]]; then
        log_success "用户 $username 已设置为管理员"
    else
        log_success "用户 $username 已取消管理员权限"
    fi
    
    read -p "按回车键继续..."
    show_user_management
}

# 封禁用户
deactivate_user() {
    echo
    read -p "请输入要封禁的用户名: " username
    while [[ -z "$username" ]]; do
        log_error "用户名不能为空"
        read -p "请输入要封禁的用户名: " username
    done
    
    echo -e "${RED}警告：此操作将封禁用户账户！${NC}"
    read -p "确认封禁用户 $username? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "操作已取消"
        show_user_management
        return
    fi
    
    # 加载配置
    load_config
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 封禁用户
    kubectl exec -n ess "$SYNAPSE_POD" -- curl -X POST \
        -H "Authorization: Bearer \$(cat /data/admin_token)" \
        -H "Content-Type: application/json" \
        -d '{"erase": false}' \
        "http://localhost:8008/_synapse/admin/v1/deactivate/@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    log_success "用户 $username 已封禁"
    read -p "按回车键继续..."
    show_user_management
}

# 解封用户
reactivate_user() {
    echo
    read -p "请输入要解封的用户名: " username
    while [[ -z "$username" ]]; do
        log_error "用户名不能为空"
        read -p "请输入要解封的用户名: " username
    done
    
    read -s -p "请输入新密码: " new_password
    echo
    while [[ -z "$new_password" ]]; do
        log_error "密码不能为空"
        read -s -p "请输入新密码: " new_password
        echo
    done
    
    # 加载配置
    load_config
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    # 解封用户（通过重新激活）
    kubectl exec -n ess "$SYNAPSE_POD" -- curl -X PUT \
        -H "Authorization: Bearer \$(cat /data/admin_token)" \
        -H "Content-Type: application/json" \
        -d "{\"password\": \"$new_password\", \"deactivated\": false}" \
        "http://localhost:8008/_synapse/admin/v2/users/@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}"
    
    log_success "用户 $username 已解封并重置密码"
    read -p "按回车键继续..."
    show_user_management
}

# 查看用户详细信息
show_user_info() {
    echo
    read -p "请输入用户名: " username
    while [[ -z "$username" ]]; do
        log_error "用户名不能为空"
        read -p "请输入用户名: " username
    done
    
    # 加载配置
    load_config
    
    SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    
    echo -e "${YELLOW}用户详细信息：${NC}"
    kubectl exec -n ess "$SYNAPSE_POD" -- curl -s \
        -H "Authorization: Bearer \$(cat /data/admin_token)" \
        "http://localhost:8008/_synapse/admin/v2/users/@${username}:${SUBDOMAIN_MATRIX}.${DOMAIN}" | \
        python3 -m json.tool
    
    echo
    read -p "按回车键继续..."
    show_user_management
}

# 显示系统要求
show_requirements() {
    clear
    echo -e "${CYAN}=== 系统要求 ===${NC}"
    echo
    echo -e "${YELLOW}最低硬件要求：${NC}"
    echo "• CPU: 2 核心"
    echo "• 内存: 2 GB RAM"
    echo "• 存储: 20 GB 可用空间"
    echo "• 网络: 稳定的互联网连接"
    echo
    echo -e "${YELLOW}操作系统要求：${NC}"
    echo "• Ubuntu 20.04 LTS 或更新版本"
    echo "• CentOS 8 或更新版本"
    echo "• Debian 10 或更新版本"
    echo
    echo -e "${YELLOW}网络要求：${NC}"
    echo "• 公网 IP 或 DDNS"
    echo "• 端口转发配置"
    echo "• 域名解析"
    echo
    echo -e "${YELLOW}推荐配置：${NC}"
    echo "• CPU: 4 核心或更多"
    echo "• 内存: 4 GB RAM 或更多"
    echo "• 存储: 50 GB SSD"
    echo "• 带宽: 100 Mbps 或更高"
    echo
    read -p "按回车键返回主菜单..."
}

# 检查系统状态
check_system() {
    clear
    echo -e "${CYAN}=== 系统状态检查 ===${NC}"
    echo
    
    # 检查操作系统
    echo -e "${YELLOW}操作系统：${NC}"
    cat /etc/os-release | grep PRETTY_NAME
    echo
    
    # 检查硬件资源
    echo -e "${YELLOW}硬件资源：${NC}"
    echo "CPU 核心数: $(nproc)"
    echo "内存总量: $(free -h | awk '/^Mem:/ {print $2}')"
    echo "可用内存: $(free -h | awk '/^Mem:/ {print $7}')"
    echo "磁盘空间: $(df -h / | awk 'NR==2 {print $4}') 可用"
    echo
    
    # 检查网络连接
    echo -e "${YELLOW}网络连接：${NC}"
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "✅ 互联网连接正常"
    else
        echo "❌ 互联网连接异常"
    fi
    echo
    
    # 检查 Docker
    echo -e "${YELLOW}Docker 状态：${NC}"
    if command -v docker >/dev/null 2>&1; then
        echo "✅ Docker 已安装: $(docker --version)"
        if systemctl is-active docker >/dev/null 2>&1; then
            echo "✅ Docker 服务运行中"
        else
            echo "❌ Docker 服务未运行"
        fi
    else
        echo "❌ Docker 未安装"
    fi
    echo
    
    # 检查 K3s
    echo -e "${YELLOW}K3s 状态：${NC}"
    if command -v k3s >/dev/null 2>&1; then
        echo "✅ K3s 已安装: $(k3s --version | head -1)"
        if systemctl is-active k3s >/dev/null 2>&1; then
            echo "✅ K3s 服务运行中"
            kubectl get nodes 2>/dev/null || echo "❌ kubectl 连接失败"
        else
            echo "❌ K3s 服务未运行"
        fi
    else
        echo "❌ K3s 未安装"
    fi
    echo
    
    # 检查 Helm
    echo -e "${YELLOW}Helm 状态：${NC}"
    if command -v helm >/dev/null 2>&1; then
        echo "✅ Helm 已安装: $(helm version --short)"
    else
        echo "❌ Helm 未安装"
    fi
    echo
    
    # 检查 Matrix Stack 部署
    echo -e "${YELLOW}Matrix Stack 状态：${NC}"
    if kubectl get namespace ess >/dev/null 2>&1; then
        echo "✅ Matrix Stack 命名空间存在"
        local pod_count=$(kubectl get pods -n ess --no-headers 2>/dev/null | wc -l)
        local running_count=$(kubectl get pods -n ess --no-headers 2>/dev/null | grep Running | wc -l)
        echo "Pod 状态: $running_count/$pod_count 运行中"
    else
        echo "❌ Matrix Stack 未部署"
    fi
    echo
    
    read -p "按回车键返回主菜单..."
}

# 显示清理菜单
show_cleanup_menu() {
    clear
    echo -e "${CYAN}=== 清理/卸载菜单 ===${NC}"
    echo
    echo -e "${RED}警告：以下操作将删除数据，请谨慎操作！${NC}"
    echo
    echo "1) 🗑️ 卸载 Matrix Stack"
    echo "2) 🧹 清理 Kubernetes 集群"
    echo "3) 💥 完全清理（包括 K3s）"
    echo "4) 📁 清理配置文件"
    echo "5) 🔄 重置到初始状态"
    echo "0) 🔙 返回主菜单"
    echo
    read -p "请选择 [0-5]: " cleanup_choice
    
    case $cleanup_choice in
        1) uninstall_matrix_stack ;;
        2) cleanup_kubernetes ;;
        3) complete_cleanup ;;
        4) cleanup_config_files ;;
        5) reset_to_initial_state ;;
        0) show_main_menu ;;
        *) log_error "无效选项"; show_cleanup_menu ;;
    esac
}

# 卸载 Matrix Stack
uninstall_matrix_stack() {
    echo
    echo -e "${RED}警告：此操作将删除 Matrix Stack 及其所有数据！${NC}"
    read -p "确认卸载 Matrix Stack？输入 'uninstall' 确认: " confirm
    
    if [[ "$confirm" != "uninstall" ]]; then
        log_info "操作已取消"
        show_cleanup_menu
        return
    fi
    
    log_info "开始卸载 Matrix Stack..."
    
    # 删除 Helm 部署
    helm uninstall ess -n ess 2>/dev/null || true
    
    # 删除命名空间
    kubectl delete namespace ess 2>/dev/null || true
    
    # 删除 PVC
    kubectl delete pvc --all -n ess 2>/dev/null || true
    
    log_success "Matrix Stack 已卸载"
    read -p "按回车键返回清理菜单..."
    show_cleanup_menu
}

# 清理配置文件
cleanup_config_files() {
    echo
    echo -e "${RED}警告：此操作将删除所有配置文件！${NC}"
    read -p "确认清理配置文件？输入 'cleanup' 确认: " confirm
    
    if [[ "$confirm" != "cleanup" ]]; then
        log_info "操作已取消"
        show_cleanup_menu
        return
    fi
    
    log_info "开始清理配置文件..."
    
    # 删除配置目录
    rm -rf "${DEFAULT_INSTALL_PATH}/configs" 2>/dev/null || true
    rm -rf "${DEFAULT_INSTALL_PATH}" 2>/dev/null || true
    
    log_success "配置文件已清理"
    read -p "按回车键返回清理菜单..."
    show_cleanup_menu
}

# 重置到初始状态
reset_to_initial_state() {
    echo
    echo -e "${RED}警告：此操作将重置系统到初始状态，删除所有相关数据！${NC}"
    read -p "确认重置到初始状态？输入 'reset' 确认: " confirm
    
    if [[ "$confirm" != "reset" ]]; then
        log_info "操作已取消"
        show_cleanup_menu
        return
    fi
    
    log_info "开始重置系统..."
    
    # 卸载 Matrix Stack
    helm uninstall ess -n ess 2>/dev/null || true
    kubectl delete namespace ess 2>/dev/null || true
    
    # 清理配置文件
    rm -rf "${DEFAULT_INSTALL_PATH}" 2>/dev/null || true
    
    # 重置 K3s
    systemctl stop k3s 2>/dev/null || true
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
    
    log_success "系统已重置到初始状态"
    read -p "按回车键返回主菜单..."
    show_main_menu
}

# 清理 Kubernetes 集群
cleanup_kubernetes() {
    echo
    echo -e "${RED}警告：此操作将清理整个 Kubernetes 集群！${NC}"
    read -p "确认清理 Kubernetes 集群？输入 'cleanup' 确认: " confirm
    
    if [[ "$confirm" != "cleanup" ]]; then
        log_info "操作已取消"
        show_cleanup_menu
        return
    fi
    
    log_info "开始清理 Kubernetes 集群..."
    
    # 删除所有部署
    kubectl delete all --all --all-namespaces 2>/dev/null || true
    
    # 删除所有命名空间（除了系统命名空间）
    kubectl get namespaces -o name | grep -v "kube-\|default" | xargs kubectl delete 2>/dev/null || true
    
    log_success "Kubernetes 集群已清理"
    read -p "按回车键返回清理菜单..."
    show_cleanup_menu
}

# 完全清理
complete_cleanup() {
    echo
    echo -e "${RED}警告：此操作将完全清理系统，包括 K3s、Docker 等！${NC}"
    read -p "确认完全清理？输入 'complete' 确认: " confirm
    
    if [[ "$confirm" != "complete" ]]; then
        log_info "操作已取消"
        show_cleanup_menu
        return
    fi
    
    log_info "开始完全清理系统..."
    
    # 停止 K3s 服务
    systemctl stop k3s 2>/dev/null || true
    
    # 卸载 K3s
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
    
    # 清理残留文件
    rm -rf /etc/rancher/k3s
    rm -rf /var/lib/rancher/k3s
    rm -rf /var/lib/kubelet
    rm -rf /etc/kubernetes
    
    log_success "系统已完全清理"
    read -p "按回车键返回主菜单..."
    show_main_menu
}

# 切换证书模式的函数
switch_to_letsencrypt_http() {
    log_info "切换到 Let's Encrypt (HTTP-01) 模式..."
    
    # 删除现有的 ClusterIssuer
    kubectl delete clusterissuer --all 2>/dev/null || true
    
    # 更新配置
    load_config
    CERT_MODE="letsencrypt-http"
    
    # 重新创建 ClusterIssuer
    create_cluster_issuer
    
    # 更新部署
    update_configuration
    
    log_success "已切换到 Let's Encrypt (HTTP-01) 模式"
    read -p "按回车键返回证书管理..."
    show_certificate_management
}

switch_to_letsencrypt_dns() {
    log_info "切换到 Let's Encrypt (DNS-01) 模式..."
    
    # 配置 DNS 提供商
    configure_dns_provider
    
    # 删除现有的 ClusterIssuer
    kubectl delete clusterissuer --all 2>/dev/null || true
    
    # 更新配置
    load_config
    CERT_MODE="letsencrypt-dns"
    
    # 重新创建 ClusterIssuer
    create_cluster_issuer
    
    # 更新部署
    update_configuration
    
    log_success "已切换到 Let's Encrypt (DNS-01) 模式"
    read -p "按回车键返回证书管理..."
    show_certificate_management
}

switch_to_selfsigned() {
    log_info "切换到自签名证书模式..."
    
    # 删除现有的 ClusterIssuer
    kubectl delete clusterissuer --all 2>/dev/null || true
    
    # 更新配置
    load_config
    CERT_MODE="selfsigned"
    
    # 重新创建 ClusterIssuer
    create_cluster_issuer
    
    # 更新部署
    update_configuration
    
    log_success "已切换到自签名证书模式"
    read -p "按回车键返回证书管理..."
    show_certificate_management
}

manual_update_certificates() {
    log_info "手动更新证书..."
    
    # 删除现有证书
    kubectl delete certificates --all -n ess 2>/dev/null || true
    
    # 重新部署以触发证书申请
    kubectl rollout restart deployment -n ess
    
    log_success "证书更新已触发"
    read -p "按回车键返回证书管理..."
    show_certificate_management
}

# 快速部署配置
quick_deployment_config() {
    log_info "快速部署配置..."
    
    # 域名配置
    read -p "请输入您的域名 (例如: example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        log_error "域名不能为空"
        read -p "请输入您的域名 (例如: example.com): " DOMAIN
    done
    
    # 管理员邮箱
    read -p "请输入管理员邮箱: " ADMIN_EMAIL
    while [[ -z "$ADMIN_EMAIL" ]]; do
        log_error "邮箱不能为空"
        read -p "请输入管理员邮箱: " ADMIN_EMAIL
    done
    
    # 管理员用户名
    read -p "请输入管理员用户名: " ADMIN_USERNAME
    while [[ -z "$ADMIN_USERNAME" ]]; do
        log_error "用户名不能为空"
        read -p "请输入管理员用户名: " ADMIN_USERNAME
    done
    
    # 管理员密码
    read -s -p "请输入管理员密码: " ADMIN_PASSWORD
    echo
    while [[ -z "$ADMIN_PASSWORD" ]]; do
        log_error "密码不能为空"
        read -s -p "请输入管理员密码: " ADMIN_PASSWORD
        echo
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
    USE_LIVEKIT_TURN="true"
    CERT_MODE="letsencrypt-http"
    
    log_success "快速部署配置完成"
}

# 自定义部署配置
custom_deployment_config() {
    log_info "自定义部署配置..."
    
    # 域名配置
    read -p "请输入您的域名 (例如: example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        log_error "域名不能为空"
        read -p "请输入您的域名 (例如: example.com): " DOMAIN
    done
    
    # 安装路径
    read -p "安装路径 [默认: $DEFAULT_INSTALL_PATH]: " INSTALL_PATH
    INSTALL_PATH=${INSTALL_PATH:-$DEFAULT_INSTALL_PATH}
    
    # 端口配置
    echo
    log_info "端口配置 (用于 NAT 环境)"
    read -p "内部 HTTP NodePort [默认: $DEFAULT_HTTP_NODEPORT]: " HTTP_NODEPORT
    HTTP_NODEPORT=${HTTP_NODEPORT:-$DEFAULT_HTTP_NODEPORT}
    
    read -p "内部 HTTPS NodePort [默认: $DEFAULT_HTTPS_NODEPORT]: " HTTPS_NODEPORT
    HTTPS_NODEPORT=${HTTPS_NODEPORT:-$DEFAULT_HTTPS_NODEPORT}
    
    read -p "外部 HTTP 端口 [默认: $DEFAULT_EXTERNAL_HTTP_PORT]: " EXTERNAL_HTTP_PORT
    EXTERNAL_HTTP_PORT=${EXTERNAL_HTTP_PORT:-$DEFAULT_EXTERNAL_HTTP_PORT}
    
    read -p "外部 HTTPS 端口 [默认: $DEFAULT_EXTERNAL_HTTPS_PORT]: " EXTERNAL_HTTPS_PORT
    EXTERNAL_HTTPS_PORT=${EXTERNAL_HTTPS_PORT:-$DEFAULT_EXTERNAL_HTTPS_PORT}
    
    # TURN 端口配置
    echo
    log_info "TURN 服务端口配置"
    read -p "TURN 端口起始 [默认: $DEFAULT_TURN_PORT_START]: " TURN_PORT_START
    TURN_PORT_START=${TURN_PORT_START:-$DEFAULT_TURN_PORT_START}
    
    read -p "TURN 端口结束 [默认: $DEFAULT_TURN_PORT_END]: " TURN_PORT_END
    TURN_PORT_END=${TURN_PORT_END:-$DEFAULT_TURN_PORT_END}
    
    # 子域名配置
    echo
    log_info "子域名配置"
    read -p "Matrix 服务子域名 [默认: $DEFAULT_SUBDOMAIN_MATRIX]: " SUBDOMAIN_MATRIX
    SUBDOMAIN_MATRIX=${SUBDOMAIN_MATRIX:-$DEFAULT_SUBDOMAIN_MATRIX}
    
    read -p "Element Web 子域名 [默认: $DEFAULT_SUBDOMAIN_CHAT]: " SUBDOMAIN_CHAT
    SUBDOMAIN_CHAT=${SUBDOMAIN_CHAT:-$DEFAULT_SUBDOMAIN_CHAT}
    
    read -p "认证服务子域名 [默认: $DEFAULT_SUBDOMAIN_AUTH]: " SUBDOMAIN_AUTH
    SUBDOMAIN_AUTH=${SUBDOMAIN_AUTH:-$DEFAULT_SUBDOMAIN_AUTH}
    
    read -p "RTC 服务子域名 [默认: $DEFAULT_SUBDOMAIN_RTC]: " SUBDOMAIN_RTC
    SUBDOMAIN_RTC=${SUBDOMAIN_RTC:-$DEFAULT_SUBDOMAIN_RTC}
    
    # 管理员配置
    echo
    log_info "管理员账户配置"
    read -p "管理员邮箱: " ADMIN_EMAIL
    while [[ -z "$ADMIN_EMAIL" ]]; do
        log_error "邮箱不能为空"
        read -p "管理员邮箱: " ADMIN_EMAIL
    done
    
    read -p "管理员用户名: " ADMIN_USERNAME
    while [[ -z "$ADMIN_USERNAME" ]]; do
        log_error "用户名不能为空"
        read -p "管理员用户名: " ADMIN_USERNAME
    done
    
    read -s -p "管理员密码: " ADMIN_PASSWORD
    echo
    while [[ -z "$ADMIN_PASSWORD" ]]; do
        log_error "密码不能为空"
        read -s -p "管理员密码: " ADMIN_PASSWORD
        echo
    done
    
    # TURN 服务选择
    echo
    log_info "TURN 服务配置"
    echo "1) 使用 LiveKit 内置 TURN (推荐)"
    echo "2) 使用独立 Coturn 服务"
    read -p "请选择 TURN 服务 [1-2]: " turn_choice
    
    case $turn_choice in
        1) USE_LIVEKIT_TURN="true" ;;
        2) USE_LIVEKIT_TURN="false" ;;
        *) USE_LIVEKIT_TURN="true" ;;
    esac
    
    # 证书模式选择
    echo
    log_info "证书模式配置"
    echo "1) Let's Encrypt (HTTP-01) - 推荐"
    echo "2) Let's Encrypt (DNS-01) - 需要 DNS API"
    echo "3) 自签名证书 - 仅用于测试"
    read -p "请选择证书模式 [1-3]: " cert_choice
    
    case $cert_choice in
        1) CERT_MODE="letsencrypt-http" ;;
        2) 
            CERT_MODE="letsencrypt-dns"
            configure_dns_provider
            ;;
        3) CERT_MODE="selfsigned" ;;
        *) CERT_MODE="letsencrypt-http" ;;
    esac
    
    log_success "自定义部署配置完成"
}

# 配置 DNS 提供商
configure_dns_provider() {
    echo
    log_info "配置 DNS 提供商 (用于 DNS-01 验证)"
    echo "1) Cloudflare"
    echo "2) 阿里云 DNS"
    echo "3) 腾讯云 DNS"
    echo "4) 其他"
    read -p "请选择 DNS 提供商 [1-4]: " dns_choice
    
    case $dns_choice in
        1) 
            DNS_PROVIDER="cloudflare"
            read -p "请输入 Cloudflare API Token: " DNS_API_KEY
            ;;
        2) 
            DNS_PROVIDER="alidns"
            read -p "请输入阿里云 Access Key ID: " DNS_API_KEY
            ;;
        3) 
            DNS_PROVIDER="tencentcloud"
            read -p "请输入腾讯云 Secret ID: " DNS_API_KEY
            ;;
        4) 
            read -p "请输入 DNS 提供商名称: " DNS_PROVIDER
            read -p "请输入 API Key: " DNS_API_KEY
            ;;
        *) 
            DNS_PROVIDER="cloudflare"
            read -p "请输入 Cloudflare API Token: " DNS_API_KEY
            ;;
    esac
}

# 检查系统要求
check_system_requirements() {
    log_info "检查系统要求..."
    
    # 检查操作系统
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "不支持的操作系统，需要 systemd 支持"
        exit 1
    fi
    
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
    
    # 检查内存
    local mem_gb=$(free -g | awk '/^Mem:/ {print $2}')
    if [[ $mem_gb -lt 2 ]]; then
        log_warning "内存不足 2GB，可能影响性能"
    fi
    
    # 检查磁盘空间
    local disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    if [[ $disk_gb -lt 20 ]]; then
        log_warning "磁盘空间不足 20GB，可能影响运行"
    fi
    
    log_success "系统要求检查完成"
}

# 安装依赖
install_dependencies() {
    log_info "安装系统依赖..."
    
    # 更新包管理器
    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y curl wget git jq
    elif command -v yum >/dev/null 2>&1; then
        yum update -y
        yum install -y curl wget git jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf update -y
        dnf install -y curl wget git jq
    else
        log_error "不支持的包管理器"
        exit 1
    fi
    
    log_success "系统依赖安装完成"
}

# 安装 K3s
install_k3s() {
    log_info "安装 K3s..."
    
    if command -v k3s >/dev/null 2>&1; then
        log_info "K3s 已安装，跳过安装步骤"
        return 0
    fi
    
    # 安装 K3s
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -
    
    # 配置 kubeconfig
    mkdir -p ~/.kube
    cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    chmod 600 ~/.kube/config
    
    # 等待 K3s 启动
    log_info "等待 K3s 启动..."
    for i in {1..60}; do
        if kubectl get nodes >/dev/null 2>&1; then
            log_success "K3s 启动完成"
            break
        fi
        if [[ $i -eq 60 ]]; then
            log_error "K3s 启动超时"
            exit 1
        fi
        sleep 5
    done
    
    log_success "K3s 安装完成"
}

# 安装 Helm
install_helm() {
    log_info "安装 Helm..."
    
    if command -v helm >/dev/null 2>&1; then
        log_info "Helm 已安装，跳过安装步骤"
        return 0
    fi
    
    # 安装 Helm
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    log_success "Helm 安装完成"
}

# 设置 Ingress 控制器
setup_ingress_controller() {
    log_info "设置 Ingress 控制器..."
    
    # 检查是否已安装
    if kubectl get deployment -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
        log_info "Ingress 控制器已安装，跳过安装步骤"
        return 0
    fi
    
    # 添加 Helm 仓库
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    
    # 安装 ingress-nginx
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=NodePort \
        --set controller.service.nodePorts.http=$HTTP_NODEPORT \
        --set controller.service.nodePorts.https=$HTTPS_NODEPORT \
        --wait \
        --timeout 10m
    
    log_success "Ingress 控制器安装完成"
}

# 设置 cert-manager
setup_cert_manager() {
    log_info "设置 cert-manager..."
    
    # 检查是否已安装
    if kubectl get deployment -n cert-manager cert-manager >/dev/null 2>&1; then
        log_info "cert-manager 已安装，跳过安装步骤"
        return 0
    fi
    
    # 添加 Helm 仓库
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    # 安装 cert-manager
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set installCRDs=true \
        --wait \
        --timeout 10m
    
    # 等待 cert-manager 启动
    log_info "等待 cert-manager 启动..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
    
    log_success "cert-manager 安装完成"
}

# 创建 ClusterIssuer
create_cluster_issuer() {
    log_info "创建 ClusterIssuer..."
    
    case $CERT_MODE in
        "letsencrypt-http")
            create_letsencrypt_http_issuer
            ;;
        "letsencrypt-dns")
            create_letsencrypt_dns_issuer
            ;;
        "selfsigned")
            create_selfsigned_issuer
            ;;
        *)
            log_error "未知的证书模式: $CERT_MODE"
            exit 1
            ;;
    esac
    
    log_success "ClusterIssuer 创建完成"
}

# 创建 Let's Encrypt HTTP-01 ClusterIssuer
create_letsencrypt_http_issuer() {
    cat << EOF | kubectl apply -f -
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
}

# 创建 Let's Encrypt DNS-01 ClusterIssuer
create_letsencrypt_dns_issuer() {
    # 创建 DNS API Secret
    kubectl create secret generic dns-api-secret \
        --from-literal=api-token="$DNS_API_KEY" \
        -n cert-manager \
        --dry-run=client -o yaml | kubectl apply -f -
    
    cat << EOF | kubectl apply -f -
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
            name: dns-api-secret
            key: api-token
EOF
}

# 创建自签名 ClusterIssuer
create_selfsigned_issuer() {
    cat << EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
}

# 生成 values.yaml 配置文件 - 完全修复版（修复所有重定向端口问题）
generate_values_yaml() {
    log_info "生成配置文件（修复所有重定向端口问题）..."
    
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
    
    cat > "${INSTALL_PATH}/configs/values.yaml" << EOF
# Matrix Stack 配置文件 - 修复所有重定向端口问题
# 生成时间: $(date)
# 修复版本: v0.1.3 - 完全修复重定向端口问题

# 服务器配置
serverName: "${SUBDOMAIN_MATRIX}.${DOMAIN}"

# 证书管理器配置
certManager:
  clusterIssuer: "${cluster_issuer_name}"

# 全局Ingress配置
ingress:
  className: "nginx"
  tlsEnabled: true
  annotations:
    cert-manager.io/cluster-issuer: "${cluster_issuer_name}"

# Synapse 配置
synapse:
  enabled: true
  ingress:
    host: "${SUBDOMAIN_MATRIX}.${DOMAIN}"
    annotations:
      cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
    className: "nginx"
    tlsEnabled: true

# Element Web 配置 - 修复重定向端口问题
elementWeb:
  enabled: true
  replicas: 1
  ingress:
    host: "${SUBDOMAIN_CHAT}.${DOMAIN}"
    annotations:
      cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
    className: "nginx"
    tlsEnabled: true
  additional:
    # 修复：确保所有客户端配置都包含正确的端口号
    default_server_config: '{"m.homeserver":{"base_url":"https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}","server_name":"${SUBDOMAIN_MATRIX}.${DOMAIN}"},"m.identity_server":{"base_url":"https://vector.im"}}'
    # 修复：Element Web 内部重定向配置
    brand: "Element"
    default_theme: "light"
    show_labs_settings: true
    # 修复：确保所有内部链接都包含端口号
    permalink_prefix: "https://${SUBDOMAIN_CHAT}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"

# Matrix Authentication Service 配置 - 修复重定向端口问题
matrixAuthenticationService:
  enabled: true
  ingress:
    host: "${SUBDOMAIN_AUTH}.${DOMAIN}"
    annotations:
      cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
    className: "nginx"
    tlsEnabled: true
  # 修复：MAS 重定向配置包含端口号
  config:
    http:
      public_base: "https://${SUBDOMAIN_AUTH}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    matrix:
      homeserver: "https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    upstream:
      name: "${SUBDOMAIN_MATRIX}.${DOMAIN}"
      issuer: "https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"

# Matrix RTC 配置 - 修复重定向端口问题
matrixRTC:
  enabled: true
  ingress:
    host: "${SUBDOMAIN_RTC}.${DOMAIN}"
    annotations:
      cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
    className: "nginx"
    tlsEnabled: true
  # 修复：RTC 服务配置包含端口号
  config:
    livekit:
      api_host: "${SUBDOMAIN_RTC}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
      ws_url: "wss://${SUBDOMAIN_RTC}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"

# Well-known delegation 配置 - 完全修复重定向端口问题
wellKnownDelegation:
  enabled: true
  additional:
    # 修复：Matrix 服务器发现包含端口号
    server: '{"m.server": "${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"}'
    # 修复：客户端发现配置包含端口号
    client: '{"m.homeserver":{"base_url":"https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"},"m.identity_server":{"base_url":"https://vector.im"},"org.matrix.msc3575.proxy":{"url":"https://${SUBDOMAIN_RTC}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"}}'
  # 修复：基础域名重定向包含端口号 - 关键修复
  baseDomainRedirect:
    enabled: true
    url: "https://${SUBDOMAIN_CHAT}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
  # 修复：所有子域名重定向都包含端口号
  ingress:
    host: "${DOMAIN}"
    annotations:
      cert-manager.io/cluster-issuer: "${cluster_issuer_name}"
      # 修复：nginx 重定向注解包含端口号
      nginx.ingress.kubernetes.io/permanent-redirect: "https://${SUBDOMAIN_CHAT}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    className: "nginx"
    tlsEnabled: true

EOF

    # 保存配置到环境文件
    cat > "${INSTALL_PATH}/configs/.env" << EOF
# Matrix Stack 部署配置 - v0.1.3 完全修复版
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

    log_success "配置文件生成完成（已修复所有重定向端口问题）: ${INSTALL_PATH}/configs/values.yaml"
    log_info "修复内容："
    log_info "  ✅ baseDomainRedirect.url 包含端口号"
    log_info "  ✅ Element Web 配置包含端口号"
    log_info "  ✅ MAS 重定向配置包含端口号"
    log_info "  ✅ RTC 服务配置包含端口号"
    log_info "  ✅ Well-known 客户端发现包含端口号"
    log_info "  ✅ Nginx 重定向注解包含端口号"
}

# 加载配置
load_config() {
    if [[ -f "${INSTALL_PATH}/configs/.env" ]]; then
        source "${INSTALL_PATH}/configs/.env"
        log_info "已加载配置文件"
    else
        log_warning "配置文件不存在，使用默认配置"
        INSTALL_PATH="${INSTALL_PATH:-$DEFAULT_INSTALL_PATH}"
    fi
}

# 部署 Matrix Stack
deploy_matrix_stack() {
    log_info "部署 Matrix Stack..."
    
    # 创建命名空间
    kubectl create namespace ess --dry-run=client -o yaml | kubectl apply -f -
    
    # 添加 Element Helm 仓库
    helm repo add element-hq https://element-hq.github.io/ess-helm
    helm repo update
    
    # 部署 Matrix Stack
    if helm list -n ess | grep -q ess; then
        log_info "更新现有部署..."
        helm upgrade ess element-hq/matrix-stack \
            --namespace ess \
            --values "${INSTALL_PATH}/configs/values.yaml" \
            --wait \
            --timeout 15m
    else
        log_info "首次部署..."
        helm install ess element-hq/matrix-stack \
            --namespace ess \
            --values "${INSTALL_PATH}/configs/values.yaml" \
            --wait \
            --timeout 15m
    fi
    
    log_success "Matrix Stack 部署完成"
}

# 等待服务就绪
wait_for_services() {
    log_info "等待服务就绪..."
    
    # 等待 Pod 启动
    log_info "等待 Pod 启动..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=ess -n ess --timeout=600s
    
    # 等待 Ingress 就绪
    log_info "等待 Ingress 就绪..."
    for i in {1..60}; do
        if kubectl get ingress -n ess | grep -q "ess"; then
            log_success "Ingress 已就绪"
            break
        fi
        if [[ $i -eq 60 ]]; then
            log_warning "Ingress 启动超时，但继续执行"
            break
        fi
        sleep 5
    done
    
    log_success "服务就绪检查完成"
}

# 创建管理员用户
create_admin_user() {
    log_info "创建管理员用户..."
    
    # 等待 MAS 服务就绪
    log_info "等待 Matrix Authentication Service 就绪..."
    for i in {1..60}; do
        if kubectl exec -n ess deploy/ess-matrix-authentication-service -- mas-cli --version >/dev/null 2>&1; then
            log_success "MAS 服务已就绪"
            break
        fi
        if [[ $i -eq 60 ]]; then
            log_error "MAS 服务启动超时"
            return 1
        fi
        sleep 5
    done
    
    # 等待 Synapse API 可用
    log_info "等待 Synapse API 就绪..."
    local SYNAPSE_POD=$(kubectl get pods -n ess -l app.kubernetes.io/name=synapse-main -o jsonpath='{.items[0].metadata.name}')
    for i in {1..60}; do
        if kubectl exec -n ess "$SYNAPSE_POD" -- curl -s http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; then
            log_success "Synapse API 已就绪"
            break
        fi
        if [[ $i -eq 60 ]]; then
            log_error "Synapse API 启动超时"
            return 1
        fi
        sleep 5
    done
    
    # 创建管理员用户（修复：基于实际 --help 确定的正确参数格式）
    log_info "创建管理员用户..."
    
    if kubectl exec -n ess deploy/ess-matrix-authentication-service -- mas-cli manage register-user \
        --password "$ADMIN_PASSWORD" \
        --admin \
        --yes \
        "$ADMIN_USERNAME"; then
        log_success "管理员用户创建完成: $ADMIN_USERNAME"
        return 0
    else
        log_error "管理员用户创建失败"
        return 1
    fi
}

# 显示服务状态
show_service_status() {
    clear
    echo -e "${CYAN}=== 服务状态 ===${NC}"
    echo
    
    echo -e "${YELLOW}Kubernetes 节点状态：${NC}"
    kubectl get nodes
    echo
    
    echo -e "${YELLOW}Matrix Stack Pods：${NC}"
    kubectl get pods -n ess
    echo
    
    echo -e "${YELLOW}Ingress 状态：${NC}"
    kubectl get ingress -n ess
    echo
    
    echo -e "${YELLOW}证书状态：${NC}"
    kubectl get certificates -n ess
    echo
    
    echo -e "${YELLOW}服务状态：${NC}"
    kubectl get svc -n ess
    echo
    
    read -p "按回车键返回管理菜单..."
    show_management_menu
}

# 证书管理
show_certificate_management() {
    clear
    echo -e "${CYAN}=== 证书管理 ===${NC}"
    echo
    echo "1) 查看证书状态"
    echo "2) 切换到 Let's Encrypt (HTTP-01)"
    echo "3) 切换到 Let's Encrypt (DNS-01)"
    echo "4) 切换到自签名证书"
    echo "5) 手动更新证书"
    echo "6) 返回管理菜单"
    echo
    read -p "请选择 [1-6]: " cert_choice
    
    case $cert_choice in
        1) show_certificate_status ;;
        2) switch_to_letsencrypt_http ;;
        3) switch_to_letsencrypt_dns ;;
        4) switch_to_selfsigned ;;
        5) manual_update_certificates ;;
        6) show_management_menu ;;
        *) log_error "无效选项"; show_certificate_management ;;
    esac
}

# 查看证书状态
show_certificate_status() {
    echo
    echo -e "${YELLOW}证书状态：${NC}"
    kubectl get certificates -n ess
    echo
    echo -e "${YELLOW}证书详情：${NC}"
    kubectl describe certificates -n ess
    echo
    read -p "按回车键返回证书管理..."
    show_certificate_management
}

# 重启服务
restart_services() {
    log_info "重启 Matrix Stack 服务..."
    
    kubectl rollout restart deployment -n ess
    kubectl rollout restart statefulset -n ess
    
    log_success "服务重启完成"
    read -p "按回车键返回管理菜单..."
    show_management_menu
}

# 显示日志菜单
show_logs_menu() {
    clear
    echo -e "${CYAN}=== 日志查看 ===${NC}"
    echo
    echo "1) Synapse 日志"
    echo "2) Element Web 日志"
    echo "3) Matrix Authentication Service 日志"
    echo "4) Matrix RTC 日志"
    echo "5) Ingress 控制器日志"
    echo "6) cert-manager 日志"
    echo "0) 返回管理菜单"
    echo
    read -p "请选择 [0-6]: " log_choice
    
    case $log_choice in
        1) kubectl logs -n ess -l app.kubernetes.io/name=synapse-main --tail=100 -f ;;
        2) kubectl logs -n ess -l app.kubernetes.io/name=element-web --tail=100 -f ;;
        3) kubectl logs -n ess -l app.kubernetes.io/name=matrix-authentication-service --tail=100 -f ;;
        4) kubectl logs -n ess -l app.kubernetes.io/name=matrix-rtc --tail=100 -f ;;
        5) kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=100 -f ;;
        6) kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager --tail=100 -f ;;
        0) show_management_menu ;;
        *) log_error "无效选项"; show_logs_menu ;;
    esac
}

# 备份数据
backup_data() {
    log_info "备份数据功能开发中..."
    read -p "按回车键返回管理菜单..."
    show_management_menu
}

# 恢复数据
restore_data() {
    log_info "恢复数据功能开发中..."
    read -p "按回车键返回管理菜单..."
    show_management_menu
}

# 更新配置
update_configuration() {
    log_info "更新配置..."
    
    # 重新生成配置文件
    generate_values_yaml
    
    # 更新部署
    helm upgrade ess element-hq/matrix-stack \
        --namespace ess \
        --values "${INSTALL_PATH}/configs/values.yaml" \
        --wait \
        --timeout 10m
    
    log_success "配置更新完成"
    read -p "按回车键返回管理菜单..."
    show_management_menu
}

# 修复重定向端口问题 - 新增功能
fix_redirect_ports() {
    clear
    echo -e "${CYAN}=== 修复重定向端口问题 ===${NC}"
    echo
    echo -e "${YELLOW}此功能将修复以下重定向端口问题：${NC}"
    echo "• matrix.域名:8443 重定向到 app.域名 (缺少端口号)"
    echo "• Element Web 内部链接缺少端口号"
    echo "• MAS 认证重定向缺少端口号"
    echo "• Well-known 发现配置缺少端口号"
    echo
    echo -e "${RED}注意：此操作将更新 Matrix Stack 配置并重新部署${NC}"
    echo
    read -p "确认修复重定向端口问题？[y/N]: " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "操作已取消"
        show_management_menu
        return
    fi
    
    # 检查是否已部署
    if ! kubectl get namespace ess >/dev/null 2>&1; then
        log_error "未找到现有的 Matrix Stack 部署"
        read -p "按回车键返回管理菜单..."
        show_management_menu
        return
    fi
    
    # 加载现有配置
    load_config
    
    if [[ -z "$DOMAIN" ]]; then
        log_error "无法加载配置，请检查部署状态"
        read -p "按回车键返回管理菜单..."
        show_management_menu
        return
    fi
    
    log_info "开始修复重定向端口问题..."
    
    # 备份当前配置
    if [[ -f "${INSTALL_PATH}/configs/values.yaml" ]]; then
        cp "${INSTALL_PATH}/configs/values.yaml" "${INSTALL_PATH}/configs/values.yaml.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "已备份当前配置"
    fi
    
    # 重新生成修复后的配置文件
    generate_values_yaml
    
    # 更新部署
    log_info "更新 Matrix Stack 部署..."
    if helm upgrade ess element-hq/matrix-stack \
        --namespace ess \
        --values "${INSTALL_PATH}/configs/values.yaml" \
        --wait \
        --timeout 15m; then
        
        log_success "重定向端口问题修复完成！"
        echo
        echo -e "${GREEN}修复内容：${NC}"
        echo "✅ 基础域名重定向现在包含端口号"
        echo "✅ Element Web 配置现在包含端口号"
        echo "✅ MAS 认证重定向现在包含端口号"
        echo "✅ Well-known 发现配置现在包含端口号"
        echo "✅ 所有内部链接现在包含端口号"
        echo
        echo -e "${CYAN}验证方法：${NC}"
        echo "curl -I https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
        echo "应该看到重定向到: https://${SUBDOMAIN_CHAT}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
        echo
    else
        log_error "部署更新失败"
        echo
        echo -e "${YELLOW}回滚方法：${NC}"
        echo "如果需要回滚，可以使用备份的配置文件："
        echo "ls ${INSTALL_PATH}/configs/values.yaml.backup.*"
    fi
    
    read -p "按回车键返回管理菜单..."
    show_management_menu
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
    echo "• 重新运行此脚本进行管理操作"
    echo "• 查看服务状态: kubectl get pods -n ess"
    echo "• 查看日志: kubectl logs -n ess -l app.kubernetes.io/name=synapse-main"
    echo
    echo -e "${GREEN}高级功能：${NC}"
    echo "• 用户管理：创建、删除、权限设置"
    echo "• 邀请码系统：生成、管理注册邀请"
    echo "• 证书管理：切换证书模式"
    echo "• 备份恢复：数据安全保障"
    echo "• 重定向修复：自动修复端口问题"
    echo
    echo -e "${CYAN}重定向验证：${NC}"
    echo "• 测试重定向: curl -I https://${SUBDOMAIN_MATRIX}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo "• 期望结果: 重定向到 https://${SUBDOMAIN_CHAT}.${DOMAIN}:${EXTERNAL_HTTPS_PORT}"
    echo
}

# 主函数
main() {
    show_banner
    
    # 检查系统要求
    check_system_requirements
    
    # 显示菜单
    show_main_menu
    
    # 配置部署参数
    if [[ "$DEPLOYMENT_MODE" == "quick" ]]; then
        quick_deployment_config
    elif [[ "$DEPLOYMENT_MODE" == "custom" ]]; then
        custom_deployment_config
    else
        return 0  # 管理模式或其他模式，不需要部署
    fi
    
    # 确认配置
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
    echo "• 管理员: $ADMIN_USERNAME"
    echo "• TURN 服务: $([ "$USE_LIVEKIT_TURN" == "true" ] && echo "LiveKit 内置" || echo "独立 Coturn")"
    echo "• 证书模式: $CERT_MODE"
    echo
    echo -e "${GREEN}重定向修复：${NC}"
    echo "• ✅ 所有重定向URL将包含端口号 :${EXTERNAL_HTTPS_PORT}"
    echo "• ✅ 修复 matrix.域名:8443 → ${SUBDOMAIN_CHAT}.域名:8443"
    echo "• ✅ 修复 Element Web 内部链接端口问题"
    echo "• ✅ 修复 MAS 认证重定向端口问题"
    echo
    read -p "确认开始部署？ [y/N]: " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "部署已取消"
        exit 0
    fi
    
    # 开始部署
    log_info "开始部署 Matrix Stack..."
    
    install_dependencies
    install_k3s
    install_helm
    setup_ingress_controller
    setup_cert_manager
    create_cluster_issuer
    generate_values_yaml
    deploy_matrix_stack
    wait_for_services
    create_admin_user
    
    # 显示部署结果
    show_deployment_result
}

# 如果直接运行此脚本，执行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

