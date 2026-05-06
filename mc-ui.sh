#!/bin/bash

# ==========================================
# mc-ui - Minecraft Server Management Script
# ==========================================

# 无论脚本从哪里启动（即使是软链接），都能找到 /opt/minecraft 里的 common.sh
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/common.sh"

echo "The OS release is: $release"

# Declare Variables
#xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
#xui_service="${XUI_SERVICE:=/etc/systemd/system}"
#log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
#mkdir -p "${log_folder}"
#iplimit_log_path="${log_folder}/3xipl.log"
#iplimit_banned_log_path="${log_folder}/3xipl-banned.log"


# 函数: 检测 Docker 的运行状态 0: Running, 1: Not Running, 2:Not Installed
function check_docker_status() {
	
	if ! command -v docker >/dev/null 2>&1; then
        return 2
    elif docker info >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 函数: 检测 Docker Compose 的运行状态 0: Installed, 1:Not Installed
function check_docker_compose_status() {
	
	if command -v docker compose >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 0: running, 1: not running, 2: not installed
function check_status() {
	echo ""
}

# 函数: 检测docker服务是否设置了开机自动启动 
# 返回值: 
#   0: enabled (已设置开机自启)
#   1: disabled / not found (未设置开机自启，或服务不存在)
function check_docker_enabled() {
    temp=$(systemctl is-enabled docker)
    if [[ "${temp}" == "enabled" ]]; then
        return 0
    else
        return 1
    fi
}

# 0: running, 1: not running
function check_server_status() {
	check_docker_status
	
	if [ $? == 0 ] && docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
		return 0
	else
		return 1
	fi
}

# 函数: 展示 Server 的运行状态
function show_server_status() {
	check_server_status
	
	if [ $? == 0 ]; then
		echo -e "Minecraft server state: ${COLOR_SUCCESS}Running${COLOR_RESET}"
	else
		echo -e "Minecraft server state: ${COLOR_WARN}Not Running${COLOR_RESET}"
	fi
	
}

# 函数：展示 Docker 和 Server 的运行状态
function show_status() {
    check_docker_status
	
    case $? in
    0)
        echo -e "Docker state: ${COLOR_SUCCESS}Running${COLOR_RESET}"
        show_docker_enable_status
        ;;
    1)
        echo -e "Docker state: ${COLOR_WARN}Not Running${COLOR_RESET}"
        show_docker_enable_status
        ;;
    2)
        echo -e "Docker state: ${COLOR_ERROR}Not Installed${COLOR_RESET}"
        ;;
    esac
	
	show_server_status
}

# 函数: 展示 Docker 是否设置了开机自动启动
function show_docker_enable_status() {
    check_docker_enabled
    if [[ $? == 0 ]]; then
        echo -e "Start Docker automatically: ${COLOR_SUCCESS}Yes${COLOR_RESET}"
    else
        echo -e "Start Docker automatically: ${COLOR_ERROR}No${COLOR_RESET}"
    fi
}

# 函数: 绘制 UI 界面之前
function before_show_menu() {
    echo && echo -n -e "${COLOR_WARN}Press enter to return to the main menu: ${COLOR_RESET}" && read -r temp
    show_menu
}

# 函数: 检查安装环境
function check_install() {
   # 1. 检查 Docker
    check_docker_status
    if [[ $? -eq 2 ]]; then
        echo ""
        log::error "Please install Docker first."
        # 使用简写语法：如果参数个数为0，则执行 before_show_menu
        [[ $# -eq 0 ]] && before_show_menu
        return 1
    fi

    # 2. 检查 Docker Compose
    check_docker_compose_status
    if [[ $? -eq 1 ]]; then
        echo ""
        log::error "Please install Docker Compose first."
        [[ $# -eq 0 ]] && before_show_menu
        return 1
    fi

    # 3. 全部检查通过后，才返回成功
    return 0
}

# 函数: 检查容器是否正在运行 
# 返回: 0 (运行中), 1 (未运行)
function is_container_running() {
    local target_container="${1:-$CONTAINER_NAME}"
    local status
    
    status=$(docker inspect -f '{{.State.Running}}' "$target_container" 2>/dev/null || echo "false")
    
    if [ "$status" = "true" ]; then
        return 0  # True 运行中
    else
        return 1  # False 未运行
    fi
}

# 函数: 执行启动容器的核心逻辑
# 返回值: 0 (成功启动), 1 (启动失败或超时)
function do_start() {

    # 切换目录，如果失败直接返回 1
    cd "$COMPOSE_DIR" || { log::error "Failed to change directory to $COMPOSE_DIR"; return 1; }   

    # 使用 local 声明局部变量，防止污染外部
    local START_TIME=$(date +%s)
    
    # 启动容器
    docker compose up -d --remove-orphans
    
    log::info "⏳ Waiting for Minecraft server to fully initialize (this may take a few minutes)..."
    
    local MAX_WAIT=300       
    local WAIT_INTERVAL=5    
    local ELAPSED=0
    local STARTED=false
    local STATUS
    
    # 轮询检测日志
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        STATUS=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
        
        if [ "$STATUS" != "true" ]; then
            log::error "❌ Container $CONTAINER_NAME stopped unexpectedly during startup!"
            log::error "--- Recent Logs ---"
            docker logs --since "$START_TIME" "$CONTAINER_NAME" | tail -n 50
            return 1 
        fi
    
        # 完美过滤旧日志的 Done 干扰
        if docker logs --since "$START_TIME" "$CONTAINER_NAME" 2>&1 | grep -q -E "Done \(.*\)|Server started\."; then
            log::success "✅ Server is fully started and ready for players!"
            STARTED=true
            break
        fi
    
        sleep $WAIT_INTERVAL
        ELAPSED=$((ELAPSED + WAIT_INTERVAL))
    done

    # 超时保护提示
    if [ "$STARTED" = "false" ]; then
        log::error "⚠️ Warning: Wait timed out after ${MAX_WAIT} seconds. Please check logs."
        return 1
    fi

    # 顺利走到这里说明启动完全成功
    return 0
}

# 函数: 执行停止容器的核心逻辑
# 返回值: 0 (优雅停止成功), 1 (强制停止或异常退出)
function do_stop() {
    log::info "🛑 Stopping server (this may take up to 30 seconds)..."
    
    # 使用 local 声明局部变量，防止污染外部环境变量
    local STOP_TIME=$(date +%s)
    
    # 将 docker stop 放到后台异步执行
    docker stop -t 30 "$CONTAINER_NAME" >/dev/null &
    local STOP_PID=$!
    
    local MAX_WAIT=35
    local WAIT_INTERVAL=2
    local ELAPSED=0
    local GRACEFUL=false
    local STATUS
    
    # 轮询检测日志
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if docker logs --since "$STOP_TIME" "$CONTAINER_NAME" 2>&1 | grep -q "Thread RCON Listener stopped"; then
            GRACEFUL=true
            break
        fi
        
        STATUS=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
        if [ "$STATUS" != "true" ]; then
            if docker logs --since "$STOP_TIME" "$CONTAINER_NAME" 2>&1 | grep -q "Thread RCON Listener stopped"; then
                GRACEFUL=true
            fi
            break
        fi
        
        sleep $WAIT_INTERVAL
        ELAPSED=$((ELAPSED + WAIT_INTERVAL))
    done

    # 确保后台进程释放
    wait $STOP_PID 2>/dev/null

    # 输出判定结果并返回状态码
    if [ "$GRACEFUL" = "true" ]; then
        log::success "✅ Server gracefully stopped and all data saved!"
        return 0
    else
        log::error "⚠️ Server stopped, but graceful shutdown ('Thread RCON Listener stopped') was not detected."
        log::error "It may have been force-killed or crashed during shutdown. Recent logs:"
        docker logs --since "$STOP_TIME" "$CONTAINER_NAME" | tail -n 10
        return 1
    fi
}

# 函数: 启动服务器
function start() {

    if is_container_running; then
        echo ""
        log::info "Server is running, No need to start again, If you need to restart, please select restart"
        # 逻辑：这里什么都不做，它会自动跳出 if，执行最后的 before_show_menu
    else
        # 直接调用核心启动函数
        do_start
    fi
    
    # 统一返回菜单
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

# 函数: 停止服务器
function stop() {
    if is_container_running; then
        # 直接调用核心停止函数
        do_stop
        
    else
        log::info "Server is not running, No need to stop."
    fi
    
    # 统一返回菜单
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

# 函数: 重启服务器
function restart() {
    log::info "🔄 Preparing to restart Minecraft server..."

    # 1. 如果在运行，先安全停止
    if is_container_running; then
        do_stop
        # 如果停止过程发生严重异常（返回1），可以选择终止重启任务
        if [ $? -ne 0 ]; then
            log::error "Abort restart due to stop failure."
            [[ $# -eq 0 ]] && before_show_menu
            return 1
        fi
    fi

    # 2. 调用核心启动
    do_start

    # 3. 统一返回菜单
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

# 函数: 查看服务器及 Docker 运行状态
function status() {
    clear
    echo -e "╔────────────────────────────────────────────────╗"
    echo -e "│   ${COLOR_SUCCESS}System & Server Status${COLOR_RESET}                       │"
    echo -e "╚────────────────────────────────────────────────╝\n"

    # 1. 检查 Docker 守护进程状态
    echo -e "${COLOR_SUCCESS}[1. Docker Service Status]${COLOR_RESET}"
    # 使用 --no-pager 防止界面卡住，并过滤出最核心的几行运行状态
    systemctl status docker --no-pager | grep -E "Loaded:|Active:|Docs:|Process:|Main PID:" 
    echo ""

    # 2. 检查 Docker Compose 容器组状态
    echo -e "${COLOR_SUCCESS}[2. Docker Compose Status]${COLOR_RESET}"
    if [ -d "$COMPOSE_DIR" ]; then
        # 必须进入 compose 所在目录才能正确执行 docker-compose ps
        cd "$COMPOSE_DIR" || echo "Failed to enter $COMPOSE_DIR"
        docker compose ps
    else
        echo "Compose directory not found. Fallback to basic docker ps:"
        docker ps -a --filter "name=$CONTAINER_NAME"
    fi
    echo ""

    # 3. 附加功能：实时资源占用查看 (如果容器正在运行)
    # 这里复用了你之前可能封装过的 is_container_running 判断
    STATUS=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
    if [ "$STATUS" = "true" ]; then
        echo -e "${COLOR_SUCCESS}[3. Container Resource Usage (Real-time)]${COLOR_RESET}"
        # --no-stream 表示只抓取当前这一秒的数据并输出，不会像持续监控那样卡住终端
        docker stats --no-stream "$CONTAINER_NAME"
    else
        echo -e "⚠️  Minecraft server container '$CONTAINER_NAME' is currently ${COLOR_ERROR}NOT RUNNING${COLOR_RESET}."
    fi
    echo ""

    # 4. 返回菜单
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

function backup() {
       
    DATE=$(date +"%Y%m%d_%H%M%S")
    FILENAME="${FILENAME_PREFIX}${DATE}.tar.gz"

    # 确保本地备份目录存在 (如果提示权限不足，请提权执行)
    if [ ! -d "$MC_BACKUP_DIR" ]; then
        mkdir -p "$MC_BACKUP_DIR" || { log::error "Failed to create $MC_BACKUP_DIR. Please run with sudo or check permissions."; return 1; }
    fi

    echo ""
    log::info "🚀 Starting Docker Minecraft Cold Backup..."

    # --- Step 1: Check Container Status ---
    CONTAINER_STATUS=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")

    if [ "$CONTAINER_STATUS" = "true" ]; then
        log::info "Container is running. Stopping gracefully..."
        # 这里你也可以复用之前我们封装的 do_stop 函数，让逻辑更健壮
        docker stop -t 30 "$CONTAINER_NAME" >/dev/null
        WAS_RUNNING=true
    else
        log::info "Container is already stopped. Skipping stop step."
        WAS_RUNNING=false
    fi

    # --- Step 2: Compress Data ---
    log::info "Compressing $MC_BASE_DIR/$MC_DATA_DIR to $MC_BACKUP_DIR ..."
    # 压缩过程如果数据量大可能会耗时，使用 -czf 静默打包
    tar -czf "$MC_BACKUP_DIR/$FILENAME" -C "$MC_BASE_DIR" "$MC_DATA_DIR"

    # --- Step 3: Restore Container Status ---
    if [ "$WAS_RUNNING" = true ]; then
        log::info "Restarting server..."
        # 同样，这里可以复用 do_start
        docker start "$CONTAINER_NAME" >/dev/null
    else
        log::info "Keeping server stopped as it was before backup."
    fi

    # --- Step 4: Upload to Google Drive ---
    log::info "Uploading to Google Drive..."
    rclone copy "$MC_BACKUP_DIR/$FILENAME" "$REMOTE_PATH" $RCLONE_FLAGS

    # --- Step 5: Auto Cleanup (Keep $KEEP_COUNT) ---
    log::info "Cleaning up old backups (Retaining $KEEP_COUNT)..."

    # 5.1 Local Cleanup
    LOCAL_EXPIRED=$(ls -t "$MC_BACKUP_DIR"/${FILENAME_PREFIX}*.tar.gz 2>/dev/null | tail -n +$((KEEP_COUNT + 1)))
    if [ -n "$LOCAL_EXPIRED" ]; then
        log::info "Deleting local expired backups..."
        # 优化：给 xargs 加上 -I {} 确保即便文件名有空格也能安全删除
        echo "$LOCAL_EXPIRED" | xargs -I {} rm -f "{}"
    fi

    # 5.2 Cloud Cleanup (Permanent delete)
    CLOUD_EXPIRED=$(rclone lsf "$REMOTE_PATH" --include "${FILENAME_PREFIX}*.tar.gz" 2>/dev/null | sort -r | tail -n +$((KEEP_COUNT + 1)))
    if [ -n "$CLOUD_EXPIRED" ]; then
        log::info "Deleting cloud expired backups (Bypassing trash)..."
        for FILE in $CLOUD_EXPIRED; do
            rclone deletefile "$REMOTE_PATH/$FILE" --drive-use-trash=false
        done
    fi

    log::success "✅ Backup Process Completed!"
    echo ""

    # --- Step 6: Return to Menu ---
    # 如果是无参调用（即来自交互式菜单），则返回菜单面板
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

# 函数
# 函数: 从云端恢复最新的备份数据
function restore() {
    echo ""
    log::info "📥 Preparing to restore latest backup from Google Drive..."

    # --- 1. 获取云端最新备份包的名字 ---
    # 使用 local 防止变量污染全局
    local LATEST_BACKUP=$(rclone lsf "$REMOTE_PATH" --include "${FILENAME_PREFIX}*.tar.gz" 2>/dev/null | sort -r | head -n 1)

    if [ -z "$LATEST_BACKUP" ]; then
        log::error "❌ No backup found with prefix '$FILENAME_PREFIX' on cloud."
        [[ $# -eq 0 ]] && before_show_menu
        return 1
    fi

    log::info "Target backup found: $LATEST_BACKUP"

    # --- 2. 检查并停止容器 ---
    local WAS_RUNNING=false
    # 复用我们之前封装的 is_container_running 函数
    if is_container_running; then
        log::info "Server is running. Stopping gracefully for restore..."
        docker stop -t 30 "$CONTAINER_NAME" >/dev/null
        WAS_RUNNING=true
    else
        log::info "Server is not running. Proceeding with data swap."
    fi

    # --- 3. 下载备份包到临时目录 ---
    local TEMP_RESTORE_DIR="/tmp/mc_restore_$$" # 使用带进程号的系统临时目录，确保安全
    mkdir -p "$TEMP_RESTORE_DIR"
    log::info "Downloading backup from cloud to temporary directory..."
    
    # 容错：如果下载失败，恢复容器状态并退出
    if ! rclone copy "$REMOTE_PATH/$LATEST_BACKUP" "$TEMP_RESTORE_DIR"; then
        log::error "❌ Failed to download backup from Google Drive."
        rm -rf "$TEMP_RESTORE_DIR"
        [ "$WAS_RUNNING" = true ] && docker start "$CONTAINER_NAME" >/dev/null
        [[ $# -eq 0 ]] && before_show_menu
        return 1
    fi

    # --- 4. 替换与解压数据 ---
    local OLD_DATA_BACKUP="data_old_$(date +%s)"
    
    # 将现有存档暂时重命名（这是容错底线，解压成功后会立刻删掉）
    if [ -d "$MC_BASE_DIR/$MC_DATA_DIR" ]; then
        mv "$MC_BASE_DIR/$MC_DATA_DIR" "$MC_BASE_DIR/$OLD_DATA_BACKUP"
    fi
    
    log::info "Extracting $LATEST_BACKUP..."
    # 容错：检查 tar 解压是否成功
    if tar -xzf "$TEMP_RESTORE_DIR/$LATEST_BACKUP" -C "$MC_BASE_DIR"; then
        log::success "Extraction successful."
        
        # 按你的要求：不再保留旧数据，解压成功后立刻彻底销毁旧文件夹！
        log::info "🗑️ Cleaning up old data..."
        [[ -n "$MC_BASE_DIR" && -n "$OLD_DATA_BACKUP" ]] && rm -rf "$MC_BASE_DIR/$OLD_DATA_BACKUP"
    else
        # 极端情况：包损坏了解压失败，立刻回退旧数据，保护现场！
        log::error "❌ Extraction failed! Archive might be corrupted. Reverting to old data..."
        rm -rf "$MC_BASE_DIR/$MC_DATA_DIR"
        mv "$MC_BASE_DIR/$OLD_DATA_BACKUP" "$MC_BASE_DIR/$MC_DATA_DIR"
        rm -rf "$TEMP_RESTORE_DIR"
        [ "$WAS_RUNNING" = true ] && docker start "$CONTAINER_NAME" >/dev/null
        [[ $# -eq 0 ]] && before_show_menu
        return 1
    fi

    # --- 5. 清理下载的临时压缩包 ---
    log::info "🗑️ Deleting downloaded temporary files..."
    rm -rf "$TEMP_RESTORE_DIR"

    # --- 6. 恢复容器运行状态 ---
    if [ "$WAS_RUNNING" = true ]; then
        log::info "Restarting server..."
        docker start "$CONTAINER_NAME" >/dev/null
    fi

    log::success "✅ Restore task finished!"
    echo ""

    # 返回菜单
    if [[ $# -eq 0 ]]; then
        before_show_menu
    fi
}

function enable_docker() {
    echo ""
}

function disable_docker() {
    echo ""
}

# 函数: 更新脚本菜单本身
function update_menu() {
    echo ""
    log::info "🔄 Preparing to update mc-ui.sh to the latest version..."
    
    # 确认提示（[Y/n] 表示默认回车是同意）
    echo -e -n "${COLOR_WARN}Are you sure you want to update the menu script? [Y/n]: ${COLOR_RESET}"
    
    # 读取用户输入（强制从终端读取，防止缓冲区有上一步遗留的字符）
    read -r confirm </dev/tty
    
    # 纯 Bash 原生处理：剔除可能隐藏的 \r (Windows回车符) 和 空格
    confirm="${confirm//$'\r'/}"
    confirm="${confirm// /}"

    # 核心判定逻辑：
    # -n "$confirm" : 判断输入是否【不为空】
    # 如果【不为空】 并且 【不是y】 并且 【不是Y】，才执行取消逻辑
    if [[ -n "$confirm" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log::info "Update cancelled."
        [[ $# -eq 0 ]] && before_show_menu
        return 0
    fi

    # 构造下载地址
    local URL="${RAW_REPOSITORY}/mc-ui/main/mc-ui.sh"
    local SCRIPT_PATH="$SCRIPT_DIR/mc-ui.sh"
    local TEMP_FILE="/tmp/mc-ui_update_$$.sh"

    log::info "Downloading latest script from $URL ..."
    
    # 下载到临时文件
    if curl -sSL -o "$TEMP_FILE" "$URL"; then
        # 简单校验
        if head -n 1 "$TEMP_FILE" | grep -q "#!/bin/bash"; then
            mv -f "$TEMP_FILE" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            
            log::success "✅ Menu updated successfully!"
            echo -e "${COLOR_SUCCESS}The script will now restart to apply changes...${COLOR_RESET}"
            sleep 2
            
            # 热重启
            exec "$SCRIPT_PATH"
        else
            log::error "❌ Downloaded file seems invalid (not a bash script). Update aborted."
            rm -f "$TEMP_FILE"
            [[ $# -eq 0 ]] && before_show_menu
            return 1
        fi
    else
        log::error "❌ Failed to download the latest script. Please check your network or URL."
        rm -f "$TEMP_FILE"
        [[ $# -eq 0 ]] && before_show_menu
        return 1
    fi
}

# 函数: 日志管理菜单
function show_log() {
    echo -e "╔────────────────────────────────────────────────╗"
    echo -e "│   ${COLOR_SUCCESS}Logs Management${COLOR_RESET}                              │"
    echo -e "│────────────────────────────────────────────────│"
    echo -e "│   ${COLOR_SUCCESS}1.${COLOR_RESET} View Real-time Logs                       │"
    echo -e "│   ${COLOR_SUCCESS}2.${COLOR_RESET} Clear All Logs                            │"
    echo -e "│   ${COLOR_SUCCESS}0.${COLOR_RESET} Back to Main Menu                         │"
    echo -e "╚────────────────────────────────────────────────╝"
    read -rp "Choose an option: " choice

    case "$choice" in
    0)
        # 返回主菜单
        show_menu
        ;;
    1)
        echo ""
        log::info "Showing logs for $CONTAINER_NAME (Press Ctrl+C to exit)..."
        # 持续输出日志 (-f)，并显示最后 100 行
        docker logs -f --tail 100 "$CONTAINER_NAME"
        
        # 退出日志查看后，返回菜单
        if [[ $# -eq 0 ]]; then
            before_show_menu
        fi
        ;;
    2)
        echo ""
        log::info "🧹 Preparing to clear logs for container: $CONTAINER_NAME ..."
        
        # 1. 动态获取当前容器的专属日志文件物理路径
        LOG_PATH=$(docker inspect --format='{{.LogPath}}' "$CONTAINER_NAME" 2>/dev/null)
        
        if [ -n "$LOG_PATH" ] && [ -f "$LOG_PATH" ]; then
            # 2. 清空该日志文件 
            # (注意：Docker 的日志文件存放在 /var/lib/docker 下，必须使用 sudo sh -c 提权清空)
            sudo sh -c "cat /dev/null > \"$LOG_PATH\""
            
            log::success "✅ All logs for $CONTAINER_NAME have been successfully cleared!"
            
            # 3. 按要求：清除后重启服务器
            echo ""
            log::info "Restarting server to generate new log stream..."
            restart 
            # 注意：之前封装的 restart 函数执行完毕后会自动调用 before_show_menu，所以这里不需要再写了
        else
            log::error "❌ Could not find log file for container $CONTAINER_NAME."
            log::error "Please make sure the container exists."
            
            if [[ $# -eq 0 ]]; then
                before_show_menu
            fi
        fi
        ;;
    *)
        echo -e "${COLOR_ERROR}Invalid option. Please select a valid number.${COLOR_RESET}\n"
        sleep 1
        show_log
        ;;
    esac
}


# 函数：绘制 UI 界面
function show_menu() {
	echo -e "
╔────────────────────────────────────────────────╗
│   ${COLOR_SUCCESS}Minecraft Server Management Script${COLOR_RESET}           │
│   ${COLOR_SUCCESS}0.${COLOR_RESET} Exit Script                               │
│────────────────────────────────────────────────│
│   ${COLOR_SUCCESS}1.${COLOR_RESET} Install                                   │
│   ${COLOR_SUCCESS}2.${COLOR_RESET} Update                                    │
│   ${COLOR_SUCCESS}3.${COLOR_RESET} Update Menu                               │
│   ${COLOR_SUCCESS}4.${COLOR_RESET} Uninstall                                 │
│────────────────────────────────────────────────│
│   ${COLOR_SUCCESS}5.${COLOR_RESET} Start                                     │
│   ${COLOR_SUCCESS}6.${COLOR_RESET} Stop                                      │
│   ${COLOR_SUCCESS}7.${COLOR_RESET} Restart                                   │
│   ${COLOR_SUCCESS}8.${COLOR_RESET} Check Status                              │
│   ${COLOR_SUCCESS}9.${COLOR_RESET} Logs Management                           │
│────────────────────────────────────────────────│
│   ${COLOR_SUCCESS}10.${COLOR_RESET} Enable Autostart                         │
│   ${COLOR_SUCCESS}11.${COLOR_RESET} Disable Autostart                        │
│────────────────────────────────────────────────│
│  ${COLOR_SUCCESS}12.${COLOR_RESET} Backup                                    │
│  ${COLOR_SUCCESS}13.${COLOR_RESET} Restore                                   │
╚────────────────────────────────────────────────╝
"
	show_status
    echo ""
	echo && read -rp "Please enter your selection [0-13]: " num

    case "${num}" in
        0)
            exit 0
			;;
        1|2|4)
            echo "Option $choice is not implemented yet. (暂时无需实现)"
            read -n 1 -s -r -p "Press any key to continue..."
            ;;
        3)
            check_install && update_menu
            ;;
        5)
            check_install && start
            ;;
        6)
            check_install && stop
            ;;
        7)
            check_install && restart
            ;;
        8)
            check_install && status
            ;;
        9)
            check_install && show_log
            ;;
        10)
            check_install && enable_docker
            ;;
        11)
            check_install && disable_docker
            ;;
        12)
            check_install && backup
            ;;
        13)
            check_install && restore
            ;;
        *)
            log::error "Please enter the correct number [0-13]"
            ;;
    esac
	
}

if [[ $# -gt 0 ]]; then
    log::warn "This is not implemented yet. (暂时无需实现)"
else
    show_menu
fi