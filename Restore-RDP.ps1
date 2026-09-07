<#
.SYNOPSIS
    Reverts or repairs Windows Remote Desktop (RDP) settings configured by Optimize-RDP.ps1.

.DESCRIPTION
    Fixes the RDP freeze issue caused by the Windows 11 UDP transport bug and AVC 4:4:4 encoding.
    Optionally rolls back all registry policies to clean Windows defaults.

.PARAMETER ForceTCPOnly
    Sets SelectTransport = 1 (TCP only) instead of deleting the key. This prevents the
    Windows 11 UDP freeze bug while preserving other host settings.

.PARAMETER ResetAll
    Default mode. Removes all registry keys added by Optimize-RDP.ps1 and restores Windows defaults.

.PARAMETER SkipServiceRestart
    Skips restarting the Remote Desktop Service (TermService).
#>

[CmdletBinding(DefaultParameterSetName="ResetAll")]
param(
    [Parameter(ParameterSetName="ResetAll")]
    [switch]$ResetAll = $true,

    [Parameter(ParameterSetName="ForceTCPOnly")]
    [switch]$ForceTCPOnly,

    [switch]$SkipServiceRestart
)

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Restoring / Repairing Remote Desktop (RDP) Settings" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# ---------------------------------------------------------
# Check Administrator Privileges & Self-Elevate
# ---------------------------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Warning "Administrator privileges are required to modify system registry."
    Write-Host "Attempting to launch an elevated prompt..." -ForegroundColor Yellow
    try {
        $argList = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($ForceTCPOnly) { $argList += " -ForceTCPOnly" }
        if ($SkipServiceRestart) { $argList += " -SkipServiceRestart" }
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -ErrorAction Stop
        Write-Host "[OK] Elevated prompt launched. Please approve the UAC prompt." -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "`n[!] Could not automatically elevate ($($_.Exception.Message))." -ForegroundColor Red
        Write-Host "    Please run this script from an Administrator PowerShell prompt." -ForegroundColor Yellow
        exit 1
    }
}

$rdpConnPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
$winStationsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations"

if ($ForceTCPOnly) {
    Write-Host "`nMode: Fixing Freeze by Forcing TCP-Only (Disabling UDP)..." -ForegroundColor Yellow

    # Force TCP Only (SelectTransport = 1) to eliminate the Windows 11 UDP freeze bug
    Set-ItemProperty -Path $rdpConnPath -Name "SelectTransport" -Value 1 -Type DWord -Force
    Write-Host " [FIX] Set SelectTransport = 1 (TCP Only - bypasses UDP freeze)" -ForegroundColor Green

    # Remove problematic GPU/AVC policies that cause NVIDIA H.264 Encoder MFT to freeze the graphics stream
    $gpuPolicies = @("AVC444ModePreferred", "AVCHardwareEncodePreferred", "bEnumerateHWBeforeSW")
    foreach ($policy in $gpuPolicies) {
        Remove-ItemProperty -Path $rdpConnPath -Name $policy -ErrorAction SilentlyContinue
        Write-Host " [REMOVED] $policy (fixed GPU encoder freeze)" -ForegroundColor Green
    }

} else {
    Write-Host "`nMode: Reverting all custom policies to Windows Defaults..." -ForegroundColor Yellow

    # Remove Terminal Services policies
    $policiesToRemove = @("SelectTransport", "AVC444ModePreferred", "AVCHardwareEncodePreferred", "bEnumerateHWBeforeSW")
    foreach ($name in $policiesToRemove) {
        if (Test-Path $rdpConnPath) {
            $val = Get-ItemProperty -Path $rdpConnPath -Name $name -ErrorAction SilentlyContinue
            if ($null -ne $val) {
                Remove-ItemProperty -Path $rdpConnPath -Name $name -Force -ErrorAction SilentlyContinue
                Write-Host " [REMOVED] $name from $rdpConnPath" -ForegroundColor Green
            }
        }
    }

    # Remove DWMFRAMEINTERVAL
    if (Test-Path $winStationsPath) {
        $dwm = Get-ItemProperty -Path $winStationsPath -Name "DWMFRAMEINTERVAL" -ErrorAction SilentlyContinue
        if ($null -ne $dwm) {
            Remove-ItemProperty -Path $winStationsPath -Name "DWMFRAMEINTERVAL" -Force -ErrorAction SilentlyContinue
            Write-Host " [REMOVED] DWMFRAMEINTERVAL (restored default 30 FPS cap)" -ForegroundColor Green
        }
    }

    # Disable UDP firewall rule
    try {
        Disable-NetFirewallRule -Name "RemoteDesktop-UserMode-In-UDP" -ErrorAction SilentlyContinue
        Write-Host " [RESTORED] Remote Desktop UDP firewall rule disabled" -ForegroundColor Green
    } catch {
        # ignore if rule missing
    }
}

# Refresh Group Policy
Write-Host "`nApplying group policy refresh..." -ForegroundColor Cyan
try {
    gpupdate /target:computer /force | Out-Null
    Write-Host " [OK] Machine group policy refreshed" -ForegroundColor Green
} catch {
    Write-Warning "gpupdate encountered an issue: $($_.Exception.Message)"
}

# Service restart
$inRdpSession = ($env:SESSIONNAME -like "RDP*") -or ($null -ne $env:CLIENTNAME -and $env:CLIENTNAME -ne "")

if ($SkipServiceRestart) {
    Write-Host "`n[i] Service restart skipped by parameter (-SkipServiceRestart)." -ForegroundColor Yellow
} elseif ($inRdpSession) {
    Write-Warning "`nYou are currently inside an active RDP session ($env:SESSIONNAME)."
    Write-Warning "Restarting TermService now would disconnect this session."
    Write-Host "Changes will take effect on next reboot or service restart." -ForegroundColor Yellow
} else {
    Write-Host "`nRestarting Remote Desktop Service (TermService)..." -ForegroundColor Yellow
    try {
        Restart-Service -Name "TermService" -Force -ErrorAction Stop
        Write-Host " [OK] TermService successfully restarted" -ForegroundColor Green
    } catch {
        Write-Warning "Could not restart TermService ($($_.Exception.Message)). A reboot is recommended."
    }
}

Write-Host "`nOperation complete! Reconnect via RDP to verify." -ForegroundColor Cyan
