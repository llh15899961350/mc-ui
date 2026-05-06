#!/bin/bash

# ===== Common Init =====

# 获取当前 common.sh 所在的真实绝对路径
COMMON_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

#CALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
#cd "$CALLER_DIR" || exit 1

# ===== 彩色定义 =====
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;34m"                                 # Blue
COLOR_WARN="\033[0;33m"                                 # Yellow
COLOR_ERROR="\033[0;31m"                                # Red
COLOR_SUCCESS="\033[0;32m"                              # Green

# ===== 常量定义 =====
CONTAINER_NAME="mc-server"                             # Name of the Docker container
COMPOSE_DIR="$HOME/opt/minecraft"                      # Directory containing docker-compose.yml
# The root URL for the raw GitHub repository. 
# Used by the update_menu function to download the latest version of the script.
RAW_REPOSITORY="https://raw.githubusercontent.com/llh15899961350"
# ==========================================
# 🛡️ 动态权限注入 (解决跨服务器的权限隔离问题)
# ==========================================
# 自动探测当前执行脚本的用户 UID 和 GID
export APP_UID=$(id -u)
export APP_GID=$(id -g)

# --- Directory Paths ---
MC_BASE_DIR="$HOME/opt/minecraft"                      # Server root directory
MC_DATA_DIR="data"                                     # Minecraft data folder name
MC_BACKUP_DIR="/var/backups/minecraft"                 # Local backup storage (Current Directory)
MC_RESTORE_DIR="/var/restore/minecraft"                # Temp folder for restoration (Current Directory)

# --- Backup & Cloud ---
REMOTE_PATH="gdrive:minecraft"                         # Rclone remote destination
KEEP_COUNT=2                                           # Number of backups to keep
FILENAME_PREFIX="mc_backup_"                           # Prefix for backup zip files
RCLONE_FLAGS="--drive-chunk-size 64M --transfers 4 -v" # Rclone performance tuning flags


# ===== 日志函数 =====

function log::info() {
    echo -e "${COLOR_INFO}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1${COLOR_RESET}"
}

function log::warn() {
    echo -e "${COLOR_WARN}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1${COLOR_RESET}"
}

function log::error() {
    echo -e "${COLOR_ERROR}[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1${COLOR_RESET}"
}

function log::success() {
    echo -e "${COLOR_SUCCESS}[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1${COLOR_RESET}"
}


# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    log::error "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
