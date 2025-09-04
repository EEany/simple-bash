#!/bin/bash

# ==============================================================================
# Prometheus & Node Exporter 自动化安装脚本 (v2)
#
# 功能:
# 1. 检查并请求 Root 权限.
# 2. 安装必要的依赖: supervisor, ufw.
# 3. 使用 ghfast.com 镜像下载最新的 Prometheus 和 Node Exporter.
# 4. 解压并安装到 /opt/workspace/ 目录下.
# 5. 创建详细的默认 Prometheus 配置文件.
# 6. 配置 Supervisor 来监控和管理这两个服务.
# 7. 智能配置 UFW 防火墙规则 (检测现有状态).
# 8. 完成后打印总结报告.
#
# 使用方法:
# 1. 保存脚本为 setup_monitoring.sh
# 2. chmod +x setup_monitoring.sh
# 3. sudo ./setup_monitoring.sh
# ==============================================================================

# --- 全局变量 ---
# 使用 set -e 命令，确保脚本在任何命令返回非零退出状态时立即退出
set -e

# 定义软件版本 (可以根据需要更新)
PROMETHEUS_VERSION="3.5.0"
NODE_EXPORTER_VERSION="1.9.1"
ARCH="linux-amd64"

# 定义安装路径
INSTALL_DIR="/opt/workspace"
PROMETHEUS_DIR="${INSTALL_DIR}/prometheus"
NODE_EXPORTER_DIR="${INSTALL_DIR}/node_exporter"

# 为中国服务器定义的下载镜像
GITHUB_MIRROR="https://ghfast.top"

# --- 颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- 函数定义 ---

# 打印信息
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# 1. 检查 Root 权限
check_root() {
    log_info "检查 Root 权限..."
    if [ "$(id -u)" != "0" ]; then
       log_error "此脚本必须使用 root 权限运行。请尝试使用 'sudo ./setup_monitoring.sh'。"
    fi
    log_info "权限检查通过。"
}

# 2. 安装依赖 (Supervisor, UFW)
install_dependencies() {
    log_info "正在更新软件包列表并安装依赖 (supervisor, ufw)..."
    # 适用于 Debian/Ubuntu 系统
    apt-get update > /dev/null
    apt-get install -y supervisor ufw curl > /dev/null
    log_info "依赖安装完成。"
    
    # 启动并启用 supervisor
    systemctl enable supervisor
    systemctl start supervisor
    log_info "Supervisor 已启动并设置为开机自启。"
}

# 3. 下载并解压 Prometheus 和 Node Exporter
download_and_setup() {
    log_info "正在创建安装目录: ${INSTALL_DIR}"
    mkdir -p ${INSTALL_DIR}
    cd ${INSTALL_DIR}

    # 下载 Prometheus
    PROMETHEUS_URL="${GITHUB_MIRROR}/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.${ARCH}.tar.gz"
    log_info "正在从镜像下载 Prometheus..."
    curl -sLO ${PROMETHEUS_URL}
    tar xvf prometheus-${PROMETHEUS_VERSION}.${ARCH}.tar.gz > /dev/null
    mv prometheus-${PROMETHEUS_VERSION}.${ARCH} prometheus
    rm prometheus-${PROMETHEUS_VERSION}.${ARCH}.tar.gz
    log_info "Prometheus 已安装到 ${PROMETHEUS_DIR}"

    # 下载 Node Exporter
    NODE_EXPORTER_URL="${GITHUB_MIRROR}/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz"
    log_info "正在从镜像下载 Node Exporter..."
    curl -sLO ${NODE_EXPORTER_URL}
    tar xvf node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz > /dev/null
    mv node_exporter-${NODE_EXPORTER_VERSION}.${ARCH} node_exporter
    rm node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz
    log_info "Node Exporter 已安装到 ${NODE_EXPORTER_DIR}"
}

# 4. 创建 Prometheus 配置文件
create_prometheus_config() {
    log_info "正在创建 Prometheus 默认配置文件..."
    # 使用 'EOF' 来防止变量替换，保持文件内容原样
    cat > ${PROMETHEUS_DIR}/prometheus.yml << 'EOF'
#====================================================================================
# 全 局 配 置  (Global Settings)
#====================================================================================
global:
  # 指 标 数 据 抓 取 频 率 。
  scrape_interval: 10s
  # 告 警 规 则 的 检 查 频 率 。
  evaluation_interval: 15s
  # 抓 取 超 时 时 间 。
  scrape_timeout: 8s

#====================================================================================
# 告 警 管 理 器  (Alertmanager) 配 置
#====================================================================================
alerting:
  alertmanagers:
    # 这 里 定 义 了 Prometheus 要 将 触 发 的 告 警 发 送 到 哪 个 Alertmanager 实 例 。
    - static_configs:
        - targets:
          # - alertmanager:9093 # Alertmanager 的 地 址 。 取 消 此 行 的 注 释 来 启 用 它 。

#====================================================================================
# 告 警 规 则 文 件 加 载
#====================================================================================
rule_files:
  # Prometheus 会 从 这 里 加 载 告 警 规 则 的 .yml 文 件 。 可 以 有 多 个 。
  # - "alert_rules.yml"
  # - "another_rules.yml"

#====================================================================================
# 数 据 抓 取 配 置  (Scrape Configurations)
#====================================================================================
scrape_configs:
  # --- 任 务 : 监 控 Prometheus 自 身 ---
  - job_name: 'prometheus'
    # 任 务 名 (job_name) 会 作 为 一 个 标 签 (例 如 : job="prometheus")
    # 添 加 到 所 有 从 这 个 任 务 抓 取 到 的 指 标 上 ， 方 便 后 续 查 询 和 筛 选 。
    static_configs:
      # 监 控 目 标 的 地 址 列 表 。 这 里 是 监 控 Prometheus 自 己 。
      - targets: [ 'localhost:9090' ]

  # --- 任 务 : 监 控 服 务 器 硬 件 和 操 作 系 统 (Node Exporter) ---
  - job_name: 'node_exporter'
    static_configs:
      # Node Exporter 通 常 运 行 在 9100 端 口 。
      # 如 果 Prometheus 和 Node Exporter 都 在 宿 主 机 上 运 行 ， 则 使 用 'localhost:9100'。
      - targets: [ 'localhost:9100' ]
EOF
    log_info "配置文件创建成功: ${PROMETHEUS_DIR}/prometheus.yml"
}

# 5. 配置 Supervisor
configure_supervisor() {
    log_info "正在配置 Supervisor..."
    
    # Prometheus Supervisor 配置
    cat > /etc/supervisor/conf.d/prometheus.conf << EOF
[program:prometheus]
command=${PROMETHEUS_DIR}/prometheus --config.file=${PROMETHEUS_DIR}/prometheus.yml
directory=${PROMETHEUS_DIR}
autostart=true
autorestart=true
user=root
stopsignal=QUIT
stdout_logfile=/var/log/supervisor/prometheus.log
stderr_logfile=/var/log/supervisor/prometheus_err.log
EOF

    # Node Exporter Supervisor 配置
    cat > /etc/supervisor/conf.d/node_exporter.conf << EOF
[program:node_exporter]
command=${NODE_EXPORTER_DIR}/node_exporter
directory=${NODE_EXPORTER_DIR}
autostart=true
autorestart=true
user=root
stdout_logfile=/var/log/supervisor/node_exporter.log
stderr_logfile=/var/log/supervisor/node_exporter_err.log
EOF

    log_info "Supervisor 配置文件创建完成。"
    log_info "正在重新加载 Supervisor 配置并启动服务..."
    supervisorctl reread
    supervisorctl update
    supervisorctl start prometheus
    supervisorctl start node_exporter
    log_info "Prometheus 和 Node Exporter 已通过 Supervisor 启动。"
}

# 6. 配置防火墙
configure_firewall() {
    log_info "开始配置防火墙 (UFW)..."

    UFW_INSTALLED=false
    if command -v ufw &> /dev/null; then
        UFW_INSTALLED=true
    fi

    # 检查 ufw 是否已经激活
    UFW_ACTIVE=$(ufw status | grep -w "Status: active" || true)

    if [ "$UFW_INSTALLED" = true ] && [ -n "$UFW_ACTIVE" ]; then
        log_info "检测到 UFW 已安装并处于激活状态。将仅添加新规则。"
    else
        if [ "$UFW_INSTALLED" = false ]; then
            log_warn "未检测到 UFW。脚本将为您安装 UFW。"
            apt-get install -y ufw > /dev/null
        fi

        log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! 警告 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log_warn "脚本将启用 UFW 防火墙。为防止服务器失联，请输入您需要保持开放"
        log_warn "的端口 (例如 SSH 端口 22, Web 端口 80 443)。"
        log_warn "多个端口请用空格隔开。如果留空，将只开放 SSH (22) 端口。"
        log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        read -p "请输入需要保持开放的端口 (默认: 22): " essential_ports

        # 如果用户没有输入，则默认开启 22 端口
        if [ -z "$essential_ports" ]; then
            essential_ports="22"
            log_info "未输入端口，默认将开放 SSH 端口 22。"
        fi

        for port in $essential_ports; do
            ufw allow $port comment 'Essential service port'
            log_info "已添加规则: 允许端口 ${port}"
        done
    fi

    # 获取用户输入的监控授权IP地址
    read -p "请输入授权访问监控端口的 IP 地址 (单个IP或多个IP用空格隔开): " authorized_ips

    if [ -z "$authorized_ips" ]; then
        log_warn "没有输入授权IP，将只允许从本地访问监控端口。"
        ufw allow 9090/tcp comment 'Prometheus access (localhost only)'
        ufw allow 9100/tcp comment 'Node Exporter access (localhost only)'
    else
        log_info "正在为以下 IP 授权端口 9090 和 9100: ${authorized_ips}"
        for ip in $authorized_ips; do
            ufw allow from ${ip} to any port 9090 proto tcp comment 'Prometheus access'
            ufw allow from ${ip} to any port 9100 proto tcp comment 'Node Exporter access'
        done
        log_info "防火墙规则已添加。"
    fi

    # 启用防火墙 (如果之前未启用)
    if [ -z "$UFW_ACTIVE" ]; then
        ufw --force enable
        log_info "UFW 已启用。"
    fi
    
    echo "--- 当前 UFW 状态 ---"
    ufw status
    echo "--------------------"
}


# 7. 打印最终报告
print_report() {
    # 获取服务器公网 IP
    SERVER_IP=$(curl -s ifconfig.me)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="<你的服务器IP>"
    fi

    echo -e "\n\n"
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}      监控服务安装与配置完成！ 🎉      ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "\n"
    echo -e "✅ ${YELLOW}Prometheus 状态:${NC} $(supervisorctl status prometheus | awk '{print $2}')"
    echo -e "✅ ${YELLOW}Node Exporter 状态:${NC} $(supervisorctl status node_exporter | awk '{print $2}')"
    echo -e "\n"
    log_info "服务详情:"
    echo -e "  - ${YELLOW}Prometheus Web UI:${NC} http://${SERVER_IP}:9090"
    echo -e "  - ${YELLOW}Node Exporter Metrics:${NC} http://${SERVER_IP}:9100/metrics"
    echo -e "  - ${YELLOW}安装目录:${NC} ${INSTALL_DIR}"
    echo -e "  - ${YELLOW}Supervisor 配置文件:${NC} /etc/supervisor/conf.d/"
    echo -e "\n"
    log_info "防火墙 (UFW) 规则摘要 (监控相关):"
    ufw status | grep -E "9090|9100" || echo "  未找到监控相关规则或 UFW 未激活。"
    echo -e "\n"
    log_info "下一步操作:"
    echo -e "  在您的 Grafana 服务器中，添加一个新的 Prometheus 数据源。"
    echo -e "  使用以下地址进行连接:"
    echo -e "  ${YELLOW}URL: http://${SERVER_IP}:9090${NC}"
    echo -e "\n"
    echo -e "${GREEN}=====================================================${NC}"
}


# --- 主程序 ---
main() {
    clear
    echo -e "${GREEN}欢迎使用 Prometheus & Node Exporter 自动化部署工具 v3${NC}"
    echo -e "----------------------------------------------------"
    check_root
    install_dependencies
    download_and_setup
    create_prometheus_config
    configure_supervisor
    configure_firewall
    print_report
}

# 执行主函数
main


