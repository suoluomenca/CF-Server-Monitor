#!/bin/bash
# =============================================
# CF-Server-Monitor-Pro 安装/卸载脚本
# 支持: Ubuntu/Debian/CentOS/RHEL/Fedora/Rocky/AlmaLinux
# =============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 路径定义
SERVICE_NAME="cf-probe"
SERVICE_FILE="/etc/systemd/system/cf-probe.service"
SCRIPT_FILE="/usr/local/bin/cf-probe.sh"
LOG_FILE="/var/log/cf-probe.log"

# 打印横幅
print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║   CF-Server-Monitor-Pro 探针管理工具     ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 信息输出
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[→]${NC} $1"; }

# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        error "请使用 root 权限运行此脚本: sudo bash $0"
    fi
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi
    
    case "$OS" in
        ubuntu|debian|raspbian)
            PKG_MGR="apt-get"
            ;;
        centos|rhel|fedora|rocky|almalinux|ol|amzn)
            PKG_MGR="yum"
            ;;
        *)
            warn "未识别的系统: $OS，将尝试继续安装"
            PKG_MGR="apt-get"
            ;;
    esac
}

# 安装必要依赖
install_deps() {
    step "检查必要依赖..."
    
    local required_cmds=("curl" "awk" "grep" "sed")
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "$cmd 未安装，尝试安装..."
            case $PKG_MGR in
                apt-get)
                    if ! apt-get update -qq 2>/dev/null; then
                        warn "apt-get update 失败"
                    fi
                    if ! apt-get install -y -qq "$cmd" 2>/dev/null; then
                        error "无法安装 $cmd，请手动安装后重试"
                    fi
                    ;;
                yum)
                    if ! yum install -y -q "$cmd" 2>/dev/null; then
                        error "无法安装 $cmd，请手动安装后重试"
                    fi
                    ;;
                *)
                    error "$cmd 未安装，且无法自动安装"
                    ;;
            esac
        fi
    done
    
    if ! command -v systemctl >/dev/null 2>&1; then
        error "systemctl 不可用，此脚本仅支持 systemd 系统"
    fi
    
    info "依赖检查完成"
}

# 停止并移除旧服务
stop_old_service() {
    step "检查并停止旧服务..."
    
    if systemctl is-active --quiet ${SERVICE_NAME}.service 2>/dev/null; then
        warn "发现正在运行的服务，正在停止..."
        systemctl stop ${SERVICE_NAME}.service 2>/dev/null || true
        systemctl disable ${SERVICE_NAME}.service 2>/dev/null || true
        info "旧服务已停止"
    fi
    
    # 强制杀掉可能残留的进程
    if pgrep -f cf-probe.sh >/dev/null 2>&1; then
        warn "发现残留进程，正在清理..."
        pkill -f cf-probe.sh 2>/dev/null || true
        sleep 1
        info "残留进程已清理"
    fi
}

# 获取 Worker URL
get_worker_url() {
    # 从 install.sh 的请求来源自动获取
    WORKER_URL=$(curl -s https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip=" && echo "detected" || echo "")
    
    # 这里需要用户提供完整 URL
    if [ -z "$WORKER_HOST" ]; then
        error "缺少 Worker URL，请通过环境变量或参数提供"
    fi
    
    echo "${WORKER_HOST}/update"
}

# 创建探针脚本
create_script() {
    local REPORT_INTERVAL=${1:-60}
    
    step "创建探针采集脚本..."
    
    cat > ${SCRIPT_FILE} << 'PROBE_EOF'
#!/bin/bash
# =============================================
# CF-Server-Monitor-Pro 探针采集脚本
# =============================================

SERVER_ID="$1"
SECRET="$2"
WORKER_URL="$3"
REPORT_INTERVAL="${REPORT_INTERVAL:-60}"

# 日志函数 - 增强版，支持 fallback
log() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -w "/var/log/cf-probe.log" ] || [ -w "/var/log" ]; then
        echo "[$timestamp] $msg" >> /var/log/cf-probe.log 2>/dev/null || \
            logger -t cf-probe "$msg" || \
            echo "[$timestamp] $msg" >&2
    else
        logger -t cf-probe "$msg" 2>/dev/null || \
            echo "[$timestamp] $msg" >&2
    fi
}

# 安全除法函数
safe_div() {
    local numerator=$1
    local denominator=$2
    local default=${3:-0}
    
    if [ "$denominator" -eq 0 ]; then
        echo "$default"
    else
        echo $((numerator / denominator))
    fi
}

# 安全浮点除法函数
safe_div_float() {
    awk -v n="$1" -v d="$2" -v def="$3" '
        BEGIN {
            if (d == 0) {
                print def
            } else {
                printf "%.2f", n / d
            }
        }
    '
}

# 获取网络流量
get_net_bytes() { 
    awk 'NR>2 {rx+=$2; tx+=$10} END {printf "%.0f %.0f", rx, tx}' /proc/net/dev 2>/dev/null || echo "0 0"
}

# 获取 CPU 统计
get_cpu_stat() { 
    awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat 2>/dev/null || echo "0 0"
}

# curl 封装函数
do_curl() {
    local url="$1"
    local timeout="${2:-3}"
    local connect_timeout="${3:-2}"
    
    curl -s -m "$timeout" --connect-timeout "$connect_timeout" "$url" 2>/dev/null
}

# 延迟测试节点
CT_NODES=("bj-ct-dualstack.ip.zstaticcdn.com" "sh-ct-dualstack.ip.zstaticcdn.com" "gd-ct-dualstack.ip.zstaticcdn.com")
CU_NODES=("bj-cu-dualstack.ip.zstaticcdn.com" "sh-cu-dualstack.ip.zstaticcdn.com" "gd-cu-dualstack.ip.zstaticcdn.com")
CM_NODES=("bj-cm-dualstack.ip.zstaticcdn.com" "sh-cm-dualstack.ip.zstaticcdn.com" "gd-cm-dualstack.ip.zstaticcdn.com")

# 缓存数组长度
CT_LEN=${#CT_NODES[@]}
CU_LEN=${#CU_NODES[@]}
CM_LEN=${#CM_NODES[@]}

get_http_ping() { 
    local target="$1"
    local rtt=$(curl -o /dev/null -s -m 2 -w "%{time_total}" "http://$target" 2>/dev/null | awk '{printf "%.0f", $1*1000}')
    echo "${rtt:-0}"
}

# 初始化
NET_STAT=$(get_net_bytes)
RX_PREV=$(echo "$NET_STAT" | awk '{print $1}')
TX_PREV=$(echo "$NET_STAT" | awk '{print $2}')
[ -z "$RX_PREV" ] && RX_PREV=0
[ -z "$TX_PREV" ] && TX_PREV=0

CPU_STAT=$(get_cpu_stat)
PREV_CPU_TOTAL=$(echo "$CPU_STAT" | awk '{print $1}')
PREV_CPU_IDLE=$(echo "$CPU_STAT" | awk '{print $2}')

IPV4="0"; IPV6="0"
PING_CT="0"; PING_CU="0"; PING_CM="0"; PING_BD="0"
ERROR_COUNT=0

# 基于时间戳的定时检测
LAST_IP_CHECK=0
LAST_PING_CHECK=0
IP_CHECK_INTERVAL=600
PING_CHECK_INTERVAL=30

log "探针启动 - 服务器ID: $SERVER_ID, 上报间隔: $REPORT_INTERVAL秒"

while true; do
    CURRENT_TIME=$(date +%s)
    
    # 每600秒(10分钟)检测一次IP - 使用时间戳判断
    if [ $((CURRENT_TIME - LAST_IP_CHECK)) -ge "$IP_CHECK_INTERVAL" ] || [ "$LAST_IP_CHECK" -eq 0 ]; then
        if do_curl "https://cloudflare.com/cdn-cgi/trace" 3 2 | grep -q "ip="; then
            IPV4="1"
        else
            IPV4="0"
        fi
        
        if curl -6 -s -m 3 --connect-timeout 2 "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null | grep -q "ip="; then
            IPV6="1"
        else
            IPV6="0"
        fi
        LAST_IP_CHECK="$CURRENT_TIME"
    fi
    
    # 每30秒测一次延迟 - 使用时间戳判断
    if [ $((CURRENT_TIME - LAST_PING_CHECK)) -ge "$PING_CHECK_INTERVAL" ] || [ "$LAST_PING_CHECK" -eq 0 ]; then
        PING_CT=$(get_http_ping "${CT_NODES[$((RANDOM % CT_LEN))]}")
        PING_CU=$(get_http_ping "${CU_NODES[$((RANDOM % CU_LEN))]}")
        PING_CM=$(get_http_ping "${CM_NODES[$((RANDOM % CM_LEN))]}")
        PING_BD=$(get_http_ping "lf3-ips.zstaticcdn.com")
        LAST_PING_CHECK="$CURRENT_TIME"
    fi

    # 系统信息
    OS=$(awk -F= '/^PRETTY_NAME/{print $2}' /etc/os-release 2>/dev/null | tr -d '"')
    [ -z "$OS" ] && OS=$(uname -srm)
    ARCH=$(uname -m)
    BOOT_TIME=$(uptime -s 2>/dev/null || stat -c %y / 2>/dev/null | cut -d'.' -f1 || echo "Unknown")
    CPU_INFO=$(grep -m 1 'model name' /proc/cpuinfo 2>/dev/null | awk -F: '{print $2}' | xargs | tr -d '"')
    [ -z "$CPU_INFO" ] && CPU_INFO=$(uname -m)
    
    # CPU - 增强除零保护
    CPU_STAT=$(get_cpu_stat)
    CPU_TOTAL=$(echo "$CPU_STAT" | awk '{print $1}')
    CPU_IDLE=$(echo "$CPU_STAT" | awk '{print $2}')
    DIFF_TOTAL=$((CPU_TOTAL - PREV_CPU_TOTAL))
    DIFF_IDLE=$((CPU_IDLE - PREV_CPU_IDLE))
    
    if [ "$DIFF_TOTAL" -le 0 ] || [ "$CPU_TOTAL" -eq 0 ]; then
        CPU="0.00"
    else
        if [ "$DIFF_IDLE" -lt 0 ]; then
            DIFF_IDLE=0
        fi
        CPU=$(awk -v t="$DIFF_TOTAL" -v i="$DIFF_IDLE" '
            BEGIN {
                pct = (1 - i/t) * 100
                if (pct < 0) pct = 0
                if (pct > 100) pct = 100
                printf "%.2f", pct
            }
        ')
    fi
    
    PREV_CPU_TOTAL=$CPU_TOTAL
    PREV_CPU_IDLE=$CPU_IDLE
    
    # 内存
    MEM_INFO=$(free -m 2>/dev/null || echo "0 0 0 0 0 0")
    RAM_TOTAL=$(echo "$MEM_INFO" | awk '/Mem:/ {print $2}')
    RAM_USED=$(echo "$MEM_INFO" | awk '/Mem:/ {print $3}')
    [ -z "$RAM_TOTAL" ] && RAM_TOTAL=0
    [ -z "$RAM_USED" ] && RAM_USED=0
    
    if [ "$RAM_TOTAL" -gt 0 ]; then
        RAM=$(awk -v used="$RAM_USED" -v total="$RAM_TOTAL" '
            BEGIN {
                if (total <= 0) {
                    print "0.00"
                } else {
                    pct = (used / total) * 100
                    if (pct > 100) pct = 100
                    if (pct < 0) pct = 0
                    printf "%.2f", pct
                }
            }
        ')
    else
        RAM="0.00"
    fi
    
    SWAP_TOTAL=$(echo "$MEM_INFO" | awk '/Swap:/ {print $2}')
    SWAP_USED=$(echo "$MEM_INFO" | awk '/Swap:/ {print $3}')
    [ -z "$SWAP_TOTAL" ] && SWAP_TOTAL=0
    [ -z "$SWAP_USED" ] && SWAP_USED=0

    # 磁盘
    DISK_INFO=$(df -hm / 2>/dev/null | tail -n1 | awk '{print $2, $3, $5}')
    DISK_TOTAL=$(echo "$DISK_INFO" | awk '{print $1}')
    DISK_USED=$(echo "$DISK_INFO" | awk '{print $2}')
    DISK=$(echo "$DISK_INFO" | awk '{print $3}' | tr -d '%')
    [ -z "$DISK_TOTAL" ] && DISK_TOTAL=0
    [ -z "$DISK_USED" ] && DISK_USED=0
    [ -z "$DISK" ] && DISK=0

    LOAD=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "0 0 0")
    UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || echo "Unknown")
    PROCESSES=$(ps -e 2>/dev/null | wc -l || echo 0)
    TCP_CONN=$(ss -ant 2>/dev/null | grep -c -v State || netstat -ant 2>/dev/null | grep -c -v Active || echo 0)
    UDP_CONN=$(ss -anu 2>/dev/null | grep -c -v State || netstat -anu 2>/dev/null | grep -c -v Active || echo 0)
    
    # 网络速度 - 增强稳定性，防止负值和异常跳变
    NET_STAT=$(get_net_bytes)
    RX_NOW=$(echo "$NET_STAT" | awk '{print $1}')
    TX_NOW=$(echo "$NET_STAT" | awk '{print $2}')
    [ -z "$RX_NOW" ] && RX_NOW=0
    [ -z "$TX_NOW" ] && TX_NOW=0

    # 计算速度，防止负值和除零
    RX_DELTA=$((RX_NOW - RX_PREV))
    TX_DELTA=$((TX_NOW - TX_PREV))
    
    [ "$RX_DELTA" -lt 0 ] && RX_DELTA=0
    [ "$TX_DELTA" -lt 0 ] && TX_DELTA=0
    
    RX_SPEED=$(safe_div "$RX_DELTA" "$REPORT_INTERVAL" "0")
    TX_SPEED=$(safe_div "$TX_DELTA" "$REPORT_INTERVAL" "0")
    
    RX_PREV=$RX_NOW
    TX_PREV=$TX_NOW
    
    # 上报数据
    PAYLOAD=$(cat <<EOF
{"id":"$SERVER_ID","secret":"$SECRET","metrics":{"cpu":"$CPU","ram":"$RAM","ram_total":"$RAM_TOTAL","ram_used":"$RAM_USED","swap_total":"$SWAP_TOTAL","swap_used":"$SWAP_USED","disk":"$DISK","disk_total":"$DISK_TOTAL","disk_used":"$DISK_USED","load":"$LOAD","uptime":"$UPTIME","boot_time":"$BOOT_TIME","net_rx":"$RX_NOW","net_tx":"$TX_NOW","net_in_speed":"$RX_SPEED","net_out_speed":"$TX_SPEED","os":"$OS","arch":"$ARCH","cpu_info":"$CPU_INFO","processes":"$PROCESSES","tcp_conn":"$TCP_CONN","udp_conn":"$UDP_CONN","ip_v4":"$IPV4","ip_v6":"$IPV6","ping_ct":"$PING_CT","ping_cu":"$PING_CU","ping_cm":"$PING_CM","ping_bd":"$PING_BD"}}
EOF
)
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "$WORKER_URL" 2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" = "200" ]; then
        ERROR_COUNT=0
    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
        if [ "$ERROR_COUNT" -ge 10 ]; then
            log "连续上报失败，尝试恢复..."
            IPV4="0"
            IPV6="0"
            ERROR_COUNT=0
        fi
    fi
    
    sleep "$REPORT_INTERVAL"
done
PROBE_EOF

    chmod +x "${SCRIPT_FILE}"
    info "探针脚本已创建: ${SCRIPT_FILE}"
}

# 创建 systemd 服务
create_service() {
    step "创建 systemd 服务..."
    
    local escaped_server_id=$(printf '%s' "$SERVER_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local escaped_secret=$(printf '%s' "$SECRET" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local escaped_worker_url=$(printf '%s' "$WORKER_URL" | sed 's/\\/\\\\/g; s/"/\\"/g')
    
    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=CF Server Monitor Probe Agent
Documentation=https://github.com/your-repo/CF-Server-Monitor-Pro
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="REPORT_INTERVAL=${REPORT_INTERVAL}"
ExecStart=/bin/bash "${SCRIPT_FILE}" "${escaped_server_id}" "${escaped_secret}" "${escaped_worker_url}"
Restart=always
RestartSec=10
User=root
Group=root
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    info "服务文件已创建: ${SERVICE_FILE}"
}

# 启动服务
start_service() {
    step "启动探针服务..."
    
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}.service 2>/dev/null || true
    systemctl restart ${SERVICE_NAME}.service 2>/dev/null || systemctl start ${SERVICE_NAME}.service
    
    sleep 2
    
    if systemctl is-active --quiet ${SERVICE_NAME}.service; then
        info "探针服务已成功启动"
    else
        error "服务启动失败，请检查日志: journalctl -u ${SERVICE_NAME} -n 20"
    fi
}

# =============================================
# 安装功能
# =============================================
install_probe() {
    SERVER_ID=$1
    SECRET=$2
    WORKER_URL=$3
    REPORT_INTERVAL=${4:-60}

    if [ -z "$SERVER_ID" ] || [ -z "$SECRET" ] || [ -z "$WORKER_URL" ]; then
        echo ""
        echo -e "${RED}错误: 缺少必要参数${NC}"
        echo ""
        echo "用法:"
        echo "  安装: bash $0 install <SERVER_ID> <SECRET> <WORKER_URL> [REPORT_INTERVAL]"
        echo "  卸载: bash $0 uninstall"
        echo ""
        echo "参数说明:"
        echo "  SERVER_ID      - 服务器唯一标识"
        echo "  SECRET         - 认证密钥"
        echo "  WORKER_URL     - 上报地址"
        echo "  REPORT_INTERVAL - 上报间隔(秒)，默认60秒"
        echo ""
        echo "示例:"
        echo "  bash $0 install abc-123-def my-secret https://your-worker.workers.dev/update"
        echo "  bash $0 install abc-123-def my-secret https://your-worker.workers.dev/update 30"
        echo ""
        exit 1
    fi

    print_banner
    echo ""
    echo -e "${CYAN}开始安装 CF-Server-Monitor-Pro 探针...${NC}"
    echo ""
    echo -e "  服务器 ID   : ${YELLOW}$SERVER_ID${NC}"
    echo -e "  上报地址    : ${YELLOW}$WORKER_URL${NC}"
    echo -e "  上报间隔    : ${YELLOW}$REPORT_INTERVAL秒${NC}"
    echo -e "  系统类型    : ${YELLOW}$(uname -srm)${NC}"
    echo ""

    check_root
    detect_os
    install_deps
    stop_old_service
    create_script "$REPORT_INTERVAL"
    create_service
    start_service

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ✅ 探针安装成功！                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}服务状态:${NC} ${GREEN}运行中 ✓${NC}"
    echo ""
    echo -e "  ${CYAN}管理命令:${NC}"
    echo -e "    systemctl status ${SERVICE_NAME}   # 查看状态"
    echo -e "    systemctl restart ${SERVICE_NAME}  # 重启服务"
    echo -e "    systemctl stop ${SERVICE_NAME}     # 停止服务"
    echo -e "    journalctl -u ${SERVICE_NAME} -f  # 实时日志"
    echo ""
    echo -e "  ${CYAN}卸载命令:${NC}"
    echo -e "    bash $0 uninstall"
    echo ""
}

# =============================================
# 卸载功能
# =============================================
uninstall_probe() {
    print_banner
    echo ""
    echo -e "${YELLOW}开始卸载 CF-Server-Monitor-Pro 探针...${NC}"
    echo ""

    check_root

    step "停止探针服务..."
    if systemctl is-active --quiet ${SERVICE_NAME}.service 2>/dev/null; then
        systemctl stop ${SERVICE_NAME}.service 2>/dev/null || true
        info "服务已停止"
    else
        info "服务未运行"
    fi

    step "禁用开机自启..."
    if systemctl is-enabled --quiet ${SERVICE_NAME}.service 2>/dev/null; then
        systemctl disable ${SERVICE_NAME}.service 2>/dev/null || true
        info "已禁用开机自启"
    fi

    step "删除服务文件..."
    if [ -f "${SERVICE_FILE}" ]; then
        rm -f ${SERVICE_FILE}
        systemctl daemon-reload 2>/dev/null || true
        info "已删除: ${SERVICE_FILE}"
    fi

    step "删除探针脚本..."
    if [ -f "${SCRIPT_FILE}" ]; then
        rm -f ${SCRIPT_FILE}
        info "已删除: ${SCRIPT_FILE}"
    fi

    step "清理运行中的进程..."
    if pgrep -f cf-probe.sh >/dev/null 2>&1; then
        pkill -9 -f cf-probe.sh 2>/dev/null || true
        sleep 1
        info "进程已清理"
    fi

    step "清理日志文件..."
    rm -f ${LOG_FILE}

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ✅ 卸载完成！                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

# =============================================
# 状态检查
# =============================================
check_status() {
    print_banner
    echo ""
    
    if systemctl is-active --quiet ${SERVICE_NAME}.service 2>/dev/null; then
        echo -e "  服务状态 : ${GREEN}运行中 ✓${NC}"
        ACTIVE_SINCE=$(systemctl show ${SERVICE_NAME}.service -p ActiveEnterTimestamp --value 2>/dev/null || echo "Unknown")
        echo -e "  启动时间 : ${CYAN}$ACTIVE_SINCE${NC}"
        
        PID=$(pgrep -f cf-probe.sh | head -1)
        if [ -n "$PID" ]; then
            echo -e "  进程 PID : ${CYAN}$PID${NC}"
        fi
    else
        echo -e "  服务状态 : ${RED}未运行 ✗${NC}"
    fi
    
    echo ""
    echo -e "  ${CYAN}文件检查:${NC}"
    [ -f "${SCRIPT_FILE}" ] && echo -e "    探针脚本 : ${GREEN}存在${NC}" || echo -e "    探针脚本 : ${RED}不存在${NC}"
    [ -f "${SERVICE_FILE}" ] && echo -e "    服务文件 : ${GREEN}存在${NC}" || echo -e "    服务文件 : ${RED}不存在${NC}"
    echo ""
}

# =============================================
# 主入口
# =============================================
case "${1:-install}" in
    install|"")
        shift 2>/dev/null || true
        install_probe "$@"
        ;;
    uninstall|remove|delete|purge)
        uninstall_probe
        ;;
    status|info|check)
        check_status
        ;;
    help|-h|--help)
        print_banner
        echo ""
        echo "用法:"
        echo "  bash $0 [命令] [参数]"
        echo ""
        echo "命令:"
        echo "  install <ID> <SECRET> <WORKER_URL> [REPORT_INTERVAL]   安装探针"
        echo "  uninstall                                              卸载探针"
        echo "  status                                                 查看状态"
        echo "  help                                                   显示帮助"
        echo ""
        echo "参数说明:"
        echo "  ID              - 服务器唯一标识"
        echo "  SECRET          - 认证密钥"
        echo "  WORKER_URL      - 上报地址"
        echo "  REPORT_INTERVAL - 上报间隔(秒)，默认60秒"
        echo ""
        echo "示例:"
        echo "  bash $0 install abc-123 my-secret https://example.workers.dev/update"
        echo "  bash $0 install abc-123 my-secret https://example.workers.dev/update 30"
        echo "  bash $0 uninstall"
        echo ""
        ;;
    *)
        echo -e "${RED}未知命令: $1${NC}"
        echo "使用 'bash $0 help' 查看帮助"
        exit 1
        ;;
esac