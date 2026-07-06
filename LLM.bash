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

check-llm-mount() {
    echo -e "${CLR_CYAN}Verifying physical VHDX mount state...${CLR_RESET}"
    
    # 1. Self-Healing Auto-Mount Trigger
    # If the target directory is missing from the kernel mount table, attempt an automatic mount
    if ! mount | grep -q "on ${TARGET_MOUNT} "; then
        echo -e "${CLR_YELLOW}Target path not found in mount table. Attempting Linux auto-mount...${CLR_RESET}"
        sudo mkdir -p "$TARGET_MOUNT"
        
        # Attempt to mount the host M: drive; mute standard errors if the host block is detached
        sudo mount -t drvfs M: "$TARGET_MOUNT" 2>/dev/null
    fi
    
    # 2. Strict Mount Table Verification
    if ! mount | grep -q "on ${TARGET_MOUNT} "; then
        echo -e "${CLR_RED}================================================================${CLR_RESET}"
        echo -e "${CLR_RED}ERROR: The storage volume could not be resolved inside WSL-2!${CLR_RESET}"
        echo -e "${CLR_YELLOW}Please ensure you have run 'MountLLM' in Windows Admin PowerShell first,${CLR_RESET}"
        echo -e "${CLR_YELLOW}then try running 'start-llm' again.${CLR_RESET}"
        echo -e "${CLR_RED}================================================================${CLR_RESET}"
        return 1
    fi
    
    echo -e "${CLR_GREEN}Physical VHDX mount verified active.${CLR_RESET}"
    return 0
}

get-llm-vram() {
    echo -e "${CLR_MAGENTA}================================================================${CLR_RESET}"
    echo -e "${CLR_MAGENTA}NVIDIA RTX 5080 VRAM ALLOCATION & SYSTEM MEMORY STATE:${CLR_RESET}"
    echo -e "${CLR_MAGENTA}================================================================${CLR_RESET}"
    
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits | while CSV_LINE= read -r line; do
            local GPU_NAME=$(echo "$line" | cut -d',' -f1)
            local VRAM_USED=$(echo "$line" | cut -d',' -f2 | tr -d ' ')
            local VRAM_TOTAL=$(echo "$line" | cut -d',' -f3 | tr -d ' ')
            
            local USED_GB=$(awk "BEGIN {print $VRAM_USED/1024}")
            local TOTAL_GB=$(awk "BEGIN {print $VRAM_TOTAL/1024}")
            
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
    
    # Counts active local TCP connections to the Ollama API port (11434).
    local ACTIVE_SESSIONS=$(ss -tna | grep -c "127.0.0.1:11434.*ESTAB")
    
    # If another window is still actively holding a socket open, skip the teardown
    if [ "$ACTIVE_SESSIONS" -gt 0 ]; then
        echo -e "${CLR_CYAN}Other active LLM network sessions detected (${ACTIVE_SESSIONS} remaining).${CLR_RESET}"
        echo -e "${CLR_GREEN}Keeping core engine service and storage pools active for other windows.${CLR_RESET}"
        return 0
    fi

    echo -e "${CLR_YELLOW}No other active network sessions found. Proceeding with full teardown...${CLR_RESET}"
    
    if systemctl is-active --quiet ollama; then
        echo -e "${CLR_CYAN}Stopping Ollama engine service...${CLR_RESET}"
        sudo systemctl stop ollama
    fi
    
    if mount | grep -q "on ${BIND_PATH} "; then
        echo -e "${CLR_CYAN}Unlinking storage path bindings safely...${CLR_RESET}"
        sudo umount "$BIND_PATH"
    fi
    
    echo -e "${CLR_GREEN}LLM Environment completely isolated and clean!${CLR_RESET}"
}

start-llm() {
    local MODEL_NAME="${1:-llama3}"

    # 1. Enforce physical Windows attachment validation and handle auto-mounting details
    if ! check-llm-mount; then
        return 1
    fi

    # 2. Idempotent Target Folder Creation
    sudo mkdir -p "$BIND_PATH"
    
    # 3. Idempotent Bind Mount Application
    if ! mount | grep -q "on ${BIND_PATH} "; then
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
        if [ $ATTEMPTS -gt 20 ]; then
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
    stop-llm
}
