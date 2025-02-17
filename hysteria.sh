#!/bin/bash
set -e
# 可选：启用调试模式：set -x

# 定义颜色和全局配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

HYSTERIA_ROOT="/etc/hysteria"
HYSTERIA_CONFIG="$HYSTERIA_ROOT/config.yaml"
SERVICE_FILE="/etc/systemd/system/hysteria.service"
CLIENT_SERVICE_FILE="/etc/systemd/system/clients.service"
CLIENT_DIR="$HYSTERIA_ROOT/clients"
LOG_FILE="/var/log/hysteria.log"
CLIENT_CONFIG_DIR="/root/H2"

# MODE 全局变量：all 表示同时安装生成两个服务
MODE="all"

#########################################
# 基础功能函数
#########################################

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行本脚本${NC}"
        exit 1
    fi
}

check_system() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}未找到 /etc/os-release 文件，无法检测系统信息！${NC}"
        exit 1
    fi
    source /etc/os-release
    echo -e "${YELLOW}检测到操作系统：$ID $VERSION_ID${NC}"
    if [[ ! "$ID" =~ ^(ubuntu|debian|centos)$ ]]; then
        echo -e "${RED}不支持的操作系统: $ID${NC}"
        exit 1
    fi
}

init_environment() {
    echo -e "${YELLOW}[1/7] 正在初始化环境...${NC}"
    check_root
    check_system
    mkdir -p "$HYSTERIA_ROOT" "$CLIENT_DIR" "$CLIENT_CONFIG_DIR"
    echo -e "${GREEN}[1/7] 环境目录创建完成！${NC}"
    echo -e "${GREEN}[1/7] 环境初始化完成！${NC}"
}

install_dependencies() {
    echo -e "${YELLOW}[2/7] 正在安装系统依赖...${NC}"
    if [[ "$ID" == "centos" ]]; then
        yum install -y wget curl tar jq qrencode > /dev/null 2>&1
    else
        apt update > /dev/null 2>&1
        apt install -y wget curl tar jq qrencode > /dev/null 2>&1
    fi
    echo -e "${GREEN}[2/7] 系统依赖安装完成！${NC}"
}

install_hysteria() {
    echo -e "${YELLOW}[3/7] 正在安装 Hysteria...${NC}"
    LATEST_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    BIN_URL="https://github.com/apernet/hysteria/releases/download/$LATEST_VER/hysteria-linux-$ARCH"
    
    wget -qO /usr/local/bin/hysteria "$BIN_URL"
    chmod +x /usr/local/bin/hysteria
    echo -e "${GREEN}[3/7] Hysteria 安装完成！${NC}"
}

prompt_config() {
    echo -e "${YELLOW}[4/7] 请输入配置（直接回车使用默认值）${NC}"
    read -p "监听端口 (默认: 443): " PORT
    PORT=${PORT:-443}

    read -p "认证密码 (默认: 随机生成): " PASSWORD
    PASSWORD=${PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}

    read -p "协议类型 (udp/wechat-video/faketcp, 默认: udp): " PROTOCOL
    PROTOCOL=${PROTOCOL:-udp}

    read -p "上行带宽 (默认: 200 mbps): " UP_BANDWIDTH
    UP_BANDWIDTH=${UP_BANDWIDTH:-200}
    UP_BANDWIDTH="${UP_BANDWIDTH} mbps"

    read -p "下行带宽 (默认: 200 mbps): " DOWN_BANDWIDTH
    DOWN_BANDWIDTH=${DOWN_BANDWIDTH:-200}
    DOWN_BANDWIDTH="${DOWN_BANDWIDTH} mbps"

    read -p "是否跳过TLS证书生成？(y/n, 默认: n): " SKIP_TLS
    SKIP_TLS=${SKIP_TLS:-n}
    if [[ "$SKIP_TLS" != "y" ]]; then
        read -p "TLS SNI (默认: www.google.com): " TLS_SNI
        TLS_SNI=${TLS_SNI:-www.google.com}
    fi

    read -p "QUIC接收窗口 (默认: 26843545): " QUIC_WINDOW
    QUIC_WINDOW=${QUIC_WINDOW:-26843545}

    read -p "是否启用快速打开 (y/n, 默认: y): " FAST_OPEN
    FAST_OPEN=${FAST_OPEN:-y}

    read -p "HTTP 监听端口 (默认: 8080): " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-8080}

    PUBLIC_IP=$(curl -s ifconfig.me)
    echo -e "${GREEN}[4/7] 配置输入完成！${NC}"
}

generate_config() {
    echo -e "${YELLOW}[5/7] 正在生成服务器配置文件...${NC}"

    # 如果没有跳过 TLS 配置，则生成证书
    if [[ "$SKIP_TLS" != "y" ]]; then
        if [ ! -f "$HYSTERIA_ROOT/server.crt" ]; then
            echo -e "${YELLOW}生成 TLS 证书...${NC}"
            openssl ecparam -genkey -name prime256v1 -out "$HYSTERIA_ROOT/server.key"
            openssl req -new -x509 -days 36500 -key "$HYSTERIA_ROOT/server.key" \
                -out "$HYSTERIA_ROOT/server.crt" -subj "/CN=$TLS_SNI"
        fi
        TLS_CONFIG="tls:
  cert: $HYSTERIA_ROOT/server.crt
  key: $HYSTERIA_ROOT/server.key"
    else
        TLS_CONFIG=""
    fi

    # 生成服务器的 config.yaml 配置
    cat > "$HYSTERIA_CONFIG" <<EOF
listen: :$PORT
protocol: $PROTOCOL
$TLS_CONFIG

auth:
  type: password
  password: $PASSWORD

bandwidth:
  up: $UP_BANDWIDTH
  down: $DOWN_BANDWIDTH

quic:
  initStreamReceiveWindow: $QUIC_WINDOW
  maxStreamReceiveWindow: $QUIC_WINDOW
  initConnReceiveWindow: $((QUIC_WINDOW * 2))
  maxConnReceiveWindow: $((QUIC_WINDOW * 2))

log:
  level: info
  timestamp: true
  output: $LOG_FILE

# 添加客户端配置文件路径
clientConfig: "$CLIENT_CONFIG_DIR/$HTTP_PORT.json"
EOF

    # 如果没有客户端配置文件，则生成客户端配置
    if [ ! -f "$CLIENT_CONFIG_DIR/$HTTP_PORT.json" ]; then
        generate_client_configs
    fi

    echo -e "${GREEN}[5/7] 服务器配置文件生成完成！${NC}"
}

generate_client_configs() {
    echo -e "${YELLOW}生成客户端配置...${NC}"

    # 提示用户输入 HTTP_PORT（端口号）
    read -p "请输入HTTP端口号（默认8080）： " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-8080}

    # 检查 /root/H2/ 目录下是否已存在该端口名的客户端配置文件，如果存在则删除旧文件
    if [ -f "$CLIENT_CONFIG_DIR/$HTTP_PORT.json" ]; then
        echo -e "${YELLOW}检测到旧的客户端配置，正在删除...${NC}"
        rm -f "$CLIENT_CONFIG_DIR/$HTTP_PORT.json"
    fi

    # 直接在 /root/H2/ 目录下生成新的客户端配置，文件名为端口号
    cat > "$CLIENT_CONFIG_DIR/$HTTP_PORT.json" <<EOF
{
    "server": "$PUBLIC_IP:$PORT",
    "auth": "$PASSWORD",
    "transport": {
        "type": "$PROTOCOL",
        "udp": {
            "hopInterval": "30s"
        }
    },
    "tls": {
        "insecure": true,
        "alpn": ["h3"]
    },
    "quic": {
        "initStreamReceiveWindow": $QUIC_WINDOW,
        "maxStreamReceiveWindow": $QUIC_WINDOW,
        "initConnReceiveWindow": $((QUIC_WINDOW * 2)),
        "maxConnReceiveWindow": $((QUIC_WINDOW * 2))
    },
    "bandwidth": {
        "up": "$UP_BANDWIDTH",
        "down": "$DOWN_BANDWIDTH"
    },
    "fastOpen": $([ "$FAST_OPEN" = "y" ] && echo true || echo false),
    "http": {
        "listen": "0.0.0.0:$HTTP_PORT"
    }
}
EOF

    echo -e "${GREEN}客户端配置已保存到 $CLIENT_CONFIG_DIR/$HTTP_PORT.json${NC}"

    # 更新 /etc/hysteria/config.yaml 配置文件，确保包含最新的客户端配置
    if [ -f "/etc/hysteria/config.yaml" ]; then
        echo -e "${YELLOW}正在更新服务端配置文件...${NC}"
        # 这里你可以用 sed 或 echo 命令插入客户端配置
        echo "客户端配置文件路径：$CLIENT_CONFIG_DIR/$HTTP_PORT.json" >> /etc/hysteria/config.yaml
        echo -e "${GREEN}服务端配置文件已更新。${NC}"
    else
        echo -e "${RED}/etc/hysteria/config.yaml 文件不存在，请检查路径。${NC}"
    fi
}

#########################################
# 创建 systemd 服务文件（同时生成服务器和客户端服务）
#########################################
create_service_files() {
    echo -e "${YELLOW}正在创建服务器模式 systemd 服务文件...${NC}"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria VPN Server Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/hysteria server -c $HYSTERIA_CONFIG
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hysteria-server

[Install]
WantedBy=multi-user.target
EOF
    echo -e "${GREEN}服务器模式服务文件创建完成！${NC}"

    echo -e "${YELLOW}正在创建客户端模式 systemd 服务文件...${NC}"
    cat > /etc/systemd/system/clients.service <<EOF
[Unit]
Description=Hysteria Client Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/hysteria -c ${CLIENT_CONFIG_DIR}/client.json
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hysteria-client

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria
    systemctl enable clients
    echo -e "${GREEN}客户端模式服务文件创建完成！${NC}"
}

#########################################
# 性能优化（默认启用 BBR 拥塞控制，只使用 UDP 模式）
#########################################
optimize_performance() {
    echo -e "${YELLOW}正在优化系统网络配置...${NC}"
    cat >> /etc/sysctl.conf <<EOF
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
EOF
    sysctl -p
    echo -e "${GREEN}✓ 系统网络配置优化完成${NC}"
}

#########################################
# 安装模式：安装后生成双服务文件
#########################################
install_mode() {
    echo -e "${YELLOW}开始安装【安装模式】...${NC}"
    init_environment
    install_dependencies
    install_hysteria
    prompt_config
    generate_config
    create_service_files
    optimize_performance
    echo -e "${GREEN}安装模式完成！请根据需要启动服务器或客户端服务。${NC}"
}

#########################################
# 服务器管理菜单
#########################################
server_menu() {
    while true; do
        clear
        echo -e "${GREEN}══════ 服务器模式管理 ══════${NC}"
        echo "1. 启动服务端"
        echo "2. 停止服务端"
        echo "3. 重启服务端"
        echo "4. 服务端状态"
        echo "5. 查看服务端日志"
        echo "6. 生成新服务端配置（客户端配置保存到 /root/H2）并显示配置供复制"
        echo "7. 全自动生成默认配置并保存到 /root/H2"
        echo "0. 返回主菜单"
        read -p "请选择: " s_choice
        case $s_choice in
            1)
                systemctl start hysteria && echo -e "${GREEN}服务器模式已启动${NC}" ;;
            2)
                systemctl stop hysteria && echo -e "${YELLOW}服务器模式已停止${NC}" ;;
            3)
                systemctl restart hysteria && echo -e "${GREEN}服务器模式已重启${NC}" ;;
            4)
                systemctl status hysteria --no-pager ;;
            5)
                tail -n 50 "$LOG_FILE" ;;
            6)
                prompt_config
                generate_config
                systemctl restart hysteria
                echo -e "${GREEN}新服务端配置已生成，客户端配置如下（请复制保存）：${NC}"
                cat "$CLIENT_CONFIG_DIR/client.json"
                ;;
            7)
                # 自动生成默认配置并保存到 /root/H2
                echo -e "${YELLOW}正在生成默认配置并保存到 /root/H2...${NC}"

                # 获取当前服务器的公网IP地址
                PUBLIC_IP=$(curl -s ifconfig.me)

                # 设置默认参数
                PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
                PROTOCOL="udp"
                UP_BANDWIDTH="200 mbps"
                DOWN_BANDWIDTH="200 mbps"
                QUIC_WINDOW="26843545"
                FAST_OPEN="y"
                TLS_SNI="www.google.com"
                PORT="443"  # 设置监听端口为 443

                # 提示用户输入 HTTP_PORT（端口号）
                read -p "请输入HTTP端口号（默认8080）： " HTTP_PORT
                # 如果用户没有输入端口号，则使用默认值 8080
                HTTP_PORT=${HTTP_PORT:-8080}

                # 删除旧的配置文件（如果存在）
                rm -f /root/H2/$HTTP_PORT.json

                # 生成默认配置文件
                generate_config

                echo -e "${GREEN}默认配置已生成并保存到 /root/H2/${HTTP_PORT}.json${NC}"

                ;;
            0) break ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
        read -p "按回车键继续..." dummy
    done
}

#########################################
# 客户端管理菜单
#########################################
client_menu() {
    while true; do
        clear
        echo -e "${GREEN}══════ 客户端模式管理 ══════${NC}"
        echo "1. 启动客户端"
        echo "2. 停止客户端"
        echo "3. 重启客户端"
        echo "4. 客户端状态"
        echo "5. 查看客户端日志"
        echo "0. 返回主菜单"
        read -p "请选择: " c_choice
        case $c_choice in
            1)
                systemctl start clients && echo -e "${GREEN}客户端模式已启动${NC}" ;;
            2)
                systemctl stop clients && echo -e "${YELLOW}客户端模式已停止${NC}" ;;
            3)
                systemctl restart clients && echo -e "${GREEN}客户端模式已重启${NC}" ;;
            4)
                systemctl status clients --no-pager ;;
            5)
                journalctl -u clients -n 50 ;;
            0) break ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
        read -p "按回车键继续..." dummy
    done
}

#########################################
# 完全卸载
#########################################
uninstall() {
    echo -e "${YELLOW}正在卸载 Hysteria...${NC}"
    systemctl stop hysteria 2>/dev/null
    systemctl disable hysteria 2>/dev/null
    systemctl stop clients 2>/dev/null
    systemctl disable clients 2>/dev/null
    rm -f "$SERVICE_FILE"
    rm -f "$CLIENT_SERVICE_FILE"
    rm -rf "$HYSTERIA_ROOT"
    rm -rf "$CLIENT_CONFIG_DIR"
    rm -f /usr/local/bin/hysteria
    echo -e "${GREEN}✓ Hysteria 已完全卸载${NC}"
}

#########################################
# 主菜单
#########################################
main_menu() {
    clear
    echo -e "${GREEN}══════ Hysteria 全能管理脚本 ── 主菜单 ══════${NC}"
    echo "1. 安装模式"
    echo "2. 服务器模式"
    echo "3. 客户端模式"
    echo "4. 完全卸载"
    echo "5. 退出脚本"
    read -p "请输入选项: " main_choice
    case $main_choice in
        1)
            install_mode ;;
        2)
            server_menu ;;
        3)
            client_menu ;;
        4)
            uninstall ;;
        5)
            exit 0 ;;
        *)
            echo -e "${RED}无效选项${NC}" ;;
    esac
}

#########################################
# 主程序入口（循环调用主菜单）
#########################################
while true; do
    main_menu
    read -p "按回车键继续..." dummy
done
