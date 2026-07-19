#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red()   { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

HY_CONFIG="/etc/hysteria/config.yaml"
CLIENT_DIR="/root/hysteria-client"
SELF_SIGNED_DIR="$HOME/.acme.sh/self-signed"

[[ $EUID -ne 0 ]] && red "注意: 请在root用户下运行脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)"
     "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
     "$(lsb_release -sd 2>/dev/null)"
     "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)"
     "$(grep . /etc/redhat-release 2>/dev/null)"
     "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
done

[[ -z $SYSTEM ]] && red "目前暂不支持你的VPS的操作系统！" && exit 1

# RHEL 系（CentOS/Rocky/AlmaLinux/Oracle/Fedora）与 Debian 系的差异统一在这里判断
is_rhel(){ [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" ]]; }

if [[ -z $(type -P curl) ]]; then
    if ! is_rhel; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl
fi

# 安装依赖：firewalld 作为统一的防火墙管理工具
# （firewalld 是 Rocky/RHEL 的默认防火墙，传统 iptables 服务已被官方弃用）
install_deps(){
    if is_rhel; then
        ${PACKAGE_INSTALL[int]} curl wget sudo openssl procps-ng firewalld
    else
        ${PACKAGE_UPDATE[int]}
        ${PACKAGE_INSTALL[int]} curl wget sudo openssl procps firewalld
    fi
    systemctl enable --now firewalld >/dev/null 2>&1
}

# firewalld 辅助函数：获取默认区域
fw_zone(){ firewall-cmd --get-default-zone 2>/dev/null; }

# 重新加载 firewalld，使 --permanent 规则生效
reload_firewall(){
    command -v firewall-cmd >/dev/null 2>&1 || return
    firewall-cmd --reload >/dev/null 2>&1
}

# 开放指定 UDP 端口（永久）
open_port(){
    local p=$1
    [[ -z $p ]] && return
    command -v firewall-cmd >/dev/null 2>&1 || return
    firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1
}

# 关闭指定 UDP 端口（永久）
close_port(){
    local p=$1
    [[ -z $p ]] && return
    command -v firewall-cmd >/dev/null 2>&1 || return
    firewall-cmd --permanent --remove-port="${p}/udp" >/dev/null 2>&1
}

# 添加端口跳跃转发规则：将 UDP 范围端口转发到本机主端口
add_forward_port(){
    local range=$1 toport=$2
    command -v firewall-cmd >/dev/null 2>&1 || return
    firewall-cmd --permanent --add-forward-port=port="${range}":proto=udp:toport="${toport}" >/dev/null 2>&1
}

# 清除本脚本添加的所有端口跳跃转发规则
clear_forward_ports(){
    local zone rule
    command -v firewall-cmd >/dev/null 2>&1 || return
    zone=$(fw_zone)
    [[ -z $zone ]] && return
    for rule in $(firewall-cmd --permanent --zone="$zone" --list-forward-ports 2>/dev/null); do
        firewall-cmd --permanent --zone="$zone" --remove-forward-port="$rule" >/dev/null 2>&1
    done
}

detect_real_ip(){
    local warpv4 warpv6
    warpv4=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    warpv6=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    if [[ $warpv4 =~ on|plus || $warpv6 =~ on|plus ]]; then
        wg-quick down wgcf >/dev/null 2>&1
        systemctl stop warp-go >/dev/null 2>&1
        ip=$(curl -s4m8 ip.sb -k) || ip=$(curl -s6m8 ip.sb -k)
        wg-quick up wgcf >/dev/null 2>&1
        systemctl start warp-go >/dev/null 2>&1
    else
        ip=$(curl -s4m8 ip.sb -k) || ip=$(curl -s6m8 ip.sb -k)
    fi
}

inst_cert(){
    green "Hysteria 2 协议证书申请方式如下："
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 必应自签证书 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} Acme 脚本自动申请"
    echo -e " ${GREEN}3.${PLAIN} 自定义证书路径"
    echo ""
    read -rp "请输入选项 [1-3]: " certInput
    if [[ $certInput == 2 ]]; then
        cert_mode="acme_sh"

        detect_real_ip

        read -rp "请输入需要申请证书的域名：" domain
        [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
        green "已输入的域名：$domain" && sleep 1

        domainIP=$(curl -s4m8 "https://dns.google/resolve?name=${domain}&type=A" | grep -oP '"data":"\K[^"]+' | head -1)
        if [[ -z $domainIP ]]; then
            domainIP=$(curl -s6m8 "https://dns.google/resolve?name=${domain}&type=AAAA" | grep -oP '"data":"\K[^"]+' | head -1)
        fi

        if [[ -z $domainIP ]]; then
            red "未解析出 IP，请检查域名是否输入有误"
            yellow "是否尝试强行继续？"
            echo -e " ${GREEN}1.${PLAIN} 是，强行继续申请"
            echo -e " ${GREEN}2.${PLAIN} 否，退出脚本"
            read -rp "请输入选项 [1-2]：" ipChoice
            [[ $ipChoice != 1 ]] && red "退出脚本" && exit 1
        elif [[ $domainIP != "$ip" ]]; then
            red "当前域名解析的 IP ($domainIP) 与本机 IP ($ip) 不匹配"
            yellow "建议如下："
            yellow "1. 请确保 CloudFlare 小云朵为关闭状态(仅限DNS)"
            yellow "2. 请检查 DNS 解析设置的 IP 是否为 VPS 的真实 IP"
            yellow "是否尝试强行继续？"
            echo -e " ${GREEN}1.${PLAIN} 是，强行继续申请"
            echo -e " ${GREEN}2.${PLAIN} 否，退出脚本"
            read -rp "请输入选项 [1-2]：" ipChoice
            [[ $ipChoice != 1 ]] && red "退出脚本" && exit 1
        fi

        ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl

        # 本地已存在 acme.sh 则直接复用，否则联网安装
        if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
            yellow "未检测到 acme.sh，开始安装……"
            curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
            source ~/.bashrc
        else
            green "检测到已安装的 acme.sh，跳过安装"
        fi

        if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
            red "acme.sh 安装失败，请检查网络后重试" && exit 1
        fi

        bash "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
        if echo "$ip" | grep -q ":"; then
            bash "$HOME/.acme.sh/acme.sh" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
        else
            bash "$HOME/.acme.sh/acme.sh" --issue -d "${domain}" --standalone -k ec-256 --insecure
        fi

        cert_path="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
        key_path="$HOME/.acme.sh/${domain}_ecc/${domain}.key"

        if [[ -f "$cert_path" && -f "$key_path" ]] && [[ -s "$cert_path" && -s "$key_path" ]]; then
            green "证书申请成功！"
            yellow "证书文件路径：$cert_path"
            yellow "私钥文件路径：$key_path"
            hy_domain="$domain"
        else
            red "证书申请失败，请检查域名解析及网络连接" && exit 1
        fi
    elif [[ $certInput == 3 ]]; then
        cert_mode="custom"
        read -rp "请输入公钥文件 crt 的路径：" cert_path
        yellow "公钥文件 crt 的路径：$cert_path"
        read -rp "请输入密钥文件 key 的路径：" key_path
        yellow "密钥文件 key 的路径：$key_path"
        read -rp "请输入证书的域名：" domain
        yellow "证书域名：$domain"
        hy_domain="$domain"
    else
        cert_mode="self-signed"
        green "将使用必应自签证书作为 Hysteria 2 的节点证书"

        mkdir -p "$SELF_SIGNED_DIR"
        cert_path="$SELF_SIGNED_DIR/cert.crt"
        key_path="$SELF_SIGNED_DIR/private.key"
        openssl ecparam -genkey -name prime256v1 -out "$key_path"
        openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
        chmod 644 "$cert_path"
        chmod 600 "$key_path"
        hy_domain="www.bing.com"
        domain="www.bing.com"

        green "自签证书已生成并保存到 $SELF_SIGNED_DIR"
    fi
}

inst_port(){
    clear_forward_ports

    read -rp "设置 Hysteria 2 端口 [1-65535]（回车则随机分配端口）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
        echo -e "${RED} $port ${PLAIN} 端口已经被其他程序占用，请更换端口重试！"
        read -rp "设置 Hysteria 2 端口 [1-65535]（回车则随机分配端口）：" port
        [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    done

    yellow "将在 Hysteria 2 节点使用的端口是：$port"
    open_port "$port"
    inst_jump
    reload_firewall
}

inst_jump(){
    green "Hysteria 2 端口使用模式如下："
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 单端口 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} 端口跳跃"
    echo ""
    read -rp "请输入选项 [1-2]: " jumpInput
    if [[ $jumpInput == 2 ]]; then
        read -rp "设置范围端口的起始端口 (建议10000-65535之间)：" firstport
        read -rp "设置范围端口的末尾端口 (建议10000-65535之间，一定要比起始端口大)：" endport
        while [[ $firstport -ge $endport ]]; do
            red "起始端口必须小于末尾端口，请重新输入"
            read -rp "设置范围端口的起始端口 (建议10000-65535之间)：" firstport
            read -rp "设置范围端口的末尾端口 (建议10000-65535之间，一定要比起始端口大)：" endport
        done
        add_forward_port "$firstport-$endport" "$port"
    else
        yellow "将继续使用单端口模式"
    fi
}

inst_pwd(){
    read -rp "设置 Hysteria 2 密码（回车跳过为随机字符）：" auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(date +%s%N | md5sum | cut -c 1-8)
    yellow "使用在 Hysteria 2 节点的密码为：$auth_pwd"
}

inst_site(){
    read -rp "请输入 Hysteria 2 的伪装网站地址 （去除https://） [回车世嘉maimai日本网站]：" proxysite
    [[ -z $proxysite ]] && proxysite="maimai.sega.jp"
    yellow "使用在 Hysteria 2 节点的伪装网站为：$proxysite"
}

inst_bandwidth(){
    read -rp "设置客户端上行速率（单位 mbps，回车默认 50）：" up_speed
    [[ -z $up_speed ]] && up_speed="50"
    [[ $up_speed =~ ^[0-9]+$ ]] && up_speed="$up_speed mbps"
    read -rp "设置客户端下行速率（单位 mbps，回车默认 100）：" down_speed
    [[ -z $down_speed ]] && down_speed="100"
    [[ $down_speed =~ ^[0-9]+$ ]] && down_speed="$down_speed mbps"
    yellow "客户端带宽：上行 $up_speed，下行 $down_speed"
}

generate_server_config(){
    mkdir -p /etc/hysteria

    cat << EOF > "$HY_CONFIG"
listen: :$port

tls:
  cert: $cert_path
  key: $key_path

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: $auth_pwd

outbounds:
  - name: default
    type: direct
    direct:
      mode: auto

masquerade:
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true
EOF
}

generate_client_configs(){
    local last_port last_ip insecure insecure_param

    if [[ -n $firstport ]]; then
        last_port="$port,$firstport-$endport"
    else
        last_port="$port"
    fi

    if echo "$ip" | grep -q ":"; then
        last_ip="[$ip]"
    else
        last_ip="$ip"
    fi

    insecure="false"
    insecure_param=0
    if [[ $cert_mode == "self-signed" ]]; then
        insecure="true"
        insecure_param=1
    fi

    mkdir -p "$CLIENT_DIR"

    cat << EOF > "$CLIENT_DIR/hy-client.yaml"
server: $last_ip:$last_port

auth: $auth_pwd

tls:
  sni: $hy_domain
  insecure: $insecure

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

bandwidth:
  up: $up_speed
  down: $down_speed

fastOpen: true

lazy: true

socks5:
  listen: 127.0.0.1:10808

http:
  listen: 127.0.0.1:10809

transport:
  udp:
    hopInterval: 30s
EOF

    cat << EOF > "$CLIENT_DIR/hy-client.json"
{
  "server": "$last_ip:$last_port",
  "auth": "$auth_pwd",
  "tls": {
    "sni": "$hy_domain",
    "insecure": $insecure
  },
  "quic": {
    "initStreamReceiveWindow": 16777216,
    "maxStreamReceiveWindow": 16777216,
    "initConnReceiveWindow": 33554432,
    "maxConnReceiveWindow": 33554432
  },
  "bandwidth": {
    "up": "$up_speed",
    "down": "$down_speed"
  },
  "fastOpen": true,
  "lazy": true,
  "socks5": {
    "listen": "127.0.0.1:10808"
  },
  "http": {
    "listen": "127.0.0.1:10809"
  },
  "transport": {
    "udp": {
      "hopInterval": "30s"
    }
  }
}
EOF

    local url nohopurl
    url="hysteria2://$auth_pwd@$last_ip:$last_port/?insecure=${insecure_param}&sni=$hy_domain#Hysteria2"
    echo "$url" > "$CLIENT_DIR/url.txt"
    nohopurl="hysteria2://$auth_pwd@$last_ip:$port/?insecure=${insecure_param}&sni=$hy_domain#Hysteria2"
    echo "$nohopurl" > "$CLIENT_DIR/url-nohop.txt"
}

insthysteria(){
    detect_real_ip

    install_deps

    wget -N https://raw.githubusercontent.com/mikeyshells/hysteria-install/master/install_server.sh
    bash install_server.sh
    rm -f install_server.sh

    if [[ -f "/usr/local/bin/hysteria" ]]; then
        green "Hysteria 2 安装成功！"
    else
        red "Hysteria 2 安装失败！"
        exit 1
    fi

    inst_cert
    inst_port
    inst_pwd
    inst_site
    inst_bandwidth

    generate_server_config
    generate_client_configs

    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl start hysteria-server

    if [[ -n $(systemctl status hysteria-server 2>/dev/null | grep -w active) && -f "$HY_CONFIG" ]]; then
        green "Hysteria 2 服务启动成功"
    else
        red "Hysteria 2 服务启动失败，请运行 systemctl status hysteria-server 查看服务状态并反馈，脚本退出" && exit 1
    fi

    showconf
}

unsthysteria(){
    local hyport
    [[ -f "$HY_CONFIG" ]] && hyport=$(grep '^listen:' "$HY_CONFIG" | awk -F: '{print $NF}')

    systemctl stop hysteria-server.service >/dev/null 2>&1
    systemctl disable hysteria-server.service >/dev/null 2>&1
    rm -f /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service
    rm -rf /usr/local/bin/hysteria /etc/hysteria "$SELF_SIGNED_DIR"
    clear_forward_ports
    close_port "$hyport"
    reload_firewall
    systemctl daemon-reload

    green "Hysteria 2 已彻底卸载完成！"
}

starthysteria(){
    systemctl start hysteria-server
    systemctl enable hysteria-server >/dev/null 2>&1
}

stophysteria(){
    systemctl stop hysteria-server
    systemctl disable hysteria-server >/dev/null 2>&1
}

hysteriaswitch(){
    yellow "请选择你需要的操作："
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 启动 Hysteria 2"
    echo -e " ${GREEN}2.${PLAIN} 关闭 Hysteria 2"
    echo -e " ${GREEN}3.${PLAIN} 重启 Hysteria 2"
    echo -e " ${GREEN}4.${PLAIN} 显示 Hysteria 2 服务状态"
    echo ""
    read -rp "请输入选项 [1-4]: " switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria ;;
        3 ) stophysteria && starthysteria ;;
        4 ) systemctl status hysteria-server ;;
        * ) exit 1 ;;
    esac
}

changeport(){
    local oldport
    oldport=$(grep '^listen:' "$HY_CONFIG" | awk -F: '{print $NF}')

    read -rp "设置 Hysteria 2 端口 [1-65535]（回车则随机分配端口）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)

    until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
        echo -e "${RED} $port ${PLAIN} 端口已经被其他程序占用，请更换端口重试！"
        read -rp "设置 Hysteria 2 端口 [1-65535]（回车则随机分配端口）：" port
        [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    done

    sed -i "s|^listen: :.*|listen: :$port|" "$HY_CONFIG"

    close_port "$oldport"
    open_port "$port"
    reload_firewall

    stophysteria && starthysteria

    green "Hysteria 2 端口已成功修改为：$port"
    yellow "请手动更新客户端配置文件以使用节点"
}

changepasswd(){
    read -rp "设置 Hysteria 2 密码（回车跳过为随机字符）：" passwd
    [[ -z $passwd ]] && passwd=$(date +%s%N | md5sum | cut -c 1-8)

    sed -i "/^auth:/,/^[^ ]/{s|^  password: .*|  password: $passwd|}" "$HY_CONFIG"

    stophysteria && starthysteria

    green "Hysteria 2 节点密码已成功修改为：$passwd"
    yellow "请手动更新客户端配置文件以使用节点"
}

change_cert(){
    local current_port current_pwd current_site
    current_port=$(grep '^listen:' "$HY_CONFIG" | awk -F: '{print $NF}')
    current_pwd=$(awk '/^auth:/{found=1} found && /password:/{print $2; exit}' "$HY_CONFIG")
    current_site=$(grep 'url: https://' "$HY_CONFIG" | sed 's|.*https://||')

    inst_cert

    port="$current_port"
    auth_pwd="$current_pwd"
    proxysite="$current_site"

    generate_server_config

    stophysteria && starthysteria

    green "Hysteria 2 节点证书类型已成功修改"
    yellow "请手动更新客户端配置文件以使用节点"
}

changeproxysite(){
    inst_site

    sed -i "s|url: https://.*|url: https://$proxysite|" "$HY_CONFIG"

    stophysteria && starthysteria

    green "Hysteria 2 节点伪装网站已成功修改为：$proxysite"
}

changeconf(){
    green "Hysteria 2 配置变更选择如下:"
    echo -e " ${GREEN}1.${PLAIN} 修改端口"
    echo -e " ${GREEN}2.${PLAIN} 修改密码"
    echo -e " ${GREEN}3.${PLAIN} 修改证书类型"
    echo -e " ${GREEN}4.${PLAIN} 修改伪装网站"
    echo ""
    read -rp " 请选择操作 [1-4]：" confAnswer
    case $confAnswer in
        1 ) changeport ;;
        2 ) changepasswd ;;
        3 ) change_cert ;;
        4 ) changeproxysite ;;
        * ) exit 1 ;;
    esac
}

showconf(){
    red "======================================================================================"
    green "Hysteria 2 代理服务安装完成"
    echo ""
    yellow "服务端配置文件 ($HY_CONFIG)："
    if [[ -f "$HY_CONFIG" ]]; then
        red "$(cat "$HY_CONFIG")"
    else
        red "未找到服务端配置文件"
    fi
    echo ""
    if [[ -f "$CLIENT_DIR/hy-client.yaml" ]]; then
        yellow "Hysteria 2 客户端 YAML 配置文件 ($CLIENT_DIR/hy-client.yaml)："
        red "$(cat "$CLIENT_DIR/hy-client.yaml")"
        echo ""
        yellow "Hysteria 2 客户端 JSON 配置文件 ($CLIENT_DIR/hy-client.json)："
        red "$(cat "$CLIENT_DIR/hy-client.json")"
        echo ""
        yellow "Hysteria 2 节点分享链接 ($CLIENT_DIR/url.txt)："
        red "$(cat "$CLIENT_DIR/url.txt")"
        echo ""
        yellow "Hysteria 2 节点单端口分享链接 ($CLIENT_DIR/url-nohop.txt)："
        red "$(cat "$CLIENT_DIR/url-nohop.txt")"
    else
        yellow "未找到客户端配置文件，请先安装 Hysteria 2"
    fi
}

update_core(){
    wget -N https://raw.githubusercontent.com/mikeyshells/hysteria-install/master/install_server.sh
    bash install_server.sh
    rm -f install_server.sh
}

menu(){
    clear
    echo "########################################"
    echo -e "#     ${RED}Hysteria 2 一键安装脚本${PLAIN}         #"
    echo "########################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 安装 Hysteria 2"
    echo -e " ${GREEN}2.${PLAIN} ${RED}卸载 Hysteria 2${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN} Hysteria 2服务管理"
    echo -e " ${GREEN}4.${PLAIN} 修改 Hysteria 2 配置"
    echo -e " ${GREEN}5.${PLAIN} 显示 Hysteria 2 配置文件"
    echo " -------------"
    echo -e " ${GREEN}6.${PLAIN} 更新 Hysteria 2 内核"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo ""
    read -rp "请输入选项 [0-6]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) changeconf ;;
        5 ) showconf ;;
        6 ) update_core ;;
        * ) exit 1 ;;
    esac
}

menu
