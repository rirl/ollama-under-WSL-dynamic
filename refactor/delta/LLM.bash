#!/bin/bash

# Define standardized ANSI color escape sequences
CLR_RESET="\033[0m"
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_CYAN="\033[1;36m"
CLR_MAGENTA="\033[1;35m"

# Centralized Directory Path Mappings
TARGET_MOUNT="/mnt/wsl/models_storage"
BIND_PATH="/opt/models"
OLLAMA_HOST="127.0.0.1"
OLLAMA_PORT="11434"

# Shared runtime control state stored on the mounted LLM volume.
CONTROL_DIR="${TARGET_MOUNT}/.ollama-control"
SESSIONS_DIR="${CONTROL_DIR}/sessions"
CONTROL_LOCK="${CONTROL_DIR}/lock"
DRAINING_FILE="${CONTROL_DIR}/draining"
ENABLED_FILE="${CONTROL_DIR}/enabled"

# Lease behavior. Idle prompts keep a lease even when they do not keep a TCP
# socket open to Ollama.
LEASE_HEARTBEAT_SECONDS="${LEASE_HEARTBEAT_SECONDS:-15}"
LEASE_TTL_SECONDS="${LEASE_TTL_SECONDS:-120}"
CLEAN_CHECKS_REQUIRED="${CLEAN_CHECKS_REQUIRED:-2}"
CLEAN_CHECK_SLEEP_SECONDS="${CLEAN_CHECK_SLEEP_SECONDS:-1}"

LLM_SESSION_ID=""
LLM_LEASE_FILE=""
LLM_HEARTBEAT_PID=""

_llm_now_epoch() {
    date +%s
}

_llm_now_iso() {
    date -Iseconds
}

_llm_distro_name() {
    if [ -n "${WSL_DISTRO_NAME:-}" ]; then
        printf '%s\n' "$WSL_DISTRO_NAME"
        return 0
    fi

    if [ -r /etc/os-release ]; then
        . /etc/os-release
        printf '%s\n' "${ID:-unknown}"
        return 0
    fi

    hostname
}

_llm_mount_active() {
    mount | grep -q "on ${TARGET_MOUNT} "
}

_llm_bind_active() {
    mount | grep -q "on ${BIND_PATH} "
}

_llm_fail_closed_if_unmounted() {
    if _llm_mount_active; then
        return 0
    fi

    echo -e "${CLR_RED}LLM volume is not mounted. Failing closed.${CLR_RESET}"

    if systemctl is-active --quiet ollama; then
        echo -e "${CLR_CYAN}Stopping Ollama engine service because backing storage is unavailable...${CLR_RESET}"
        sudo systemctl stop ollama
    fi

    if systemctl is-enabled --quiet ollama 2>/dev/null; then
        echo -e "${CLR_CYAN}Disabling Ollama engine service because backing storage is unavailable...${CLR_RESET}"
        sudo systemctl disable ollama
    fi

    if _llm_bind_active; then
        echo -e "${CLR_CYAN}Unlinking stale storage path binding...${CLR_RESET}"
        sudo umount "$BIND_PATH" 2>/dev/null || true
    fi

    return 1
}

_llm_init_control_dir() {
    if ! _llm_mount_active; then
        return 1
    fi

    mkdir -p "$SESSIONS_DIR"
    chmod 700 "$CONTROL_DIR" 2>/dev/null || true
    touch "$ENABLED_FILE"
    touch "$CONTROL_LOCK"
}

_llm_with_lock() {
    local command_to_run="$1"
    shift

    _llm_init_control_dir || return 1

    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 200
            "$command_to_run" "$@"
        ) 200>"$CONTROL_LOCK"
    else
        "$command_to_run" "$@"
    fi
}

_llm_write_lease() {
    local lease_file="$1"
    local session_id="$2"
    local distro="$3"
    local pid="$4"
    local now_epoch now_iso

    now_epoch="$(_llm_now_epoch)"
    now_iso="$(_llm_now_iso)"

    cat >"$lease_file" <<LEASE
SESSION_ID='$session_id'
DISTRO='$distro'
HOSTNAME='$(hostname)'
PID='$pid'
STARTED_AT='$now_iso'
LAST_SEEN='$now_iso'
LAST_SEEN_EPOCH='$now_epoch'
STATE='running'
LEASE
}

_llm_acquire_lease_locked() {
    local model_name="$1"
    local distro session_id lease_file

    if [ -f "$DRAINING_FILE" ]; then
        echo -e "${CLR_RED}LLM runtime is draining. Refusing to start a new session.${CLR_RESET}"
        return 1
    fi

    distro="$(_llm_distro_name)"
    session_id="${distro}-$$-$(_llm_now_epoch)"
    lease_file="${SESSIONS_DIR}/${session_id}.lease"

    _llm_write_lease "$lease_file" "$session_id" "$distro" "$$"

    {
        echo "MODEL_NAME='${model_name}'"
    } >>"$lease_file"

    LLM_SESSION_ID="$session_id"
    LLM_LEASE_FILE="$lease_file"

    echo -e "${CLR_GREEN}Acquired shared LLM session lease:${CLR_RESET} ${LLM_SESSION_ID}"
}

_llm_release_lease_locked() {
    if [ -n "$LLM_LEASE_FILE" ] && [ -f "$LLM_LEASE_FILE" ]; then
        rm -f "$LLM_LEASE_FILE"
        echo -e "${CLR_GREEN}Released shared LLM session lease.${CLR_RESET}"
    fi
}

_llm_release_lease() {
    _llm_with_lock _llm_release_lease_locked || true
}

_llm_update_heartbeat_once() {
    if [ -z "$LLM_LEASE_FILE" ] || [ ! -f "$LLM_LEASE_FILE" ]; then
        return 1
    fi

    local now_epoch now_iso tmp_file
    now_epoch="$(_llm_now_epoch)"
    now_iso="$(_llm_now_iso)"
    tmp_file="${LLM_LEASE_FILE}.tmp"

    awk -v now_iso="$now_iso" -v now_epoch="$now_epoch" '
        BEGIN { saw_iso=0; saw_epoch=0 }
        /^LAST_SEEN=/ { print "LAST_SEEN=\047" now_iso "\047"; saw_iso=1; next }
        /^LAST_SEEN_EPOCH=/ { print "LAST_SEEN_EPOCH=\047" now_epoch "\047"; saw_epoch=1; next }
        { print }
        END {
            if (!saw_iso) print "LAST_SEEN=\047" now_iso "\047"
            if (!saw_epoch) print "LAST_SEEN_EPOCH=\047" now_epoch "\047"
        }
    ' "$LLM_LEASE_FILE" >"$tmp_file" && mv "$tmp_file" "$LLM_LEASE_FILE"
}

_llm_start_heartbeat() {
    (
        while true; do
            _llm_update_heartbeat_once || exit 0
            sleep "$LEASE_HEARTBEAT_SECONDS"
        done
    ) &
    LLM_HEARTBEAT_PID="$!"
}

_llm_stop_heartbeat() {
    if [ -n "$LLM_HEARTBEAT_PID" ]; then
        kill "$LLM_HEARTBEAT_PID" 2>/dev/null || true
        wait "$LLM_HEARTBEAT_PID" 2>/dev/null || true
        LLM_HEARTBEAT_PID=""
    fi
}

_llm_cleanup_current_session() {
    _llm_stop_heartbeat
    _llm_release_lease
}

_llm_socket_count() {
    ss -Htan "sport = :${OLLAMA_PORT}" 2>/dev/null | awk '$1 ~ /^(ESTAB|SYN-RECV)$/ { count++ } END { print count + 0 }'
}

_llm_reap_stale_leases_locked() {
    local now lease_file last_seen pid distro current_distro age

    now="$(_llm_now_epoch)"
    current_distro="$(_llm_distro_name)"

    [ -d "$SESSIONS_DIR" ] || return 0

    for lease_file in "$SESSIONS_DIR"/*.lease; do
        [ -e "$lease_file" ] || continue

        last_seen=""
        pid=""
        distro=""

        # shellcheck disable=SC1090
        . "$lease_file" 2>/dev/null || true

        last_seen="${LAST_SEEN_EPOCH:-0}"
        pid="${PID:-}"
        distro="${DISTRO:-}"
        age=$((now - last_seen))

        if [ "$distro" = "$current_distro" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi

        if [ "$age" -le "$LEASE_TTL_SECONDS" ]; then
            continue
        fi

        echo -e "${CLR_YELLOW}Removing stale LLM session lease:${CLR_RESET} $(basename "$lease_file")"
        rm -f "$lease_file"
    done
}

_llm_live_lease_count_locked() {
    _llm_reap_stale_leases_locked >/dev/null 2>&1 || true
    find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.lease' 2>/dev/null | wc -l
}

_llm_live_lease_count() {
    _llm_with_lock _llm_live_lease_count_locked
}

check-llm-mount() {
    echo -e "${CLR_CYAN}Verifying physical VHDX mount state...${CLR_RESET}"

    # 1. Self-Healing Auto-Mount Trigger
    # If the target directory is missing from the kernel mount table, attempt an automatic mount.
    if ! _llm_mount_active; then
        echo -e "${CLR_YELLOW}Target path not found in mount table. Attempting Linux auto-mount...${CLR_RESET}"
        sudo mkdir -p "$TARGET_MOUNT"

        # Attempt to mount the host M: drive; mute standard errors if the host block is detached.
        sudo mount -t drvfs M: "$TARGET_MOUNT" 2>/dev/null
    fi

    # 2. Strict Mount Table Verification
    if ! _llm_mount_active; then
        echo -e "${CLR_RED}================================================================${CLR_RESET}"
        echo -e "${CLR_RED}ERROR: The storage volume could not be resolved inside WSL-2!${CLR_RESET}"
        echo -e "${CLR_YELLOW}Please ensure you have run 'MountLLM' in Windows Admin PowerShell first,${CLR_RESET}"
        echo -e "${CLR_YELLOW}then try running 'start-llm' again.${CLR_RESET}"
        echo -e "${CLR_RED}================================================================${CLR_RESET}"
        _llm_fail_closed_if_unmounted
        return 1
    fi

    _llm_init_control_dir
    echo -e "${CLR_GREEN}Physical VHDX mount verified active.${CLR_RESET}"
    return 0
}

get-llm-vram() {
    echo -e "${CLR_MAGENTA}================================================================${CLR_RESET}"
    echo -e "${CLR_MAGENTA}NVIDIA RTX 5080 VRAM ALLOCATION & SYSTEM MEMORY STATE:${CLR_RESET}"
    echo -e "${CLR_MAGENTA}================================================================${CLR_RESET}"

    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits | while CSV_LINE= read -r line; do
            local GPU_NAME
            local VRAM_USED
            local VRAM_TOTAL
            local USED_GB
            local TOTAL_GB

            GPU_NAME=$(echo "$line" | cut -d',' -f1)
            VRAM_USED=$(echo "$line" | cut -d',' -f2 | tr -d ' ')
            VRAM_TOTAL=$(echo "$line" | cut -d',' -f3 | tr -d ' ')

            USED_GB=$(awk "BEGIN {print $VRAM_USED/1024}")
            TOTAL_GB=$(awk "BEGIN {print $VRAM_TOTAL/1024}")

            echo -e "${CLR_CYAN}Device:${CLR_RESET} $GPU_NAME"
            echo -e "${CLR_CYAN}VRAM Consumption:${CLR_RESET} ${CLR_GREEN}${USED_GB} GB${CLR_RESET} / ${CLR_YELLOW}${TOTAL_GB} GB${CLR_RESET} allocated"
        done
    else
        echo -e "${CLR_YELLOW}WARNING: nvidia-smi tool not found. Falling back to host memory check.${CLR_RESET}"
        free -h | awk '/^Mem:/ {print "WSL Host RAM: Used: " $3 " / Total: " $2}'
    fi
    echo -e "${CLR_MAGENTA}================================================================${CLR_RESET}"
}

stop-llm() {
    echo -e "${CLR_YELLOW}Initiating session cleanup evaluation...${CLR_RESET}"

    if ! _llm_fail_closed_if_unmounted; then
        return 1
    fi

    _llm_init_control_dir || return 1
    touch "$DRAINING_FILE"

    local check_index active_sockets live_leases
    for ((check_index = 1; check_index <= CLEAN_CHECKS_REQUIRED; check_index++)); do
        active_sockets="$(_llm_socket_count)"
        live_leases="$(_llm_live_lease_count)"

        if [ "$active_sockets" -gt 0 ] || [ "$live_leases" -gt 0 ]; then
            echo -e "${CLR_CYAN}LLM runtime is still in use: ${active_sockets} active/connecting socket(s), ${live_leases} live lease(s).${CLR_RESET}"
            echo -e "${CLR_GREEN}Keeping Ollama service and storage pools active for other sessions.${CLR_RESET}"
            rm -f "$DRAINING_FILE"
            return 0
        fi

        if [ "$check_index" -lt "$CLEAN_CHECKS_REQUIRED" ]; then
            sleep "$CLEAN_CHECK_SLEEP_SECONDS"
        fi
    done

    echo -e "${CLR_YELLOW}No active sockets or live leases found. Proceeding with full teardown...${CLR_RESET}"

    if systemctl is-active --quiet ollama; then
        echo -e "${CLR_CYAN}Stopping Ollama engine service...${CLR_RESET}"
        sudo systemctl stop ollama
    fi

    if systemctl is-enabled --quiet ollama 2>/dev/null; then
        echo -e "${CLR_CYAN}Disabling Ollama engine service...${CLR_RESET}"
        sudo systemctl disable ollama
    fi

    if _llm_bind_active; then
        echo -e "${CLR_CYAN}Unlinking storage path bindings safely...${CLR_RESET}"
        sudo umount "$BIND_PATH"
    fi

    rm -f "$DRAINING_FILE"
    echo -e "${CLR_GREEN}LLM Environment completely isolated and clean!${CLR_RESET}"
}

start-llm() {
    local MODEL_NAME="${1:-llama3}"

    # 1. Enforce physical Windows attachment validation and handle auto-mounting details.
    if ! check-llm-mount; then
        return 1
    fi

    if ! _llm_with_lock _llm_acquire_lease_locked "$MODEL_NAME"; then
        return 1
    fi

    trap _llm_cleanup_current_session EXIT INT TERM HUP
    _llm_start_heartbeat

    # 2. Idempotent Target Folder Creation
    sudo mkdir -p "$BIND_PATH"

    # 3. Idempotent Bind Mount Application
    if ! _llm_bind_active; then
        echo -e "${CLR_CYAN}Initializing LLM storage bind...${CLR_RESET}"
        sudo mount --bind "$TARGET_MOUNT" "$BIND_PATH"
    else
        echo -e "${CLR_YELLOW}Storage path ${BIND_PATH} is already bound. Skipping mount execution.${CLR_RESET}"
    fi

    # 4. Fast Ownership Allocation Routine
    echo -e "${CLR_CYAN}Configuring file handle ownership mappings...${CLR_RESET}"
    sudo find "$BIND_PATH" -mindepth 1 -type d ! -readable -prune -o -name "System Volume Information" -prune -o -exec chown ollama:ollama {} + 2>/dev/null
    sudo find "$BIND_PATH" -mindepth 1 -type d ! -readable -prune -o -name "System Volume Information" -prune -o -exec chmod 775 {} + 2>/dev/null

    # 5. Idempotent Service Initialization Check
    if ! systemctl is-active --quiet ollama; then
        echo -e "${CLR_CYAN}Starting Ollama runtime service...${CLR_RESET}"
        sudo systemctl start ollama
    else
        echo -e "${CLR_YELLOW}Ollama runtime service is already running active context.${CLR_RESET}"
    fi

    # 6. Dynamic Socket Listening Validation Loop
    echo -n -e "${CLR_CYAN}Waiting for Ollama API port (11434) to listen${CLR_RESET}"
    local ATTEMPTS=0
    while ! timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/11434" 2>/dev/null; do
        echo -n -e "${CLR_YELLOW}.${CLR_RESET}"
        sleep 0.5
        ((ATTEMPTS++))
        if [ "$ATTEMPTS" -gt 20 ]; then
            echo ""
            echo -e "${CLR_RED}ERROR: Ollama service failed to open port 11434 within 10 seconds.${CLR_RESET}"
            echo -e "${CLR_CYAN}Checking status details:${CLR_RESET}"
            sudo systemctl status ollama.service
            return 1
        fi
    done
    echo -e "${CLR_GREEN} Online!${CLR_RESET}"

    # 7. Collect live VRAM performance snapshot
    get-llm-vram

    # 8. Trigger terminal interactive interface session
    echo -e "${CLR_GREEN}Launching LLM Environment using model:${CLR_RESET} [${CLR_MAGENTA}$MODEL_NAME${CLR_RESET}]..."
    ollama run "$MODEL_NAME"

    # 9. Clean execution fall-through teardown
    echo ""
    _llm_cleanup_current_session
    trap - EXIT INT TERM HUP
    stop-llm
}
