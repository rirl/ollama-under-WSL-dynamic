<#
.MODULE NAME
    LLMStorage
.SYNOPSIS
    A PowerShell module to manage fixed-size VHDX storage mappings for WSL LLM development.
#>

$global:LLMVhdPath = "D:\LocalLLM\models_storage.vhdx"
$global:LLMDriveLetter = "M"

# Define the custom shorthand alias
Set-Alias -Name MountLLM -Value Mount-LLMStorage -Description "Shorthand to mount the LLM fixed VHDX"

function Test-AdminPrivilege {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
        Write-Host "Success: Fixed AI volume cleanly online at $global:LLMDriveLetter:\ drive!" -ForegroundColor Green
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
    param()

    if (-not (Test-AdminPrivilege)) {
        Write-Error "Administrative privileges required."
        return
    }

    $vhd = Get-VHD -Path $global:LLMVhdPath -ErrorAction SilentlyContinue

    if ($vhd.Attached) {
        Write-Host "Safely unlinking $global:LLMVhdPath..." -ForegroundColor Yellow
        Dismount-VHD -Path $global:LLMVhdPath
        Write-Host "Disk completely dismounted." -ForegroundColor Green
    } else {
        Write-Host "Storage disk is already offline." -ForegroundColor Cyan
    }
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

    [PSCustomObject]@{
        VhdPath     = $global:LLMVhdPath
        DriveLetter = $global:LLMDriveLetter
        Attached    = [bool]$vhd.Attached
        DiskNumber  = if ($vhd.Attached) { $vhd.DiskNumber } else { $null }
        SizeGB      = [Math]::Round($vhd.Size / 1GB, 2)
        FreeSpaceGB = if ($volume) { [Math]::Round($volume.SizeRemaining / 1GB, 2) } else { 0 }
    }
}

# Export functions along with the custom alias
Export-ModuleMember -Function Mount-LLMStorage, Dismount-LLMStorage, Get-LLMStorageStatus -Alias MountLLM
