# LLMStorage Module Documentation

> [!NOTE]
> **REPOSITORY LOCATION**  
> The complete codebase for the `LLMStorage` PowerShell modules, along with companion Linux environment setup utilities, can be cloned or contributed to directly on GitHub at [ollama-under-WSL-dynamic](https://github.com).

## 🚀 Windows Host Quick Reference (`LLMStorage.psm1`)
When working on your Windows host, you can use these native PowerShell commands to manage your virtual block storage array. **All mounting actions require an elevated Administrator session.**

| Function Name | Short-Hand Alias | Admin Required? | Description |
| :--- | :--- | :---: | :--- |
| `Mount-LLMStorage` | **`MountLLM`** | **Yes** | Attaches the pre-allocated VHDX container file and maps it cleanly to the host `M:` drive. |
| `Dismount-LLMStorage` | *None* | **Yes** | Gracefully flushes and detaches the virtual drive from the OS to protect against model weight database corruption. |
| `Get-LLMStorageStatus` | *None* | No | Queries the host kernel to dump live storage size metrics, free space, and attachment health states. |

---

> [!WARNING]
> **CRITICAL ARCHITECTURAL REQUIREMENT**  
> This module **does not** create, initialize, or format virtual disk containers. It operates under the strict assumption that the target VHDX file (`D:\LocalLLM\models_storage.vhdx`) has **already been manually created, partitioned, and pre-allocated as a FIXED-size disk image** with an established filesystem (e.g., NTFS or exFAT) ready for host attachment. Attempting to mount an uninitialized or dynamic file will result in storage discovery faults.

## Overview & Core Purpose
The primary purpose of the `LLMStorage` module is to **reliably and uniformly expose a singular, high-performance local Large Language Model (LLM) storage pool to every running WSL-2 Linux distribution on your machine simultaneously**. 

By utilizing Windows Hyper-V virtualization tools to attach the fixed `.vhdx` container and leveraging WSL-2's internal shared memory backbone (`/mnt/wsl/`), massive **Ollama** model weights can be read by any of your Linux distributions without creating duplicate files or filling up your primary operating system drive.

### Core Configuration Defaults
* **Target Storage Path**: `D:\LocalLLM\models_storage.vhdx` *(Must be pre-created/fixed)*
* **Assigned Host Drive Letter**: `M:`
* **Preferred Linux Deployment Directory**: `/opt/models`

---

## On-Demand WSL-2 Execution Workflow
To keep your high-end hardware unencumbered during gaming or standard desktop tasks, the Ollama background daemon should remain disabled. Instead, storage path binding, systemd service lifecycle orchestration, hardware VRAM verification, and interactive terminal chat sessions are handled selectively using an on-demand controller script.

### Step 1: Disable Automatic Background Boot (Run Once)
Execute this command in your main WSL distribution to prevent Ollama from running when Linux boots:
```bash
sudo systemctl disable ollama
```

### Step 2: Deploy the Local Controller Module (`~/LLM.bash`)
Create an independent automation script inside your Linux user profile home directory:
```bash
nano ~/LLM.bash
```

Paste your finalized colorized, socket-aware `LLM.bash` code implementation inside. Save the layout and apply strict executable permissions to the module:
```bash
chmod +x ~/LLM.bash
```

### Step 3: Configure the Systemd Directory Overrides
Because Ollama defaults to standard local directories, you must override its system environment options to direct its internal lookups to `/opt/models`.

1. Open the systemd service override utility:
   ```bash
   sudo systemctl edit ollama.service
   ```
2. Paste the following configuration block into the editor, save, and exit:
   ```ini
   [Service]
   Environment="OLLAMA_MODELS=/opt/models"
   ```
3. Sync the structural changes into your active Linux tracking tables:
   ```bash
   sudo systemctl daemon-reload
   ```

### Step 4: Configure Conditional Loading via `.bashrc`
Add this conditional execution sequence to the very bottom of your `~/.bashrc` profile. This allows you to log into any terminal shell safely without encountering loading warnings if the script file is absent:
```bash
if [ -f "\$HOME/LLM.bash" ]; then
    source "\$HOME/LLM.bash"
fi
```
Refresh your shell configuration: `source ~/.bashrc`

---

## Multi-Instance Runtime Architecture
The `~/LLM.bash` script is explicitly designed to support **multiple concurrent terminal chat sessions** across the same distribution natively. 

* **Idempotent Mounting**: Secondary terminal windows running `start-llm` will detect existing file binds or active daemons and instantly skip initialization overhead to prevent system conflicts.
* **Socket-Based Isolation Protection**: The `stop-llm` teardown block utilizes kernel-level socket statistics (`ss`) to scan for active local TCP connections on port `11434`. The underlying storage partitions and services **will remain online until the very last active terminal window drops its chat session**.

---

## Troubleshooting & NTFS Permission Exclusions
When formatting the virtual hard disk container with an **NTFS** filesystem, Windows automatically populates a hidden system folder (`System Volume Information`) at the drive root. Because Windows restricts this folder with hard kernel-level security descriptors, running standard recursive `chown -R` commands will trigger permission denied faults and cause the Ollama daemon to crash on boot (`status=1/FAILURE`).

To avoid this, the integrated `start-llm` script explicitly routes ownership adjustments through custom `find` pipelines that skip unreadable system directories entirely:
```bash
sudo find /opt/models -mindepth 1 -type d ! -readable -prune -o -name "System Volume Information" -prune -o -exec chown -R ollama:ollama {} + 2>/dev/null
```

If manual intervention is ever required to clear a stuck background crash-loop, run the following sequence:
```bash
# 1. Clean the permission pathways manually while pruning NTFS locks
sudo find /opt/models -mindepth 1 -type d ! -readable -prune -o -name "System Volume Information" -prune -o -exec chown -R ollama:ollama {} + 2>/dev/null
sudo find /opt/models -mindepth 1 -type d ! -readable -prune -o -name "System Volume Information" -prune -o -exec chmod -R 775 {} + 2>/dev/null

# 2. Reset the background service tracking states
sudo systemctl daemon-reload
sudo systemctl stop ollama
```

---

## Complete End-to-End Direct Usage Example

1. Launch a Windows PowerShell console with **Administrator** elevation and execute:
   ```powershell
   MountLLM
   ```
2. Open your preferred WSL-2 distribution terminal and map the raw host partition to the shared global memory layer:
   ```bash
   sudo mkdir -p /mnt/wsl/models_storage
   sudo mount -t drvfs M: /mnt/wsl/models_storage
   ```
3. Invoke the selective runtime workflow to check hardware constraints and enter your chat workspace:
   ```bash
   start-llm
   ```
   *(Or target alternative models downloaded on your disk pool via argument pass-through overrides: `start-llm phi3`).*
4. Type `/exit` or `/bye` inside your model prompt. The terminal script will automatically evaluate active sessions, teardown services if no other windows are connected, and cleanly detach the system hooks.
