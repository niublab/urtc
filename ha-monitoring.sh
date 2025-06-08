# Matrix Stack 健康监控配置
# 基于Prometheus和Grafana的监控方案

# 安装监控组件
install_monitoring() {
    log "安装监控组件..."
    
    # 添加Prometheus Helm仓库
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    
    # 创建监控命名空间
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # 安装kube-prometheus-stack
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --set grafana.adminPassword="$(get_env "ADMIN_PASSWORD" "")" \
        --wait
    
    log "监控组件安装完成"
}

# 配置Matrix服务监控
configure_matrix_monitoring() {
    log "配置Matrix服务监控..."
    
    # 创建Synapse ServiceMonitor
    cat > "$MATRIX_CONFIG/synapse-servicemonitor.yaml" << EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: synapse-metrics
  namespace: monitoring
  labels:
    app: synapse
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: synapse
  endpoints:
  - port: metrics
    interval: 30s
    path: /_synapse/metrics
EOF
    
    # 创建LiveKit ServiceMonitor
    cat > "$MATRIX_CONFIG/livekit-servicemonitor.yaml" << EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: livekit-metrics
  namespace: monitoring
  labels:
    app: livekit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: livekit
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
EOF
    
    # 应用监控配置
    kubectl apply -f "$MATRIX_CONFIG/synapse-servicemonitor.yaml"
    kubectl apply -f "$MATRIX_CONFIG/livekit-servicemonitor.yaml"
    
    log "Matrix服务监控配置完成"
}

# 创建告警规则
create_alert_rules() {
    log "创建告警规则..."
    
    cat > "$MATRIX_CONFIG/matrix-alerts.yaml" << EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: matrix-alerts
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
    role: alert-rules
spec:
  groups:
  - name: matrix.rules
    rules:
    - alert: SynapseDown
      expr: up{job="synapse-metrics"} == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Synapse服务不可用"
        description: "Synapse服务已停止响应超过5分钟"
    
    - alert: LiveKitDown
      expr: up{job="livekit-metrics"} == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "LiveKit服务不可用"
        description: "LiveKit服务已停止响应超过5分钟"
    
    - alert: HighMemoryUsage
      expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes > 0.9
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "内存使用率过高"
        description: "节点内存使用率超过90%"
    
    - alert: HighCPUUsage
      expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "CPU使用率过高"
        description: "节点CPU使用率超过80%"
    
    - alert: DiskSpaceLow
      expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 10
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "磁盘空间不足"
        description: "根分区可用空间少于10%"
    
    - alert: CertificateExpiringSoon
      expr: (cert_manager_certificate_expiration_timestamp_seconds - time()) / 86400 < 30
      for: 1h
      labels:
        severity: warning
      annotations:
        summary: "证书即将过期"
        description: "SSL证书将在30天内过期"
EOF
    
    kubectl apply -f "$MATRIX_CONFIG/matrix-alerts.yaml"
    
    log "告警规则创建完成"
}

# 配置Grafana仪表板
configure_grafana_dashboards() {
    log "配置Grafana仪表板..."
    
    # Matrix服务仪表板
    cat > "$MATRIX_CONFIG/matrix-dashboard.json" << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "Matrix Services Dashboard",
    "tags": ["matrix"],
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "Synapse Status",
        "type": "stat",
        "targets": [
          {
            "expr": "up{job=\"synapse-metrics\"}",
            "legendFormat": "Synapse"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "mappings": [
              {
                "options": {
                  "0": {
                    "text": "DOWN",
                    "color": "red"
                  },
                  "1": {
                    "text": "UP",
                    "color": "green"
                  }
                },
                "type": "value"
              }
            ]
          }
        },
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 0
        }
      },
      {
        "id": 2,
        "title": "LiveKit Status",
        "type": "stat",
        "targets": [
          {
            "expr": "up{job=\"livekit-metrics\"}",
            "legendFormat": "LiveKit"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "mappings": [
              {
                "options": {
                  "0": {
                    "text": "DOWN",
                    "color": "red"
                  },
                  "1": {
                    "text": "UP",
                    "color": "green"
                  }
                },
                "type": "value"
              }
            ]
          }
        },
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 0
        }
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "30s"
  }
}
EOF
    
    # 创建ConfigMap
    kubectl create configmap matrix-dashboard \
        --from-file="$MATRIX_CONFIG/matrix-dashboard.json" \
        --namespace monitoring \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log "Grafana仪表板配置完成"
}

# 健康检查脚本
create_health_check_script() {
    log "创建健康检查脚本..."
    
    cat > "$MATRIX_CONFIG/health-check.sh" << 'EOF'
#!/bin/bash
# Matrix服务健康检查脚本

MATRIX_HOME="/opt/matrix"
ENV_FILE="$MATRIX_HOME/.env"
LOG_FILE="$MATRIX_HOME/logs/health-check.log"
NAMESPACE="ess"

# 加载环境变量
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

# 日志函数
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 检查Pod状态
check_pod_status() {
    local service_name="$1"
    local pod_status=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$service_name" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    
    if [[ "$pod_status" == "Running" ]]; then
        log_message "✓ $service_name: 运行正常"
        return 0
    else
        log_message "✗ $service_name: 状态异常 ($pod_status)"
        return 1
    fi
}

# 检查服务可达性
check_service_connectivity() {
    local service_name="$1"
    local port="$2"
    local path="${3:-/}"
    
    local service_ip=$(kubectl get svc -n "$NAMESPACE" "$service_name" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    
    if [[ -n "$service_ip" ]]; then
        if curl -s --max-time 10 "http://$service_ip:$port$path" >/dev/null; then
            log_message "✓ $service_name: 网络连接正常"
            return 0
        else
            log_message "✗ $service_name: 网络连接失败"
            return 1
        fi
    else
        log_message "✗ $service_name: 服务不存在"
        return 1
    fi
}

# 检查证书状态
check_certificate_status() {
    log_message "检查证书状态..."
    
    local cert_issues=0
    
    # 检查cert-manager证书
    while IFS= read -r cert_info; do
        local cert_name=$(echo "$cert_info" | awk '{print $1}')
        local ready_status=$(echo "$cert_info" | awk '{print $2}')
        
        if [[ "$ready_status" == "True" ]]; then
            log_message "✓ 证书 $cert_name: 状态正常"
        else
            log_message "✗ 证书 $cert_name: 状态异常"
            ((cert_issues++))
        fi
    done < <(kubectl get certificates -n "$NAMESPACE" --no-headers 2>/dev/null)
    
    return $cert_issues
}

# 检查存储状态
check_storage_status() {
    log_message "检查存储状态..."
    
    local storage_issues=0
    
    # 检查PVC状态
    while IFS= read -r pvc_info; do
        local pvc_name=$(echo "$pvc_info" | awk '{print $1}')
        local pvc_status=$(echo "$pvc_info" | awk '{print $2}')
        
        if [[ "$pvc_status" == "Bound" ]]; then
            log_message "✓ 存储 $pvc_name: 状态正常"
        else
            log_message "✗ 存储 $pvc_name: 状态异常 ($pvc_status)"
            ((storage_issues++))
        fi
    done < <(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null)
    
    return $storage_issues
}

# 检查资源使用情况
check_resource_usage() {
    log_message "检查资源使用情况..."
    
    # 检查内存使用
    local mem_usage=$(free | awk '/^Mem:/{printf "%.1f", $3/$2 * 100.0}')
    if (( $(echo "$mem_usage > 90" | bc -l) )); then
        log_message "⚠ 内存使用率过高: ${mem_usage}%"
    else
        log_message "✓ 内存使用率正常: ${mem_usage}%"
    fi
    
    # 检查磁盘使用
    local disk_usage=$(df / | awk 'NR==2{printf "%.1f", $3/$2 * 100.0}')
    if (( $(echo "$disk_usage > 90" | bc -l) )); then
        log_message "⚠ 磁盘使用率过高: ${disk_usage}%"
    else
        log_message "✓ 磁盘使用率正常: ${disk_usage}%"
    fi
}

# 主检查函数
main_health_check() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log_message "开始健康检查..."
    
    local total_issues=0
    
    # 检查核心服务
    local services=("synapse" "elementweb" "mas" "livekit" "postgresql" "haproxy")
    
    for service in "${services[@]}"; do
        if ! check_pod_status "$service"; then
            ((total_issues++))
        fi
    done
    
    # 检查服务连接
    check_service_connectivity "synapse" "8008" "/_matrix/client/versions" || ((total_issues++))
    check_service_connectivity "livekit" "7880" "/rtc" || ((total_issues++))
    
    # 检查证书
    check_certificate_status || ((total_issues++))
    
    # 检查存储
    check_storage_status || ((total_issues++))
    
    # 检查资源使用
    check_resource_usage
    
    # 总结
    if [[ $total_issues -eq 0 ]]; then
        log_message "✓ 所有检查通过，系统运行正常"
    else
        log_message "⚠ 发现 $total_issues 个问题，请检查日志"
    fi
    
    log_message "健康检查完成"
    return $total_issues
}

# 执行检查
main_health_check
EOF
    
    chmod +x "$MATRIX_CONFIG/health-check.sh"
    
    # 创建systemd服务
    sudo tee /etc/systemd/system/matrix-health-check.service > /dev/null << EOF
[Unit]
Description=Matrix Health Check Service
After=network.target

[Service]
Type=oneshot
User=$USER
ExecStart=$MATRIX_CONFIG/health-check.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # 创建systemd定时器
    sudo tee /etc/systemd/system/matrix-health-check.timer > /dev/null << EOF
[Unit]
Description=Matrix Health Check Timer
Requires=matrix-health-check.service

[Timer]
OnCalendar=*:0/10
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # 启用定时器
    sudo systemctl daemon-reload
    sudo systemctl enable matrix-health-check.timer
    sudo systemctl start matrix-health-check.timer
    
    log "健康检查脚本创建完成"
}

# 性能优化配置
configure_performance_optimization() {
    log "配置性能优化..."
    
    # 创建资源限制配置
    cat > "$MATRIX_CONFIG/resource-limits.yaml" << EOF
# 资源限制配置
apiVersion: v1
kind: LimitRange
metadata:
  name: matrix-resource-limits
  namespace: ess
spec:
  limits:
  - default:
      cpu: "1000m"
      memory: "1Gi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    type: Container
  - max:
      cpu: "4000m"
      memory: "8Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
    type: Container
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: matrix-resource-quota
  namespace: ess
spec:
  hard:
    requests.cpu: "2000m"
    requests.memory: "4Gi"
    limits.cpu: "8000m"
    limits.memory: "16Gi"
    persistentvolumeclaims: "10"
EOF
    
    kubectl apply -f "$MATRIX_CONFIG/resource-limits.yaml"
    
    # 配置Pod优先级
    cat > "$MATRIX_CONFIG/priority-classes.yaml" << EOF
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: matrix-critical
value: 1000
globalDefault: false
description: "Critical Matrix services"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: matrix-high
value: 500
globalDefault: false
description: "High priority Matrix services"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: matrix-normal
value: 100
globalDefault: true
description: "Normal priority Matrix services"
EOF
    
    kubectl apply -f "$MATRIX_CONFIG/priority-classes.yaml"
    
    log "性能优化配置完成"
}

# 网络策略配置
configure_network_policies() {
    log "配置网络策略..."
    
    cat > "$MATRIX_CONFIG/network-policies.yaml" << EOF
# 默认拒绝所有入站流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: ess
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
# 允许Synapse访问PostgreSQL
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-synapse-to-postgresql
  namespace: ess
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgresql
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: synapse
    ports:
    - protocol: TCP
      port: 5432
---
# 允许外部访问HAProxy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-to-haproxy
  namespace: ess
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: haproxy
  policyTypes:
  - Ingress
  ingress:
  - ports:
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 443
    - protocol: TCP
      port: 8448
---
# 允许内部服务间通信
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-internal-communication
  namespace: ess
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/part-of: matrix-stack
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/part-of: matrix-stack
EOF
    
    kubectl apply -f "$MATRIX_CONFIG/network-policies.yaml"
    
    log "网络策略配置完成"
}

# 自动扩缩容配置
configure_autoscaling() {
    log "配置自动扩缩容..."
    
    # 安装metrics-server（如果未安装）
    if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
        
        # 为K3s配置metrics-server
        kubectl patch deployment metrics-server -n kube-system --type='json' \
            -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
    fi
    
    # 创建HPA配置
    cat > "$MATRIX_CONFIG/hpa.yaml" << EOF
# Synapse HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: synapse-hpa
  namespace: ess
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: synapse
  minReplicas: $(get_env "SYNAPSE_REPLICAS" "1")
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
---
# Element Web HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: elementweb-hpa
  namespace: ess
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: elementweb
  minReplicas: $(get_env "ELEMENT_REPLICAS" "1")
  maxReplicas: 3
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
---
# LiveKit HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: livekit-hpa
  namespace: ess
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: livekit
  minReplicas: $(get_env "LIVEKIT_REPLICAS" "1")
  maxReplicas: 3
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 70
EOF
    
    kubectl apply -f "$MATRIX_CONFIG/hpa.yaml"
    
    log "自动扩缩容配置完成"
}

# 日志聚合配置
configure_log_aggregation() {
    log "配置日志聚合..."
    
    # 创建Fluent Bit配置
    cat > "$MATRIX_CONFIG/fluent-bit-config.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: kube-system
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         1
        Log_Level     info
        Daemon        off
        Parsers_File  parsers.conf
        HTTP_Server   On
        HTTP_Listen   0.0.0.0
        HTTP_Port     2020

    [INPUT]
        Name              tail
        Path              /var/log/containers/*matrix*.log
        Parser            docker
        Tag               matrix.*
        Refresh_Interval  5

    [FILTER]
        Name                kubernetes
        Match               matrix.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Merge_Log           On
        K8S-Logging.Parser  On
        K8S-Logging.Exclude Off

    [OUTPUT]
        Name  file
        Match matrix.*
        Path  /var/log/matrix/
        File  matrix.log
        Format json_lines

  parsers.conf: |
    [PARSER]
        Name   docker
        Format json
        Time_Key time
        Time_Format %Y-%m-%dT%H:%M:%S.%L
        Time_Keep   On
EOF
    
    kubectl apply -f "$MATRIX_CONFIG/fluent-bit-config.yaml"
    
    log "日志聚合配置完成"
}

# 备份策略配置
configure_backup_strategy() {
    log "配置备份策略..."
    
    # 创建备份CronJob
    cat > "$MATRIX_CONFIG/backup-cronjob.yaml" << EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: matrix-backup
  namespace: ess
spec:
  schedule: "0 2 * * *"  # 每天凌晨2点
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:13
            command:
            - /bin/bash
            - -c
            - |
              pg_dump -h postgresql -U postgres -d synapse > /backup/synapse-\$(date +%Y%m%d).sql
              pg_dump -h postgresql -U postgres -d mas > /backup/mas-\$(date +%Y%m%d).sql
              # 清理7天前的备份
              find /backup -name "*.sql" -mtime +7 -delete
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgresql-secret
                  key: password
            volumeMounts:
            - name: backup-storage
              mountPath: /backup
          volumes:
          - name: backup-storage
            persistentVolumeClaim:
              claimName: backup-pvc
          restartPolicy: OnFailure
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backup-pvc
  namespace: ess
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF
    
    kubectl apply -f "$MATRIX_CONFIG/backup-cronjob.yaml"
    
    log "备份策略配置完成"
}

# 安全加固配置
configure_security_hardening() {
    log "配置安全加固..."
    
    # 创建Pod安全策略
    cat > "$MATRIX_CONFIG/pod-security-policy.yaml" << EOF
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: matrix-psp
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
    - ALL
  volumes:
    - 'configMap'
    - 'emptyDir'
    - 'projected'
    - 'secret'
    - 'downwardAPI'
    - 'persistentVolumeClaim'
  runAsUser:
    rule: 'MustRunAsNonRoot'
  seLinux:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: matrix-psp-user
rules:
- apiGroups: ['policy']
  resources: ['podsecuritypolicies']
  verbs: ['use']
  resourceNames:
  - matrix-psp
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: matrix-psp-binding
roleRef:
  kind: ClusterRole
  name: matrix-psp-user
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: default
  namespace: ess
EOF
    
    kubectl apply -f "$MATRIX_CONFIG/pod-security-policy.yaml"
    
    log "安全加固配置完成"
}

# 主函数：配置所有高可用和监控功能
configure_ha_monitoring() {
    log "开始配置高可用和监控功能..."
    
    # 安装监控组件
    install_monitoring
    
    # 配置Matrix服务监控
    configure_matrix_monitoring
    
    # 创建告警规则
    create_alert_rules
    
    # 配置Grafana仪表板
    configure_grafana_dashboards
    
    # 创建健康检查脚本
    create_health_check_script
    
    # 配置性能优化
    configure_performance_optimization
    
    # 配置网络策略
    configure_network_policies
    
    # 配置自动扩缩容
    configure_autoscaling
    
    # 配置日志聚合
    configure_log_aggregation
    
    # 配置备份策略
    configure_backup_strategy
    
    # 配置安全加固
    configure_security_hardening
    
    log "高可用和监控功能配置完成"
}

