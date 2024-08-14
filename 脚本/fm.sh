#!/bin/bash

# 定义颜色常量
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN='\033[0m'

# 定义颜色输出函数
log_red(){
    echo -e "${RED}[ERROR] $1${PLAIN}"
}

log_green(){
    echo -e "${GREEN}[INFO] $1${PLAIN}"
}

log_yellow(){
    echo -e "${YELLOW}[WARN] $1${PLAIN}"
}

# 检查操作系统类型
check_system(){
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        SYSTEM=$ID
    else
        log_red "无法识别的操作系统"
        exit 1
    fi
}

# 包管理操作
package_update(){
    case "$SYSTEM" in
        debian|ubuntu)
            sudo apt-get -y update
            ;;
        centos|redhat|fedora|oracle|alma|rocky|amazon)
            sudo yum -y update
            ;;
        *)
            log_red "不支持的操作系统"
            exit 1
            ;;
    esac
}

package_install(){
    package_name=$1
    case "$SYSTEM" in
        debian|ubuntu)
            sudo apt-get -y install "$package_name"
            ;;
        centos|redhat|fedora|oracle|alma|rocky|amazon)
            sudo yum -y install "$package_name"
            ;;
        *)
            log_red "不支持的操作系统"
            exit 1
            ;;
    esac
}

# 检查并安装必要的工具
check_install_tools(){
    tools=("curl" "wget" "socat")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_yellow "$tool 未安装，正在安装..."
            package_install "$tool"
        fi
    done
}

# 安装 Nginx
install_nginx(){
    if command -v nginx &> /dev/null; then
        log_green "Nginx 已安装"
    else
        log_yellow "Nginx 未安装，正在安装..."
        package_install "nginx"
        if [ $? -ne 0 ]; then
            log_red "Nginx 安装失败，请检查您的系统是否支持 apt 或 yum。"
            exit 1
        fi
    fi
}

# 安装 acme.sh
install_acme_sh(){
    read -rp "请输入注册邮箱（例：admin@gmail.com，或留空自动生成）：" acmeEmail
    if [ -z "$acmeEmail" ]; then
        autoEmail=$(date +%s%N | md5sum | cut -c 1-32)
        acmeEmail="$autoEmail@gmail.com"
    fi
    curl https://get.acme.sh | sh -s email="$acmeEmail"
    source ~/.bashrc
    bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    if [[ -n $(~/.acme.sh/acme.sh -v 2>/dev/null) ]]; then
        log_green "Acme.sh 证书申请脚本安装成功！"
    else
        log_red "抱歉，Acme.sh 证书申请脚本安装失败"
        log_green "建议如下："
        log_yellow "1. 检查 VPS 的网络环境"
        log_yellow "2. 脚本可能需要更新，建议截图发布到 GitHub Issues 或 TG 群询问"
        exit 1
    fi
}

# 下载并替换 Nginx 配置文件
download_nginx_config(){
    local url="https://raw.githubusercontent.com/aquasofts/fmgen/main/%E8%84%9A%E6%9C%AC/fm"
    local destination="/etc/nginx/sites-available/fm"
    
    wget -O "$destination" "$url"
    if [ $? -ne 0 ]; then
        log_red "下载失败，请检查网络连接。"
        exit 1
    else
        log_green "文件已成功下载并覆盖到 $destination"
    fi
}

# 安装和配置 SSL 证书
setup_ssl_cert(){
    nginx -s stop
    read -p "请输入你的域名: " domain
    log_green "你输入的域名为: $domain，正在进行域名合法性校验..."

    if ~/.acme.sh/acme.sh --list | grep -q "$domain"; then
        log_red "域名合法性校验失败，当前环境已有对应域名证书，不可重复申请。"
        ~/.acme.sh/acme.sh --list
        exit 1
    else
        log_green "域名合法性校验通过..."
    fi

    local WebPort=80
    read -p "请输入你所希望使用的端口，建议使用80端口: " WebPort
    if [[ ! "$WebPort" =~ ^[0-9]+$ ]] || [ "$WebPort" -gt 65535 ] || [ "$WebPort" -lt 1 ]; then
        log_yellow "你所选择的端口 $WebPort 为无效值，将使用默认 80 端口进行申请。"
        WebPort=80
    fi

    log_green "将会使用 $WebPort 进行证书申请，请确保端口处于开放状态..."
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --httpport "$WebPort"
    if [ $? -ne 0 ]; then
        log_red "证书申请失败，请参见报错信息。"
        rm -rf ~/.acme.sh/"$domain"
        exit 1
    else
        log_green "证书申请成功，开始安装证书..."
    fi

    certPath="/root/cert"
    mkdir -p "$certPath"
    ~/.acme.sh/acme.sh --installcert -d "$domain" --ca-file "$certPath/ca.cer" \
        --cert-file "$certPath/$domain.cer" --key-file "$certPath/$domain.key" \
        --fullchain-file "$certPath/fullchain.cer"

    if [ $? -ne 0 ]; then
        log_red "证书安装失败，脚本退出"
        rm -rf ~/.acme.sh/"$domain"
        exit 1
    else
        log_green "证书安装成功，开启自动更新..."
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        chmod 755 "$certPath"
        ls -lah "$certPath"
    fi

    # 替换 Nginx 配置文件中的占位符
    sudo sed -i "s|yourdomain|$domain|g" /etc/nginx/sites-available/fm
    sudo sed -i "s|jjkk|$certPath/$domain.cer|g" /etc/nginx/sites-available/fm
    sudo sed -i "s|hhjj|$certPath/$domain.key|g" /etc/nginx/sites-available/fm

    # 链接配置文件
    sudo ln -sf /etc/nginx/sites-available/fm /etc/nginx/sites-enabled/

    # 重启 Nginx
    sudo systemctl restart nginx
    if [ $? -ne 0 ]; then
        log_red "Nginx 重启失败，请检查 Nginx 配置。"
        exit 1
    else
        log_green "Nginx 已成功重启。您的链接为 https://$domain"
    fi
}

# 主程序入口
main(){
    check_system
    package_update
    check_install_tools
    install_nginx
    install_acme_sh
    download_nginx_config
    setup_ssl_cert
}

main
