#!/bin/bash

# Reality 协议一键安装脚本 (Xray VLESS + Reality)
# 默认配置: SNI=www.notion.so, 端口=443, 指纹=chrome

set -euo pipefail

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# --- 路径配置 ---
XRAY_DIR="/usr/local/bin"
XRAY_BIN="${XRAY_DIR}/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
INFO_FILE="${XRAY_CONFIG_DIR}/.reality_info"

# --- 默认值 ---
DEFAULT_PORT=443
DEFAULT_SNI="www.notion.so"
DEFAULT_FINGERPRINT="chrome"

# --- 生成高强度随机字符串 ---
gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || \
        openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'
    fi
}

gen_hex() {
    local len=$1
    openssl rand -hex "$len"
}

# --- 获取公网 IP ---
get_ips() {
    SERVER_IP4=$(curl -4s --max-time 5 https://api.ipify.org 2>/dev/null || curl -4s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*')
    SERVER_IP6=$(curl -6s --max-time 5 https://api6.ipify.org 2>/dev/null || curl -6s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*')
}

# --- 检查 root ---
[ "$(id -u)" -ne 0 ] && error "请使用 root 用户运行此脚本"

# --- 检测系统架构 ---
case "$(uname -m)" in
    x86_64)  ARCH="64" ;;
    aarch64|arm64) ARCH="arm64-v8a" ;;
    armv7l)  ARCH="armv7a" ;;
    *)       error "不支持的架构: $(uname -m)" ;;
esac

# --- 安装依赖 ---
info "安装依赖..."
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq curl wget openssl qrencode >/dev/null 2>&1 || error "依赖安装失败"

# --- 安装 Xray ---
install_xray() {
    if [ -f "$XRAY_BIN" ]; then
        info "检测到已安装 Xray，跳过下载"
        return 0
    fi

    info "正在下载安装 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || error "Xray 安装失败"
}

# --- 获取或读取配置 ---
load_or_gen_config() {
    if [ -f "$INFO_FILE" ]; then
        info "检测到已有配置文件"
        source "$INFO_FILE"
    fi

    # 如没有则生成默认值
    [ -z "${REALITY_PORT:-}" ] && REALITY_PORT=$DEFAULT_PORT
    [ -z "${REALITY_SNI:-}" ]  && REALITY_SNI=$DEFAULT_SNI
    [ -z "${REALITY_FINGERPRINT:-}" ] && REALITY_FINGERPRINT=$DEFAULT_FINGERPRINT
    [ -z "${REALITY_UUID:-}" ] && REALITY_UUID=$(gen_uuid)
    [ -z "${REALITY_SHORT_ID:-}" ] && REALITY_SHORT_ID=$(gen_hex 8)

    # 生成密钥对
    if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
        local keypair
        keypair=$($XRAY_BIN x25519 2>/dev/null) || error "生成 X25519 密钥对失败"
        REALITY_PRIVATE_KEY=$(echo "$keypair" | awk '/Private/ {print $3}')
        REALITY_PUBLIC_KEY=$(echo "$keypair" | awk '/Public/ {print $3}')
    fi
}

# --- 交互式配置 ---
configure() {
    echo
    echo -e "${CYAN}${BOLD}==== Reality 配置 ====${NC}"
    echo

    read -rp "请输入监听端口 [默认: $REALITY_PORT]: " input_port
    [ -n "$input_port" ] && REALITY_PORT=$input_port

    read -rp "请输入 SNI (伪装域名) [默认: $REALITY_SNI]: " input_sni
    [ -n "$input_sni" ] && REALITY_SNI=$input_sni

    read -rp "请输入浏览器指纹 [默认: $REALITY_FINGERPRINT]: " input_fp
    [ -n "$input_fp" ] && REALITY_FINGERPRINT=$input_fp

    read -rp "请输入 UUID [默认随机生成]: " input_uuid
    [ -n "$input_uuid" ] && REALITY_UUID=$input_uuid

    read -rp "请输入 Short ID [默认随机生成]: " input_sid
    [ -n "$input_sid" ] && REALITY_SHORT_ID=$input_sid

    read -rp "请输入私钥 (留空随机生成): " input_priv
    if [ -n "$input_priv" ]; then
        REALITY_PRIVATE_KEY=$input_priv
        read -rp "请输入与私钥对应的公钥: " REALITY_PUBLIC_KEY
    fi
}

# --- 写入 Xray 配置 ---
write_config() {
    mkdir -p "$XRAY_CONFIG_DIR"

    cat > "$XRAY_CONFIG_FILE" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": ${REALITY_PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${REALITY_UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${REALITY_SNI}:443",
                    "xver": 0,
                    "serverNames": [
                        "${REALITY_SNI}"
                    ],
                    "privateKey": "${REALITY_PRIVATE_KEY}",
                    "shortIds": [
                        "${REALITY_SHORT_ID}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOF

    # 保存配置信息
    cat > "$INFO_FILE" <<EOF
REALITY_PORT=${REALITY_PORT}
REALITY_SNI=${REALITY_SNI}
REALITY_FINGERPRINT=${REALITY_FINGERPRINT}
REALITY_UUID=${REALITY_UUID}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
EOF
    chmod 600 "$INFO_FILE"

    # 创建/更新 systemd 服务
    if [ ! -f "$XRAY_SERVICE_FILE" ]; then
        cat > "$XRAY_SERVICE_FILE" <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    fi
}

# --- 启动服务 ---
start_service() {
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1
    if systemctl is-active xray >/dev/null 2>&1; then
        success "Xray 服务启动成功"
    else
        error "Xray 服务启动失败，请运行 journalctl -u xray -xe 查看日志"
    fi
}

# --- 输出客户端信息 ---
print_client_info() {
    local host="${SERVER_IP4:-${SERVER_IP6:-服务器IP}}"
    [ -n "$SERVER_IP6" ] && host="${SERVER_IP4:-[$SERVER_IP6]}"

    # VLESS 分享链接
    local vless_link="vless://${REALITY_UUID}@${host}:${REALITY_PORT}?security=reality&sni=${REALITY_SNI}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision&encryption=none#Reality-${host}"

    echo
    echo -e "${GREEN}${BOLD}========== Reality 安装完成 ==========${NC}"
    echo
    echo -e "${CYAN}服务器地址:${NC} ${host}"
    echo -e "${CYAN}端口:${NC}       ${REALITY_PORT}"
    echo -e "${CYAN}UUID:${NC}       ${REALITY_UUID}"
    echo -e "${CYAN}传输协议:${NC}   tcp"
    echo -e "${CYAN}流控:${NC}       xtls-rprx-vision"
    echo -e "${CYAN}安全类型:${NC}   reality"
    echo -e "${CYAN}SNI:${NC}        ${REALITY_SNI}"
    echo -e "${CYAN}指纹:${NC}       ${REALITY_FINGERPRINT}"
    echo -e "${CYAN}公钥 (pbk):${NC} ${REALITY_PUBLIC_KEY}"
    echo -e "${CYAN}Short ID:${NC}   ${REALITY_SHORT_ID}"
    echo
    echo -e "${YELLOW}VLESS 链接:${NC}"
    echo -e "${vless_link}"
    echo
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${YELLOW}二维码:${NC}"
        echo "$vless_link" | qrencode -t ANSIUTF8
    fi
    echo
    echo -e "${GREEN}配置信息已保存到: ${INFO_FILE}${NC}"
    echo -e "${GREEN}Xray 配置文件: ${XRAY_CONFIG_FILE}${NC}"
    echo
}

# --- 主流程 ---
main() {
    echo -e "${CYAN}${BOLD}Reality 协议一键安装脚本${NC}"
    echo

    get_ips
    install_xray
    load_or_gen_config

    if [ "$#" -ge 1 ] && [ "$1" == "--auto" ]; then
        info "使用默认/已保存配置自动安装"
    else
        configure
    fi

    write_config
    start_service
    print_client_info
}

main "$@"
