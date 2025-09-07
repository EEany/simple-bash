#!/bin/bash

# ==============================================================================
# Prometheus & Node Exporter 自动化安装脚本 (monitor.sh v3)
#
# 功能:
# 1. 检查并请求 Root 权限.
# 2. 自动检测系统发行版 (Debian/Ubuntu/CentOS/RHEL) 和架构 (x86_64/arm64).
# 3. 创建专用的低权限系统用户 'prometheus' 来运行服务，增强安全性.
# 4. 安装必要的依赖 (ufw, curl).
# 5. [新] 使用多个加速镜像轮询下载，并加入最多3次失败重试功能.
# 6. 下载官方 SHA256 校验和文件，并验证软件包完整性.
# 7. 解压并安装服务.
# 8. 创建详细的默认 Prometheus 配置文件.
# 9. 配置 Systemd 来管理这两个服务，实现开机自启.
# 10. 智能配置 UFW 防火墙规则.
# 11. 自动安装 starnode 管理工具到 /usr/local/bin，实现全局访问.
# 12. 完成后打印详细的总结报告.
#
# ==============================================================================

# --- 脚本设置 ---
set -e
set -u

# --- 全局变量 ---
PROMETHEUS_VERSION="2.53.0"
NODE_EXPORTER_VERSION="1.8.2"
INSTALL_BASE_DIR="/opt/prometheus"
USER="prometheus"
GROUP="prometheus"

# [更新] 使用您提供的最新 GitHub 加速镜像列表
GITHUB_MIRRORS=(
    "https://gh-proxy.com"
    "https://hk.gh-proxy.com"
    "https://cdn.gh-proxy.com"
    "https://edgeone.gh-proxy.com"
)

# --- 颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- 函数定义 ---

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# 带重试和轮询功能的下载函数
# 参数1: 原始 GitHub 下载 URL
# 参数2: 保存的文件名
download_with_retry() {
    local original_url="$1"
    local output_filename="$2"
    local max_attempts=3
    local attempt=1
    local success=false

    while [ "$attempt" -le "$max_attempts" ]; do
        # 通过取余运算实现镜像轮询
        local mirror_index=$(( (attempt - 1) % ${#GITHUB_MIRRORS[@]} ))
        local mirror_host="${GITHUB_MIRRORS[$mirror_index]}"
        local full_url="${mirror_host}/${original_url}"

        log_info "尝试下载 (第 ${attempt}/${max_attempts} 次) 从: ${mirror_host}"
        
        # 使用 -o 指定输出文件名，因为 URL 结构变了
        if curl --progress-bar -fL -o "${output_filename}" "${full_url}"; then
            log_info "下载成功。"
            success=true
            break
        else
            log_warn "从 ${mirror_host} 下载失败。"
            if [ "$attempt" -lt "$max_attempts" ]; then
                log_warn "将在2秒后尝试下一个镜像..."
                sleep 2
            fi
        fi
        ((attempt++))
    done

    if [ "$success" = false ]; then
        log_error "所有下载尝试均失败。请检查您的网络连接或镜像可用性。"
    fi
}


# 1. 检查 Root 权限
check_root() {
    log_info "检查 Root 权限..."
    if [ "$(id -u)" != "0" ]; then
        log_error "此脚本必须使用 root 权限运行。请尝试使用 'sudo ./monitor.sh'。"
    fi
    log_info "权限检查通过。"
}

# 2. 检测系统发行版和架构
detect_distro_and_arch() {
    log_info "正在检测系统环境..."
    MACHINE_ARCH=$(uname -m)
    case "${MACHINE_ARCH}" in
        x86_64) ARCH="linux-amd64" ;;
        aarch64) ARCH="linux-arm64" ;;
        *) log_error "不支持的系统架构: ${MACHINE_ARCH}" ;;
    esac
    log_info "检测到系统架构: ${ARCH}"

    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
        INSTALL_CMD="apt-get install -y"
        UPDATE_CMD="apt-get update"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y"
        UPDATE_CMD="yum makecache"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y"
        UPDATE_CMD="dnf makecache"
    else
        log_error "未找到支持的包管理器 (apt-get, yum, or dnf)。"
    fi
    log_info "检测到包管理器: ${PKG_MANAGER}"
}

# 3. 创建专用的服务用户
create_service_user() {
    log_info "正在创建专用的系统用户 '${USER}'..."
    if id -u "${USER}" &>/dev/null; then
        log_warn "用户 '${USER}' 已存在，跳过创建步骤。"
    else
        useradd --system --no-create-home --shell /bin/false "${USER}"
        log_info "系统用户 '${USER}' 创建成功。"
    fi
}

# 4. 安装依赖
install_dependencies() {
    log_info "正在更新软件包列表并安装依赖 (ufw, curl)..."
    ${UPDATE_CMD} > /dev/null
    ${INSTALL_CMD} ufw curl tar > /dev/null
    log_info "依赖安装完成。"
}

# 5. 下载、校验并安装
download_and_setup() {
    log_info "正在创建安装目录: ${INSTALL_BASE_DIR}"
    rm -rf "${INSTALL_BASE_DIR}"
    mkdir -p "${INSTALL_BASE_DIR}"
    
    # --- 处理 Prometheus ---
    cd "${INSTALL_BASE_DIR}"
    local PROMETHEUS_FILENAME="prometheus-${PROMETHEUS_VERSION}.${ARCH}.tar.gz"
    local PROMETHEUS_DL_URL="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/${PROMETHEUS_FILENAME}"
    local SHA256_FILENAME="prometheus-sha256sums.txt" # Use a unique name
    local SHA256_URL="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/sha256sums.txt"

    log_info "正在下载 Prometheus (v${PROMETHEUS_VERSION})..."
    download_with_retry "${PROMETHEUS_DL_URL}" "${PROMETHEUS_FILENAME}"
    
    log_info "正在下载 Prometheus SHA256 校验和文件..."
    download_with_retry "${SHA256_URL}" "${SHA256_FILENAME}"
    
    log_info "正在校验 Prometheus 文件完整性..."
    grep "${PROMETHEUS_FILENAME}" "${SHA256_FILENAME}" | sha256sum --check --strict || log_error "Prometheus 文件校验失败！"
    
    log_info "校验成功，正在解压 Prometheus..."
    tar xzf "${PROMETHEUS_FILENAME}" --strip-components=1 -C "${INSTALL_BASE_DIR}" > /dev/null
    rm -f "${PROMETHEUS_FILENAME}" "${SHA256_FILENAME}"
    log_info "Prometheus 已安装到 ${INSTALL_BASE_DIR}"

    # --- 处理 Node Exporter ---
    cd /tmp
    local NODE_EXPORTER_FILENAME="node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz"
    local NODE_EXPORTER_DL_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_FILENAME}"
    SHA256_FILENAME="node-exporter-sha256sums.txt" # Use a unique name
    SHA256_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/sha256sums.txt"
    
    log_info "正在下载 Node Exporter (v${NODE_EXPORTER_VERSION})..."
    download_with_retry "${NODE_EXPORTER_DL_URL}" "${NODE_EXPORTER_FILENAME}"

    log_info "正在下载 Node Exporter SHA256 校验和文件..."
    download_with_retry "${SHA256_URL}" "${SHA256_FILENAME}"
    
    log_info "正在校验 Node Exporter 文件完整性..."
    grep "${NODE_EXPORTER_FILENAME}" "${SHA256_FILENAME}" | sha256sum --check --strict || log_error "Node Exporter 文件校验失败！"
    
    log_info "校验成功，正在安装 Node Exporter..."
    tar xzf "${NODE_EXPORTER_FILENAME}" > /dev/null
    mv "node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" /usr/local/bin/
    rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}"* "${SHA256_FILENAME}"
    log_info "Node Exporter 已安装到 /usr/local/bin/"

    # --- 设置权限 ---
    log_info "正在设置目录权限..."
    mkdir -p "${INSTALL_BASE_DIR}/data"
    chown -R "${USER}:${GROUP}" "${INSTALL_BASE_DIR}"
}


# 6. 创建 Prometheus 配置文件
create_prometheus_config() {
    log_info "正在创建 Prometheus 默认配置文件..."
    cat > "${INSTALL_BASE_DIR}/prometheus.yml" << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
EOF
    chown "${USER}:${GROUP}" "${INSTALL_BASE_DIR}/prometheus.yml"
    log_info "配置文件创建成功: ${INSTALL_BASE_DIR}/prometheus.yml"
}

# 7. 配置 Systemd 服务
configure_systemd() {
    log_info "正在配置 Systemd 服务..."
    
    cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target
[Service]
User=${USER}
Group=${GROUP}
Type=simple
ExecStart=${INSTALL_BASE_DIR}/prometheus \
    --config.file=${INSTALL_BASE_DIR}/prometheus.yml \
    --storage.tsdb.path=${INSTALL_BASE_DIR}/data/ \
    --web.console.templates=${INSTALL_BASE_DIR}/consoles \
    --web.console.libraries=${INSTALL_BASE_DIR}/console_libraries
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target
[Service]
User=${USER}
Group=${GROUP}
Type=simple
ExecStart=/usr/local/bin/node_exporter
[Install]
WantedBy=multi-user.target
EOF

    log_info "Systemd 配置文件创建完成。"
    log_info "正在重新加载 Systemd 并启动服务..."
    systemctl daemon-reload
    systemctl enable --now prometheus
    systemctl enable --now node_exporter
    log_info "Prometheus 和 Node Exporter 已启动并设置为开机自启。"
}

# 8. 配置防火墙
configure_firewall() {
    log_info "开始配置防火墙 (UFW)..."
    if ! command -v ufw &> /dev/null; then
        log_warn "未找到 ufw 命令，跳过防火墙配置。"
        return
    fi

    local UFW_ACTIVE
    UFW_ACTIVE=$(ufw status | grep -w "Status: active" || true)

    if [ -n "${UFW_ACTIVE}" ]; then
        log_info "检测到 UFW 已激活，将仅添加新规则。"
    else
        log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! 警告 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log_warn "脚本将启用 UFW 防火墙。为防止服务器失联，请输入需要保持开放"
        log_warn "的端口 (例如 SSH 端口 22)。多个端口请用空格隔开。"
        log_warn "如果留空，将只开放 SSH (22) 端口。"
        log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        read -p "请输入需要保持开放的端口 (默认: 22): " essential_ports

        essential_ports=${essential_ports:-22}
        log_info "将开放以下基础端口: ${essential_ports}"

        for port in ${essential_ports}; do
            ufw allow "${port}" comment 'Essential service port'
        done
    fi

    read -p "请输入授权访问监控端口的 IP 地址 (留空则只允许本机访问): " authorized_ips

    if [ -z "${authorized_ips}" ]; then
        log_warn "没有输入授权IP，将只允许从本机 (localhost) 访问监控端口。"
        ufw allow from 127.0.0.1 to any port 9090 proto tcp comment 'Prometheus access (localhost only)'
        ufw allow from 127.0.0.1 to any port 9100 proto tcp comment 'Node Exporter access (localhost only)'
    else
        log_info "正在为以下 IP 授权端口 9090 和 9100: ${authorized_ips}"
        for ip in ${authorized_ips}; do
            ufw allow from "${ip}" to any port 9090 proto tcp comment 'Prometheus access'
            ufw allow from "${ip}" to any port 9100 proto tcp comment 'Node Exporter access'
        done
    fi

    if [ -z "${UFW_ACTIVE}" ]; then
        ufw --force enable
        log_info "UFW 已启用。"
    fi
    
    echo "--- 当前 UFW 状态 ---"
    ufw status
    echo "--------------------"
}

# 9. 安装 starnode 管理工具
install_starnode_cli() {
    log_info "正在安装 starnode 管理工具..."
    
    cat > /usr/local/bin/starnode << 'EOF'
#!/bin/bash
# ==============================================================================
# StarNode - Prometheus & Node Exporter 管理工具
# ==============================================================================

set -u
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
SERVICES=("prometheus" "node_exporter")
PROMETHEUS_INSTALL_DIR="/opt/prometheus"
PROMETHEUS_USER="prometheus"
SYSTEMD_FILES=("/etc/systemd/system/prometheus.service" "/etc/systemd/system/node_exporter.service")

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "此操作需要 root 权限。请使用 'sudo starnode $1'。"
    fi
}

usage() {
    echo "StarNode - Prometheus & Node Exporter 管理工具"
    echo "用法: starnode [命令]"
    echo "-------------------------------------------------"
    echo "  start      启动所有监控服务"
    echo "  stop       停止所有监控服务"
    echo "  restart    重启所有监控服务"
    echo "  status     检查所有监控服务的状态"
    echo "  uninstall  彻底卸载监控服务及其所有数据"
}

do_uninstall() {
    check_root "uninstall"
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! 警告 !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    log_warn "您即将执行彻底卸载操作。这将:"
    log_warn "  1. 停止并禁用 Prometheus 和 Node Exporter 服务。"
    log_warn "  2. 删除所有 Systemd 配置文件。"
    log_warn "  3. 删除整个安装目录 (${PROMETHEUS_INSTALL_DIR})，包括所有监控数据！"
    log_warn "  4. 删除专用的系统用户 '${PROMETHEUS_USER}'。"
    log_warn "  5. 尝试移除相关的防火墙规则。"
    log_warn "此操作不可逆！"
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    read -p "请输入 'uninstall' 以确认执行此操作: " confirmation

    if [ "${confirmation}" != "uninstall" ]; then
        log_info "操作已取消。"
        exit 0
    fi

    log_info "开始卸载流程..."
    log_info "正在停止并禁用 Systemd 服务..."
    systemctl disable --now "${SERVICES[@]}" &> /dev/null
    log_info "正在删除 Systemd 配置文件..."
    rm -f "${SYSTEMD_FILES[@]}"
    systemctl daemon-reload
    log_info "正在删除安装目录和二进制文件..."
    rm -rf "${PROMETHEUS_INSTALL_DIR}"
    rm -f /usr/local/bin/node_exporter
    log_info "正在删除系统用户 '${PROMETHEUS_USER}'..."
    userdel "${PROMETHEUS_USER}" &> /dev/null || log_warn "用户 '${PROMETHEUS_USER}' 可能已被手动删除。"
    log_info "正在尝试移除 UFW 防火墙规则..."
    if command -v ufw &> /dev/null; then
        RULES_TO_DELETE=$(ufw status numbered | grep -E "Prometheus access|Node Exporter access" | awk -F'[][]' '{print $2}' | sort -nr)
        if [ -n "$RULES_TO_DELETE" ]; then
            for num in $RULES_TO_DELETE; do
                yes | ufw delete "$num" > /dev/null && log_info "已删除 UFW 规则 #${num}"
            done
        else
            log_warn "未找到相关的 UFW 规则。"
        fi
    else
        log_warn "未找到 ufw 命令，跳过防火墙规则移除。"
    fi
    echo -e "\n${GREEN}=====================================================${NC}"
    log_info "Prometheus 和 Node Exporter 已成功卸载。"
    echo -e "${GREEN}=====================================================${NC}"
}

if [ $# -eq 0 ]; then usage; exit 1; fi
COMMAND="$1"
case "${COMMAND}" in
    start) check_root "start"; systemctl start "${SERVICES[@]}"; log_info "服务已启动。";;
    stop) check_root "stop"; systemctl stop "${SERVICES[@]}"; log_info "服务已停止。";;
    restart) check_root "restart"; systemctl restart "${SERVICES[@]}"; log_info "服务已重启。";;
    status) log_info "正在检查服务状态..."; systemctl status --no-pager "${SERVICES[@]}";;
    uninstall) do_uninstall;;
    *) log_error "未知命令: ${COMMAND}"; usage; exit 1;;
esac
EOF
    
    chmod +x /usr/local/bin/starnode
    log_info "管理工具 'starnode' 已成功安装到 /usr/local/bin/"
    log_info "您现在可以在系统的任何位置直接使用 'starnode' 命令。"
}


# 10. 打印最终报告
print_report() {
    local SERVER_IP
    SERVER_IP=$(curl -s --fail --connect-timeout 2 ifconfig.me || hostname -I | awk '{print $1}')
    [ -z "${SERVER_IP}" ] && SERVER_IP="<你的服务器IP>"

    local prometheus_status node_exporter_status
    prometheus_status=$(systemctl is-active prometheus)
    node_exporter_status=$(systemctl is-active node_exporter)
    
    echo -e "\n\n"
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}      监控服务安装与配置完成！ 🎉      ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "\n"
    echo -e "✅ ${YELLOW}Prometheus 状态:${NC} ${prometheus_status}"
    echo -e "✅ ${YELLOW}Node Exporter 状态:${NC} ${node_exporter_status}"
    echo -e "\n"
    log_info "服务详情:"
    echo -e "  - ${YELLOW}Prometheus Web UI:${NC} http://${SERVER_IP}:9090"
    echo -e "  - ${YELLOW}Node Exporter Metrics:${NC} http://${SERVER_IP}:9100/metrics"
    echo -e "  - ${YELLOW}Prometheus 安装目录:${NC} ${INSTALL_BASE_DIR}"
    echo -e "  - ${YELLOW}Systemd 配置文件:${NC} /etc/systemd/system/"
    echo -e "\n"
    log_info "全局管理工具:"
    echo -e "  'starnode' 命令已安装到您的系统中。"
    echo -e "  - 查看状态: ${YELLOW}starnode status${NC}"
    echo -e "  - 停止服务: ${YELLOW}sudo starnode stop${NC}"
    echo -e "  - 彻底卸载: ${YELLOW}sudo starnode uninstall${NC}"
    echo -e "\n"
    log_info "下一步操作:"
    echo -e "  在您的 Grafana 中添加 Prometheus 数据源: ${YELLOW}URL: http://${SERVER_IP}:9090${NC}"
    echo -e "\n${GREEN}=====================================================${NC}"
}

# --- 主程序 ---
main() {
    clear
    echo -e "${GREEN}欢迎使用 Prometheus & Node Exporter 自动化部署工具${NC}"
    echo "----------------------------------------------------"
    check_root
    detect_distro_and_arch
    create_service_user
    install_dependencies
    download_and_setup
    create_prometheus_config
    configure_systemd
    configure_firewall
    install_starnode_cli
    print_report
}

# 执行主函数
main
