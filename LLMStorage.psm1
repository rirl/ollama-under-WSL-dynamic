<#
.MODULE NAME
    LLMStorage
.SYNOPSIS
    A PowerShell module to manage fixed-size VHDX storage mappings for WSL LLM development.
#>

$global:LLMVhdPath = "D:\LocalLLM\models_storage.vhdx"
$global:LLMDriveLetter = "M"
$global:LLMControlDirectoryName = ".ollama-control"
$global:LLMLeaseTtlSeconds = 120

# Define the custom shorthand alias
Set-Alias -Name MountLLM -Value Mount-LLMStorage -Description "Shorthand to mount the LLM fixed VHDX"

function Test-AdminPrivilege {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LLMControlPath {
    return "$($global:LLMDriveLetter):\$($global:LLMControlDirectoryName)"
}

function Get-LLMSessionsPath {
    return (Join-Path -Path (Get-LLMControlPath) -ChildPath "sessions")
}


function ConvertFrom-LLMLeaseFile {
    <#
    .SYNOPSIS
        Parses a simple Bash-style .lease file into a PowerShell object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $values = @{}
    Get-Content -Path $File.FullName -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_ -match "^([A-Za-z_][A-Za-z0-9_]*)='(.*)'$") {
            $values[$Matches[1]] = $Matches[2]
        }
    }

    [PSCustomObject]@{
        Name             = $File.Name
        FullName         = $File.FullName
        SessionId        = $values['SESSION_ID']
        Distro           = $values['DISTRO']
        Hostname         = $values['HOSTNAME']
        LocalPid         = $values['LOCAL_PID']
        RootNamespacePid = $values['ROOT_NAMESPACE_PID']
        PidNamespace     = $values['PID_NAMESPACE']
        ParentPid        = $values['PPID']
        ModelName        = $values['MODEL_NAME']
        State            = $values['STATE']
        StartedAt        = $values['STARTED_AT']
        LastSeen         = $values['LAST_SEEN']
        LastSeenEpoch    = $values['LAST_SEEN_EPOCH']
        LastWriteTime    = $File.LastWriteTime
        AgeSeconds       = [Math]::Round(((Get-Date) - $File.LastWriteTime).TotalSeconds, 0)
    }
}

function Get-ActiveLLMSessionLeases {
    <#
    .SYNOPSIS
        Lists non-stale shared LLM session leases recorded on the mounted LLM volume.
    #>
    [CmdletBinding()]
    param(
        [int]$LeaseTtlSeconds = $global:LLMLeaseTtlSeconds
    )

    $sessionsPath = Get-LLMSessionsPath
    if (-not (Test-Path -Path $sessionsPath)) {
        return @()
    }

    $cutoff = (Get-Date).AddSeconds(-1 * $LeaseTtlSeconds)

    @(Get-ChildItem -Path $sessionsPath -Filter "*.lease" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $cutoff } |
        ForEach-Object { ConvertFrom-LLMLeaseFile -File $_ })
}

function Mount-LLMStorage {
    <#
    .SYNOPSIS
        Mounts the fixed-size LLM VHDX block storage and assigns it to the M: drive.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-AdminPrivilege)) {
        Write-Error "Administrative privileges required. Please restart PowerShell as Administrator."
        return
    }

    if (-not (Test-Path -Path $global:LLMVhdPath)) {
        Write-Error "Target VHDX file not found at: $global:LLMVhdPath"
        return
    }

    $vhd = Get-VHD -Path $global:LLMVhdPath -ErrorAction SilentlyContinue

    if ($vhd.Attached) {
        Write-Verbose "VHDX is already attached to the Windows subsystem."
    } else {
        Write-Host "Mounting LLM disk: $global:LLMVhdPath..." -ForegroundColor Green
        Mount-VHD -Path $global:LLMVhdPath -Passthru | Out-Null
        Start-Sleep -Seconds 2
    }

    $volume = Get-Volume -DriveLetter $global:LLMDriveLetter -ErrorAction SilentlyContinue
    if ($volume) {
        $controlPath = Get-LLMControlPath
        $sessionsPath = Get-LLMSessionsPath

        if (-not (Test-Path -Path $sessionsPath)) {
            New-Item -Path $sessionsPath -ItemType Directory -Force | Out-Null
        }

        Write-Host "Success: Fixed AI volume cleanly online at $global:LLMDriveLetter:\ drive!" -ForegroundColor Green
        Write-Verbose "Shared LLM control directory available at $controlPath"
    } else {
        Write-Warning "Disk attached, but failed to find drive letter $global:LLMDriveLetter`:. Check Disk Management."
    }
}

function Dismount-LLMStorage {
    <#
    .SYNOPSIS
        Dismounts the LLM VHDX block storage from the host machine safely.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if (-not (Test-AdminPrivilege)) {
        Write-Error "Administrative privileges required."
        return
    }

    $vhd = Get-VHD -Path $global:LLMVhdPath -ErrorAction SilentlyContinue

    if (-not $vhd.Attached) {
        Write-Host "Storage disk is already offline." -ForegroundColor Cyan
        return
    }

    $activeLeases = @(Get-ActiveLLMSessionLeases)
    if ($activeLeases.Count -gt 0 -and -not $Force) {
        Write-Warning "Refusing to dismount LLM storage because active shared session leases were found."
        $activeLeases | Format-Table -AutoSize | Out-Host
        Write-Warning "Exit the WSL LLM sessions first, or rerun with -Force if you intentionally want to revoke them."
        return
    }

    if ($activeLeases.Count -gt 0 -and $Force) {
        Write-Warning "Force dismount requested while active LLM session leases exist. WSL Ollama sessions may fail closed."
        $activeLeases | Format-Table -AutoSize | Out-Host
    }

    Write-Host "Safely unlinking $global:LLMVhdPath..." -ForegroundColor Yellow
    Dismount-VHD -Path $global:LLMVhdPath
    Write-Host "Disk completely dismounted." -ForegroundColor Green
}

function Get-LLMStorageStatus {
    <#
    .SYNOPSIS
        Retrieves real-time telemetry about the LLM VHDX storage system.
    #>
    [CmdletBinding()]
    param()

    $vhd = Get-VHD -Path $global:LLMVhdPath -ErrorAction SilentlyContinue
    $volume = Get-Volume -DriveLetter $global:LLMDriveLetter -ErrorAction SilentlyContinue
    $activeLeases = @(Get-ActiveLLMSessionLeases)

    [PSCustomObject]@{
        VhdPath             = $global:LLMVhdPath
        DriveLetter         = $global:LLMDriveLetter
        Attached            = [bool]$vhd.Attached
        DiskNumber          = if ($vhd.Attached) { $vhd.DiskNumber } else { $null }
        SizeGB              = if ($vhd) { [Math]::Round($vhd.Size / 1GB, 2) } else { 0 }
        FreeSpaceGB         = if ($volume) { [Math]::Round($volume.SizeRemaining / 1GB, 2) } else { 0 }
        ActiveSessionLeases = $activeLeases.Count
        ControlPath         = if ($volume) { Get-LLMControlPath } else { $null }
    }
}

# Export functions along with the custom alias
Export-ModuleMember -Function Mount-LLMStorage, Dismount-LLMStorage, Get-LLMStorageStatus, Get-ActiveLLMSessionLeases -Alias MountLLM
