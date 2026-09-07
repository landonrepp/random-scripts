<#
.SYNOPSIS
    Configures Sunshine game stream host to automatically match the display resolution
    of connecting Moonlight clients (eliminating black bars) and restore native host
    resolution upon disconnect.

.DESCRIPTION
    Applies optimized Sunshine display device (dd_*) configurations:
    1. Sets dd_configuration_option to 'verify_only' (activates resolution matching without breaking multi-display topology).
    2. Sets dd_resolution_option to 'auto' with dd_refresh_rate_option disabled to prevent TV display mode rejection (Error 1610).
    3. Configures dd_mode_remapping for unconventional client aspect ratios (e.g. MacBook Pro 16:10 3024x1964 -> 2560x1600)
       that physical TVs/monitors cannot natively render.
    4. Enables dd_config_revert_on_disconnect with a 500ms safety buffer so the host screen automatically reverts to native 4K
       as soon as Moonlight disconnects.
    5. Injects an undo prep-command into apps.json for the 'Desktop' app as a secondary safety net.
    6. Ensures sunshine.conf is written in ASCII without Byte Order Mark (BOM) to prevent Sunshine configuration parsing failures.

.PARAMETER DisplayGuid
    The device GUID of the target display monitor. Defaults to the LG TV SSCR2 GUID ({0b690d3a-321d-5430-ab30-87045cb97ee4}).

.PARAMETER RevertDelayMs
    Delay in milliseconds before reverting display settings after client disconnection (default: 500ms).

.PARAMETER SkipServiceRestart
    Skips restarting SunshineService after applying configuration changes.

.PARAMETER DryRun
    Previews configuration changes without writing to files or restarting the service.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$DisplayGuid = "{0b690d3a-321d-5430-ab30-87045cb97ee4}",
    [int]$RevertDelayMs = 500,
    [switch]$SkipServiceRestart,
    [switch]$DryRun
)

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " Configuring Sunshine Dynamic Client Resolution Matching" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# ---------------------------------------------------------
# Check Administrator Privileges
# ---------------------------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $DryRun) {
    Write-Warning "Administrator privileges are required to modify Sunshine configuration in Program Files and restart the service."
    Write-Host "Attempting to launch an elevated PowerShell prompt..." -ForegroundColor Yellow
    try {
        $argList = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -DisplayGuid `"$DisplayGuid`" -RevertDelayMs $RevertDelayMs"
        if ($SkipServiceRestart) { $argList += " -SkipServiceRestart" }
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -ErrorAction Stop
        Write-Host "[OK] Elevated prompt launched. Please check your screen and approve the UAC prompt." -ForegroundColor Green
        exit 0
    } catch {
        Write-Host "`n[!] Could not automatically launch elevated prompt ($($_.Exception.Message))." -ForegroundColor Red
        Write-Host "    Please re-run this script in an elevated Administrator terminal:" -ForegroundColor Yellow
        Write-Host "    powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"`n" -ForegroundColor Cyan
        exit 1
    }
}

$sunshineDir = "C:\Program Files\Sunshine"
$configDir   = Join-Path $sunshineDir "config"
$confFile    = Join-Path $configDir "sunshine.conf"
$appsFile    = Join-Path $configDir "apps.json"

if (-not (Test-Path $configDir)) {
    Write-Error "Sunshine config directory not found at: $configDir"
    exit 1
}

# ---------------------------------------------------------
# Define Desired Configuration Settings
# ---------------------------------------------------------
$modeRemappingJson = '{"mixed":[],"resolution_only":[{"requested_resolution":"3024x1964","final_resolution":"2560x1600"},{"requested_resolution":"3456x2234","final_resolution":"2560x1600"},{"requested_resolution":"2560x1664","final_resolution":"2560x1600"},{"requested_resolution":"2880x1864","final_resolution":"2560x1600"},{"requested_resolution":"2388x1668","final_resolution":"2048x1536"},{"requested_resolution":"2732x2048","final_resolution":"2048x1536"}],"refresh_rate_only":[]}'

$configSettings = [ordered]@{
    "output_name"                    = $DisplayGuid
    "dd_configuration_option"        = "verify_only"
    "dd_resolution_option"           = "auto"
    "dd_refresh_rate_option"         = "disabled"
    "dd_config_revert_on_disconnect" = "enabled"
    "dd_config_revert_delay"         = "$RevertDelayMs"
    "dd_mode_remapping"              = $modeRemappingJson
}

# ---------------------------------------------------------
# Process sunshine.conf
# ---------------------------------------------------------
Write-Host "`n[1/3] Preparing sunshine.conf configuration..." -ForegroundColor Yellow

$existingLines = @()
if (Test-Path $confFile) {
    $existingLines = Get-Content $confFile -Encoding Ascii -ErrorAction SilentlyContinue
}

$newLines = @()
$keysProcessed = @{}

foreach ($line in $existingLines) {
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("#") -or [string]::IsNullOrWhiteSpace($trimmed)) {
        $newLines += $line
        continue
    }

    if ($trimmed -match '^([^=]+)=(.*)$') {
        $key = $matches[1].Trim()
        if ($configSettings.Contains($key)) {
            $newLines += "$key = $($configSettings[$key])"
            $keysProcessed[$key] = $true
        } else {
            $newLines += $line
        }
    } else {
        $newLines += $line
    }
}

foreach ($key in $configSettings.Keys) {
    if (-not $keysProcessed.ContainsKey($key)) {
        $newLines += "$key = $($configSettings[$key])"
    }
}

if ($DryRun) {
    Write-Host "[DryRun] Would write the following lines to ${confFile}:" -ForegroundColor Cyan
    $newLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
} else {
    # CRITICAL: Sunshine crashes or ignores keys if written with a UTF-8 BOM
    [System.IO.File]::WriteAllLines($confFile, $newLines, [System.Text.Encoding]::ASCII)
    Write-Host "[OK] sunshine.conf updated successfully (ASCII, no BOM)." -ForegroundColor Green
    $newLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}

# ---------------------------------------------------------
# Update apps.json Desktop prep-cmd undo hook
# ---------------------------------------------------------
Write-Host "`n[2/3] Configuring Desktop session exit hook in apps.json..." -ForegroundColor Yellow

$resetScriptPath = Join-Path $PSScriptRoot "Reset-DisplayResolution.ps1"
if (-not (Test-Path $resetScriptPath)) {
    $resetScriptPath = "C:\Users\lando\reset-tv-resolution.ps1"
}

if (Test-Path $appsFile) {
    try {
        $appsContent = Get-Content $appsFile -Raw | ConvertFrom-Json
        $desktop = $appsContent.apps | Where-Object { $_.name -eq "Desktop" }
        if ($desktop) {
            $undoCmd = "powershell.exe -ExecutionPolicy Bypass -File `"$resetScriptPath`""
            $prepCmdObj = @(
                [PSCustomObject]@{
                    do   = ""
                    undo = $undoCmd
                }
            )

            if ($DryRun) {
                Write-Host "[DryRun] Would update 'Desktop' app undo command to: $undoCmd" -ForegroundColor Cyan
            } else {
                $desktop | Add-Member -NotePropertyName "prep-cmd" -NotePropertyValue $prepCmdObj -Force
                $updatedJson = $appsContent | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($appsFile, $updatedJson, [System.Text.Encoding]::ASCII)
                Write-Host "[OK] apps.json updated with Desktop session undo hook." -ForegroundColor Green
            }
        }
    } catch {
        Write-Warning "Could not update apps.json: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------
# Restart Sunshine Service
# ---------------------------------------------------------
Write-Host "`n[3/3] Managing SunshineService..." -ForegroundColor Yellow

$service = Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue
if ($service) {
    if ($DryRun) {
        Write-Host "[DryRun] Would restart SunshineService." -ForegroundColor Cyan
    } elseif ($SkipServiceRestart) {
        Write-Host "[Skip] Skipping service restart as requested (-SkipServiceRestart)." -ForegroundColor Yellow
    } else {
        Write-Host "Restarting SunshineService..." -ForegroundColor Yellow
        Restart-Service -Name "SunshineService" -Force
        Start-Sleep -Seconds 2
        $service.Refresh()
        if ($service.Status -eq 'Running') {
            Write-Host "[OK] SunshineService restarted and running." -ForegroundColor Green
        } else {
            Write-Warning "SunshineService is in status: $($service.Status)"
        }
    }
} else {
    Write-Warning "SunshineService was not found on this system. If Sunshine runs as an executable, please restart it manually."
}

Write-Host "`n======================================================" -ForegroundColor Cyan
Write-Host " Sunshine Resolution Matching Configuration Complete" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
