# LLMStorage Module Documentation

> [!WARNING]
> **CRITICAL ARCHITECTURAL REQUIREMENT**  
> This module **does not** create, initialize, or format virtual disk containers. It operates under the strict assumption that the target VHDX file (`D:\LocalLLM\models_storage.vhdx`) has **already been manually created, partitioned, and pre-allocated as a FIXED-size disk image** with an established filesystem (e.g., NTFS or exFAT) ready for host attachment. Attempting to mount an uninitialized or dynamic file will result in storage discovery faults.

## Overview
The `LLMStorage` module manages fixed-size virtual hard disk (`.vhdx`) mappings on Windows. It isolates massive local Large Language Model (LLM) weights—specifically for the **Ollama** runtime backend—and safely exposes them to your **WSL-2 Linux subsystem** without filling up your primary OS drive.

### Core Configuration Defaults
* **Target Storage Path**: `D:\LocalLLM\models_storage.vhdx` *(Must be pre-created/fixed)*
* **Assigned Host Drive Letter**: `M:`

---

## Critical WSL-2 & Ollama Workflow Notes
While this PowerShell module handles the **Windows host side** attachment, Windows will not automatically mount the drive inside Linux, nor will Ollama look there by default. 

You must follow these post-mount steps inside your WSL-2 terminal session using `systemctl` to link everything together:

### Step 1: Manually Mount the Volume in WSL-2
Once the disk is online on Windows as `M:`, execute these commands inside your WSL-2 terminal to mount the filesystem:
```bash
sudo mkdir -p /mnt/wsl/models_storage
sudo mount -t drvfs M: /mnt/wsl/models_storage
```

### Step 2: Override the Ollama Service Storage Path
Because Ollama is managed as a system service, you must tell its `systemctl` configuration where the new storage path is located. 

1. Open the systemd service override file:
   ```bash
   sudo systemctl edit ollama.service
   ```
2. Paste the following configuration block into the editor, save, and close it:
   ```ini
   [Service]
   Environment="OLLAMA_MODELS=/mnt/wsl/models_storage/ollama"
   ```

### Step 3: Reload Systemd and Start Ollama
Apply the changes and launch the daemon using `systemctl`:
```bash
sudo systemctl daemon-reload
sudo systemctl start ollama
```
*(To verify it running successfully on the new disk, you can check its status with `sudo systemctl status ollama`).*

---

## Prerequisites & Requirements
* **Pre-existing Fixed Storage**: The underlying `.vhdx` container must exist and be fully formatted prior to using this runtime engine.
* **Administrative Privileges**: Core disk manipulation APIs require running your host PowerShell session as an Administrator.
* **Hyper-V Storage Cmdlets**: Requires native Windows storage virtualization primitives (`Get-VHD`, `Mount-VHD`).

---

## Command Reference

| Command | Type | Description | Admin Required |
| :--- | :--- | :--- | :---: |
| **`Mount-LLMStorage`** | Function | Mounts the pre-allocated VHDX container and reserves the host `M:` partition. | **Yes** |
| **`MountLLM`** | Alias | Shorthand shortcut pointing directly to `Mount-LLMStorage`. | **Yes** |
| **`Dismount-LLMStorage`** | Function | Detaches the storage blocks safely to prevent Ollama database corruption. | **Yes** |
| **`Get-LLMStorageStatus`** | Function | Returns live space telemetry and baseline disk tracking states. | No |

---

## Detailed Command Specifications

### 1. Mount-LLMStorage
Mounts the target VHDX array to the host subsystem. 

#### Shorthand Alias
```powershell
MountLLM
```

#### Syntax
```powershell
Mount-LLMStorage [-Verbose]
```

#### Behavioral Steps
1. Asserts host administrative execution context.
2. Interrogates path variables to verify the physical presence of the `.vhdx` blob. **Throws an explicit terminating error if the file has not been created yet.**
3. Bypasses execution blocks smoothly if the drive is already running.
4. Drops a 2-second sleep anchor to let Windows partition discovery catch up before completing initialization logs.

---

### 2. Dismount-LLMStorage
Gracefully unlinks the virtual block array from the host OS partition structure.

#### Syntax
```powershell
Dismount-LLMStorage
```

#### Behavioral Steps
1. Asserts administrative session rights.
2. Checks to confirm the drive isn't already offline.
3. Triggers the flush detach sequence. *(Note: Stop the service via `sudo systemctl stop ollama` inside WSL before running this)*.

---

### 3. Get-LLMStorageStatus
Queries the operational environment to dump detailed telemetry metrics regarding the virtual volume layout.

#### Syntax
```powershell
Get-LLMStorageStatus
```

#### Sample Output Object
```text
VhdPath     : D:\(\LocalLLM\models_storage.\)vhdx
DriveLetter : M
Attached    : True
DiskNumber  : 3
SizeGB      : 256.00
FreeSpaceGB : 142.34
```

---

## Private / Internal Helper Functions

### Test-AdminPrivilege
An internal checker function used by mounting engines to assert security contexts before running storage subsystem actions. Returns a Boolean value (`$true` / `$false`).
```powershell
# Used internally within the module structure
Test-AdminPrivilege
```
