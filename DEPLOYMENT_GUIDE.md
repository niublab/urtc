# Matrix Stack 部署和使用指南

## 概述

本指南详细介绍如何使用完善后的 Matrix Stack 部署脚本，在动态IP内网环境中部署完整的 Matrix 视频会议系统。

## 系统要求

### 硬件要求
- **CPU**: 最少2核，推荐4核以上
- **内存**: 最少6GB，推荐8GB以上
- **存储**: 最少50GB可用空间，推荐100GB以上
- **网络**: 稳定的互联网连接

### 软件要求
- **操作系统**: Ubuntu 20.04+ 或 Debian 11+
- **用户权限**: 非root用户，但需要sudo权限
- **网络配置**: 已配置ddns-go服务，DNS解析正常

### 网络要求
- **域名**: 已注册的域名，配置了A记录
- **端口转发**: 路由器已配置端口转发
  - 8080 → 内网服务器:30080 (HTTP)
  - 8443 → 内网服务器:30443 (HTTPS)
  - 8448 → 内网服务器:30448 (Federation)
- **Cloudflare API**: 已获取API Token用于DNS验证

## 快速开始

### 1. 下载和执行脚本

```bash
# 下载脚本
curl -fsSL https://raw.githubusercontent.com/niublab/ess-helm-nat/main/setup.sh -o setup.sh

# 设置执行权限
chmod +x setup.sh

# 运行脚本
./setup.sh
```

### 2. 首次部署流程

#### 步骤1: 环境检查和准备
选择菜单选项 `1) 环境检查和准备`
- 自动检查系统要求
- 安装必要的软件包
- 创建目录结构

#### 步骤2: 配置向导
选择菜单选项 `2) 配置向导`
- 输入主域名 (例如: example.com)
- 输入Cloudflare API Token
- 配置管理员账户
- 设置端口配置 (建议使用8080/8443)
- 配置子域名前缀
- 选择部署模式
- 选择证书类型

#### 步骤3: 安装K3s
选择菜单选项 `3) 安装K3s`
- 自动下载和安装K3s
- 配置kubectl访问

#### 步骤4: 安装cert-manager
选择菜单选项 `4) 安装cert-manager`
- 安装Helm
- 安装cert-manager
- 配置ClusterIssuer

#### 步骤5: 部署Matrix Stack
选择菜单选项 `5) 部署Matrix Stack`
- 生成MAS配置
- 生成Helm values文件
- 部署所有服务
- 等待服务就绪

#### 步骤6: 创建管理员用户
选择菜单选项 `6) 创建管理员用户`
- 自动创建管理员账户

#### 步骤7: 配置动态IP监控
选择菜单选项 `7) 配置动态IP监控`
- 创建IP检查脚本
- 配置systemd定时任务

#### 步骤8: 查看部署信息
选择菜单选项 `8) 查看部署信息`
- 显示访问地址和管理员账户信息

## 详细配置说明

### 域名配置

#### 主域名
- 格式: `example.com`
- 要求: 已在Cloudflare托管，配置了A记录

#### 子域名配置
默认子域名前缀：
- `app.example.com` - Element Web客户端
- `live.example.com` - LiveKit音视频服务
- `mas.example.com` - Matrix认证服务
- `rtc.example.com` - Matrix RTC后端
- `jwt.example.com` - JWT服务
- `matrix.example.com` - Matrix联邦服务

### 端口配置

#### 推荐端口配置
- **HTTP端口**: 8080 (避免ISP封锁)
- **HTTPS端口**: 8443 (避免ISP封锁)
- **联邦端口**: 8448 (Matrix标准端口)

#### 端口转发配置
在路由器中配置以下端口转发：
```
外网端口 → 内网IP:NodePort
8080 → 192.168.1.100:30080
8443 → 192.168.1.100:30443
8448 → 192.168.1.100:30448
```

### 部署模式选择

#### 1. 开发调试部署
- 所有服务单副本
- 资源消耗最低
- 适合开发测试

#### 2. 测试环境部署
- 关键服务多副本
- 中等资源消耗
- 适合功能测试

#### 3. 生产环境部署
- 所有服务多副本
- 高可用配置
- 适合生产使用

#### 4. 自定义配置
- 手动设置各服务副本数
- 灵活配置资源

### 证书配置

#### 生产证书 (推荐)
- 使用Let's Encrypt正式证书
- 浏览器完全信任
- 有速率限制

#### 测试证书
- 使用Let's Encrypt Staging证书
- 浏览器显示不安全警告
- 无速率限制，适合测试

## 管理操作

### 用户管理

#### 创建用户
1. 进入 `10) 用户管理`
2. 选择 `1) 创建新用户`
3. 输入用户名和密码
4. 选择是否设为管理员

#### 删除用户
1. 进入 `10) 用户管理`
2. 选择 `2) 删除用户`
3. 输入要删除的用户名
4. 确认删除操作

#### 重置密码
1. 进入 `10) 用户管理`
2. 选择 `3) 重置用户密码`
3. 输入用户名和新密码

#### 生成邀请码
1. 进入 `10) 用户管理`
2. 选择 `6) 生成注册邀请码`
3. 设置有效期和使用次数

### 系统管理

#### 查看服务状态
1. 进入 `11) 系统管理`
2. 选择 `1) 查看系统状态`
3. 查看所有服务运行状态

#### 重启服务
1. 进入 `11) 系统管理`
2. 选择 `2) 重启服务`
3. 选择要重启的服务

#### 查看日志
1. 进入 `11) 系统管理`
2. 选择 `4) 查看日志`
3. 选择要查看的服务日志

#### 证书管理
1. 进入 `11) 系统管理`
2. 选择 `5) 证书管理`
3. 进行证书相关操作

### 备份和恢复

#### 立即备份
1. 进入 `12) 备份和恢复`
2. 选择 `1) 立即备份`
3. 等待备份完成

#### 恢复备份
1. 进入 `12) 备份和恢复`
2. 选择 `2) 恢复数据`
3. 选择要恢复的备份文件

#### 自动备份配置
1. 进入 `12) 备份和恢复`
2. 选择 `5) 自动备份配置`
3. 启用每日自动备份

## 独立证书管理

### 使用独立证书管理脚本

```bash
# 下载证书管理脚本
curl -fsSL https://raw.githubusercontent.com/niublab/ess-helm-nat/main/cert-manager.sh -o cert-manager.sh

# 设置执行权限
chmod +x cert-manager.sh

# 运行证书管理脚本
./cert-manager.sh
```

### 证书管理功能

#### 安装acme.sh
1. 选择 `1) 安装和配置acme.sh`
2. 自动安装acme.sh和配置Cloudflare API

#### 申请证书
1. 选择 `2) 申请证书 (acme.sh)`
2. 输入域名
3. 选择证书类型 (生产/测试)

#### 续期证书
1. 选择 `3) 续期证书 (acme.sh)`
2. 输入要续期的域名

#### 撤销证书
1. 选择 `4) 撤销证书 (acme.sh)`
2. 输入要撤销的域名
3. 确认撤销操作

#### 批量操作
1. 选择 `10) 批量证书操作`
2. 选择批量申请、续期或检查

## 监控和告警

### 访问Grafana仪表板

1. 获取Grafana访问地址：
```bash
kubectl get svc -n monitoring prometheus-grafana
```

2. 端口转发到本地：
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

3. 浏览器访问: `http://localhost:3000`
4. 使用管理员密码登录

### 查看监控指标

#### 系统监控
- CPU使用率
- 内存使用率
- 磁盘使用率
- 网络流量

#### 服务监控
- Synapse服务状态
- LiveKit服务状态
- 数据库连接数
- 证书过期时间

### 告警配置

#### 查看告警规则
```bash
kubectl get prometheusrules -n monitoring
```

#### 查看当前告警
```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
```
访问: `http://localhost:9090/alerts`

## 故障排除

### 常见问题

#### 1. 服务无法启动
**症状**: Pod状态为Pending或CrashLoopBackOff
**解决方案**:
```bash
# 查看Pod详情
kubectl describe pod -n ess <pod-name>

# 查看Pod日志
kubectl logs -n ess <pod-name>

# 检查资源使用
kubectl top nodes
kubectl top pods -n ess
```

#### 2. 证书申请失败
**症状**: Certificate状态为False
**解决方案**:
```bash
# 查看证书状态
kubectl describe certificate -n ess

# 查看Challenge状态
kubectl get challenges -A

# 检查Cloudflare API Token
kubectl get secret cloudflare-api-token-secret -n cert-manager -o yaml
```

#### 3. 无法访问服务
**症状**: 浏览器无法访问Matrix服务
**解决方案**:
```bash
# 检查Ingress状态
kubectl get ingress -n ess

# 检查Service状态
kubectl get svc -n ess

# 检查端口转发
netstat -tuln | grep -E "(30080|30443|30448)"
```

#### 4. 数据库连接失败
**症状**: Synapse无法连接PostgreSQL
**解决方案**:
```bash
# 检查PostgreSQL状态
kubectl get pods -n ess -l app.kubernetes.io/name=postgresql

# 检查数据库密码
kubectl get secret -n ess postgresql-secret -o yaml

# 测试数据库连接
kubectl exec -it -n ess deployment/postgresql -- psql -U postgres
```

### 日志查看

#### 系统日志
```bash
# 查看systemd服务日志
journalctl -u matrix-ip-check.timer
journalctl -u matrix-health-check.timer

# 查看脚本执行日志
tail -f /opt/matrix/logs/ip-check.log
tail -f /opt/matrix/logs/health-check.log
```

#### 应用日志
```bash
# 查看Synapse日志
kubectl logs -f -n ess deployment/synapse

# 查看LiveKit日志
kubectl logs -f -n ess deployment/livekit

# 查看MAS日志
kubectl logs -f -n ess deployment/mas
```

### 性能优化

#### 资源调整
1. 进入 `11) 系统管理`
2. 选择 `6) 配置管理`
3. 选择 `4) 修改副本数配置`
4. 根据负载调整副本数

#### 自动扩缩容
```bash
# 查看HPA状态
kubectl get hpa -n ess

# 查看资源使用
kubectl top pods -n ess
```

## 安全建议

### 网络安全
1. 定期更新系统和软件包
2. 配置防火墙规则
3. 使用强密码和双因素认证
4. 定期检查访问日志

### 证书安全
1. 定期检查证书有效期
2. 及时续期即将过期的证书
3. 使用生产证书而非测试证书
4. 备份证书私钥

### 数据安全
1. 启用自动备份
2. 定期验证备份可用性
3. 加密敏感数据
4. 限制数据库访问权限

## 维护计划

### 日常维护
- 检查服务状态
- 查看监控告警
- 检查磁盘空间
- 查看系统日志

### 周期维护
- 更新系统软件包
- 检查证书有效期
- 清理旧日志文件
- 验证备份可用性

### 月度维护
- 更新Matrix组件
- 检查安全补丁
- 优化性能配置
- 审查用户权限

## 升级指南

### 组件升级
1. 进入 `11) 系统管理`
2. 选择 `3) 更新组件`
3. 确认升级操作

### 脚本升级
```bash
# 下载新版本脚本
curl -fsSL https://raw.githubusercontent.com/niublab/ess-helm-nat/main/setup.sh -o setup-new.sh

# 备份当前配置
cp /opt/matrix/.env /opt/matrix/.env.backup

# 使用新脚本
chmod +x setup-new.sh
./setup-new.sh
```

## 支持和帮助

### 获取帮助
- 查看脚本帮助: `./setup.sh --help`
- 查看版本信息: `./setup.sh --version`
- 查看部署信息: 选择菜单选项 `8) 查看部署信息`

### 社区支持
- GitHub Issues: 报告问题和建议
- Matrix社区: 加入Matrix官方社区
- 文档更新: 贡献文档改进

### 联系方式
如有问题，请通过以下方式联系：
- GitHub: https://github.com/niublab/ess-helm-nat
- 邮箱: 根据实际情况填写

---

**注意**: 本指南基于完善后的 ess-helm-nat 项目，确保在部署前已经配置好ddns-go服务和DNS解析。

