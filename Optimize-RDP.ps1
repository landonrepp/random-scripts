<#
.SYNOPSIS
    Optimizes Windows Remote Desktop (RDP) Host settings for high-frame-rate (60 FPS),
    TCP-only transport (disabling UDP to prevent connection freezes), and H.264/AVC GPU hardware acceleration.

.DESCRIPTION
    Applies official Windows Group Policy & Terminal Server registry configurations:
    1. DWMFRAMEINTERVAL = 15 (~60-66 FPS cap instead of default 30 FPS).
    2. SelectTransport = 1 (Enforces TCP-only transport, disabling UDP to prevent freezes).
    3. Cleans up problematic AVC 4:4:4 and GPU policies that cause NVIDIA encoder stalls.
    4. Disables inbound UDP 3389 in Windows Firewall and disables client-side UDP.
    5. Handles TermService restart safely without abruptly severing active RDP sessions.

.PARAMETER SkipServiceRestart
    Skips restarting the Remote Desktop Service (TermService). Recommended when running
    from an active RDP session.

.PARAMETER DryRun
    Audits the current configuration and reports what would change without modifying anything.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidateSet(30, 60, 120)]
    [int]$TargetFPS = 60,

    [switch]$SkipServiceRestart,
    [switch]$DryRun
)

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Configuring Remote Desktop Host Performance Settings" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# ---------------------------------------------------------
# Check Administrator Privileges
# ---------------------------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $DryRun) {
    Write-Warning "Administrator privileges are required to modify system registry and firewall policies."
    Write-Host "Attempting to launch an elevated PowerShell prompt..." -ForegroundColor Yellow
    try {
        $argList = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -TargetFPS $TargetFPS"
        if ($SkipServiceRestart) { $argList += " -SkipServiceRestart" }
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -ErrorAction Stop
        Write-Host "[OK] Elevated prompt launched. Please check your screen and approve the UAC prompt." -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "`n[!] Could not automatically launch elevated prompt from this session ($($_.Exception.Message))." -ForegroundColor Red
        Write-Host "    To apply these changes, please run the command below in an Administrator terminal:" -ForegroundColor Yellow
        Write-Host "`n    powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"`n" -ForegroundColor Cyan
        exit 1
    }
}

# ---------------------------------------------------------
# Helper Function: Idempotent Registry DWORD Writer
# ---------------------------------------------------------
function Set-RegistryDword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][int]$Value,
        [Parameter(Mandatory=$true)][string]$Description,
        [switch]$AuditOnly
    )

    $currentValue = $null
    if (Test-Path $Path) {
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $prop -and $prop.PSObject.Properties[$Name]) {
            $currentValue = [int]$prop.$Name
        }
    }

    if ($null -ne $currentValue -and $currentValue -eq $Value) {
        Write-Host " [EXISTS] $Description ($Name = $Value)" -ForegroundColor DarkGray
        return
    }

    if ($AuditOnly) {
        $currentDisplay = if ($null -ne $currentValue) { $currentValue } else { "<Not Set>" }
        Write-Host " [NEEDED] $Description ($($Name): current=$currentDisplay, desired=$Value)" -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord -Force
    Write-Host " [UPDATE] $Description ($Name = $Value)" -ForegroundColor Green
}

# ---------------------------------------------------------
# 1. Frame Rate Cap (Configurable: 30, 60, or 120 FPS)
# ---------------------------------------------------------
$winStationsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations"
$intervalMs = switch ($TargetFPS) {
    120 { 8 }   # ~125 FPS cap
    60  { 15 }  # ~66 FPS cap
    30  { 33 }  # ~30 FPS default cap
    Default { 15 }
}
Set-RegistryDword -Path $winStationsPath -Name "DWMFRAMEINTERVAL" -Value $intervalMs -Description "Configured $TargetFPS FPS cap (interval = ${intervalMs}ms)" -AuditOnly:$DryRun

# ---------------------------------------------------------
# 2. Transport Protocol & Firewall (Disable UDP / Force TCP Only)
# ---------------------------------------------------------
$rdpConnPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
$rdpClientPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client"

# SelectTransport = 1 forces TCP-only mode on the host (disables UDP to fix Windows 11 RDP freeze bug)
Set-RegistryDword -Path $rdpConnPath -Name "SelectTransport" -Value 1 -Description "Forced TCP-only transport (disabled UDP on host)" -AuditOnly:$DryRun

# fClientDisableUDP = 1 disables UDP on the client side
Set-RegistryDword -Path $rdpClientPath -Name "fClientDisableUDP" -Value 1 -Description "Disabled UDP on RDP Client" -AuditOnly:$DryRun

# Disable UDP firewall rule
try {
    $udpRule = Get-NetFirewallRule -Name "RemoteDesktop-UserMode-In-UDP" -ErrorAction SilentlyContinue
    if ($null -ne $udpRule) {
        $isEnabled = ($udpRule.Enabled -eq [Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetSecurity.Enabled]::True -or $udpRule.Enabled -eq 'True' -or $udpRule.Enabled -eq 1)
        if (-not $isEnabled) {
            Write-Host " [EXISTS] Remote Desktop UDP firewall rule is already disabled" -ForegroundColor DarkGray
        } elseif ($DryRun) {
            Write-Host " [NEEDED] Remote Desktop UDP firewall rule needs to be disabled" -ForegroundColor Yellow
        } else {
            Disable-NetFirewallRule -Name "RemoteDesktop-UserMode-In-UDP" -ErrorAction Stop
            Write-Host " [UPDATE] Disabled Remote Desktop UDP firewall rule" -ForegroundColor Green
        }
    } else {
        Write-Host " [INFO] Remote Desktop UDP firewall rule not found or already absent" -ForegroundColor DarkGray
    }
} catch {
    Write-Warning "Could not update firewall rules: $($_.Exception.Message)"
}

# ---------------------------------------------------------
# 3. Clean up problematic GPU / AVC Encoding Policies
# ---------------------------------------------------------
# AVC 4:4:4, AVCHardwareEncodePreferred, and bEnumerateHWBeforeSW cause NVIDIA H.264
# Encoder MFT to stall/freeze the graphics pipeline (especially with macOS, iOS, or non-enterprise GPUs).
$badPolicies = @("AVC444ModePreferred", "AVCHardwareEncodePreferred", "bEnumerateHWBeforeSW")
foreach ($policy in $badPolicies) {
    if (Test-Path $rdpConnPath) {
        $val = Get-ItemProperty -Path $rdpConnPath -Name $policy -ErrorAction SilentlyContinue
        if ($null -ne $val -and $null -ne $val.$policy) {
            if ($DryRun) {
                Write-Host " [NEEDED] Remove problematic GPU policy $policy" -ForegroundColor Yellow
            } else {
                Remove-ItemProperty -Path $rdpConnPath -Name $policy -Force -ErrorAction SilentlyContinue
                Write-Host " [REMOVED] Problematic GPU policy $policy (resolved encoder stall)" -ForegroundColor Green
            }
        }
    }
}

# ---------------------------------------------------------
# 4. Refresh Group Policy (Skipped in DryRun)
# ---------------------------------------------------------
if (-not $DryRun) {
    Write-Host "`nApplying group policy updates..." -ForegroundColor Cyan
    try {
        gpupdate /target:computer /force | Out-Null
        Write-Host " [OK] Machine group policy refreshed" -ForegroundColor Green
    } catch {
        Write-Warning "Group policy refresh reported an issue: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------
# 5. Service Restart / Active Session Safeguard
# ---------------------------------------------------------
$inRdpSession = ($env:SESSIONNAME -like "RDP*") -or ($null -ne $env:CLIENTNAME -and $env:CLIENTNAME -ne "")

if ($DryRun) {
    Write-Host "`n[DryRun Complete] No changes were written. Run without -DryRun to apply." -ForegroundColor Cyan
    return
}

if ($SkipServiceRestart) {
    Write-Host "`n[i] Service restart skipped by parameter (-SkipServiceRestart)." -ForegroundColor Yellow
    Write-Host "    A system reboot is recommended to apply all GPU and display changes." -ForegroundColor Yellow
} elseif ($inRdpSession) {
    Write-Warning "`nYou are currently running this script inside an active RDP session ($env:SESSIONNAME)."
    Write-Warning "Restarting TermService now will immediately disconnect your session."
    Write-Host "A system reboot is recommended to guarantee all changes take effect." -ForegroundColor Yellow
} else {
    Write-Host "`nRestarting Remote Desktop Service (TermService)..." -ForegroundColor Yellow
    try {
        Restart-Service -Name "TermService" -Force -ErrorAction Stop
        Write-Host " [OK] TermService successfully restarted" -ForegroundColor Green
    } catch {
        Write-Warning "Could not restart TermService ($($_.Exception.Message)). A reboot is recommended."
    }
}

Write-Host "`nSetup complete! Reconnect via the Windows App or Remote Desktop Client to test latency and frame rates." -ForegroundColor Cyan
