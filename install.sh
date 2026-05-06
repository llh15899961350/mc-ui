#!/bin/bash

# ===== 彩色定义 =====
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;34m"
COLOR_WARN="\033[0;33m"
COLOR_ERROR="\033[0;31m"
COLOR_SUCCESS="\033[0;32m"

# ===== 常量定义 =====
CONTAINER_NAME="mc-server"
COMPOSE_DIR="$HOME/opt/minecraft"
# The root URL for the raw GitHub repository. 
# Used by the update_menu function to download the latest version of the script.
RAW_REPOSITORY="https://raw.githubusercontent.com/llh15899961350"

# ==========================================
# 🛡️ 动态权限注入
# ==========================================
export APP_UID=$(id -u)
export APP_GID=$(id -g)
TARGET_USER=${SUDO_USER:-$USER}
TARGET_GROUP=$(id -g -n $TARGET_USER)

# --- Directory Paths ---
MC_BASE_DIR="$HOME/opt/minecraft"
MC_DATA_DIR="data"
MC_BACKUP_DIR="/var/backups/minecraft"
MC_RESTORE_DIR="/var/restore/minecraft"

# --- Backup & Cloud (静态配置) ---
RCLONE_REMOTE_NAME="gdrive"
RCLONE_REMOTE_DIR="minecraft"
RCLONE_REMOTE_PATH="${RCLONE_REMOTE_NAME}:${RCLONE_REMOTE_DIR}"
KEEP_COUNT=1
FILENAME_PREFIX="mc_backup_"
RCLONE_FLAGS="--drive-chunk-size 64M --transfers 4 -v"

CALLER_DIR="$(pwd)"

# ===== 日志函数 =====
function log::info() { echo -e "${COLOR_INFO}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1${COLOR_RESET}"; }
function log::warn() { echo -e "${COLOR_WARN}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1${COLOR_RESET}"; }
function log::error() { echo -e "${COLOR_ERROR}[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1${COLOR_RESET}"; }
function log::success() { echo -e "${COLOR_SUCCESS}[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1${COLOR_RESET}"; }

# Check OS
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    log::error "Failed to check the system OS, please contact the author!"
    exit 1
fi

function arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        *) echo -e "${COLOR_ERROR}Unsupported CPU architecture!${COLOR_RESET}" && exit 1 ;;
    esac
}

# ==========================================
# 🚀 核心初始化函数
# ==========================================

function init_docker() {
    log::info "⏳ 正在初始化 Docker 配置文件..."
    # 使用子 Shell 避免污染当前执行路径
    (
        cd "$COMPOSE_DIR" || { log::error "Failed to change directory to $COMPOSE_DIR"; exit 1; } 
        wget -q "${RAW_REPOSITORY}/mc-ui/main/docker-compose.yml" -O docker-compose.yml
    )

    # 将当前真实用户加入 docker 组
    sudo usermod -aG docker "$TARGET_USER"
    log::warn "已将用户 $TARGET_USER 加入 docker 组。注意：如果是首次安装，后续可能需要重新连接 SSH 才能免 sudo 执行 docker 命令。"
    log::success "✅ Docker 配置完成！"
}

function init_rclone() {
    log::info "⏳ 正在配置 Rclone..."
    if ! rclone config dump | grep -q "\"$RCLONE_REMOTE_NAME\":"; then
        log::warn "未检测到名为 '$RCLONE_REMOTE_NAME' 的 Rclone 配置，请根据提示完成授权。"
        rclone config
    else
        log::success "✅ 检测到已存在 '$RCLONE_REMOTE_NAME' 的 Rclone 配置，跳过绑定。"
        #帮我实现多一个逻辑,进入存在RCLONE_REMOTE_NAME, 寻求用户是否进入Rclone 配置, y(Entry default), n(No)
    fi
}

function init_dirs() {
    log::info "⏳ 正在创建 Minecraft 本地备份和恢复目录..."
    sudo mkdir -p "$MC_BACKUP_DIR"
    sudo mkdir -p "$MC_RESTORE_DIR"
    sudo chown -R "$TARGET_USER:$TARGET_GROUP" "$MC_BACKUP_DIR" "$MC_RESTORE_DIR"
    sudo chmod -R 755 "$MC_BACKUP_DIR" "$MC_RESTORE_DIR"
    log::success "✅ 目录初始化完成！"
}

function init_mc-ui() {
    log::info "⏳ 正在下载并配置 mc-ui 脚本..."
    (
        cd "$COMPOSE_DIR" || { log::error "Failed to change directory to $COMPOSE_DIR"; exit 1; } 
        wget -q "${RAW_REPOSITORY}/mc-ui/main/common.sh" -O common.sh
        wget -q "${RAW_REPOSITORY}/mc-ui/main/mc-ui.sh" -O mc-ui.sh
        chmod +x mc-ui.sh common.sh
    )

    # 清理并写入别名
    sed -i '/alias mc-ui=/d' ~/.bashrc
    echo "alias mc-ui='bash $COMPOSE_DIR/mc-ui.sh'" >> ~/.bashrc
    log::success "✅ mc-ui alias 已添加到 ~/.bashrc！(下次登录或执行 source ~/.bashrc 后可直接使用)"
}

function init_data_folder() {
    sudo chown -R "$TARGET_USER:$TARGET_GROUP" "$COMPOSE_DIR/$MC_DATA_DIR"
    find "$COMPOSE_DIR/$MC_DATA_DIR" -type d -exec chmod 755 {} +
    find "$COMPOSE_DIR/$MC_DATA_DIR" -type f -exec chmod 644 {} +
    log::success "✅ 数据文件夹权限调整完毕！"
}

function install_base() {
    log::info "⏳ 正在安装基础依赖包..."
    case "${release}" in
        ubuntu | debian | armbian)
            sudo apt update
            sudo apt install docker.io docker-compose-plugin wget unzip curl -y
            # 安装 rclone
            sudo curl https://rclone.org/install.sh | sudo bash
        ;;
    esac
    log::success "✅ 基础依赖安装完成！"
}

function install_mc-ui() {
    mkdir -p "$COMPOSE_DIR/$MC_DATA_DIR"

    install_base
    init_data_folder
    init_dirs
    init_docker
    init_mc-ui
    init_rclone

    log::success "🎉 整体安装流程结束！正在为您启动 mc-ui..."
    # 使用绝对路径执行，避免 source .bashrc 无法生效的问题
    bash "$COMPOSE_DIR/mc-ui.sh"
}

echo "The OS release is: $release"
echo "Arch: $(arch)"
echo -e "${COLOR_SUCCESS}Running Installation...${COLOR_RESET}"

# 开始执行
install_mc-ui "$1"
