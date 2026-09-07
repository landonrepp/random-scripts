# random-scripts

A collection of utility, performance, and automation scripts.

## Scripts

### 1. `Optimize-RDP.ps1`
Optimizes Windows Remote Desktop (RDP) Host settings for high-frame-rate and reliable streaming:
- **Configurable Frame Rate Cap**: Configures DWM to allow 60 FPS (default) or 120 FPS (`-TargetFPS 60` or `-TargetFPS 120`) instead of the default 30 FPS cap.
- **TCP-Only Transport**: Forces TCP mode (`SelectTransport = 1`) and disables UDP on both host and client, preventing the widespread Windows 11 RDP UDP freeze/stalling bug.
- **Safe Graphics Pipeline**: Cleans up problematic AVC 4:4:4 and forced GPU enumeration policies that cause `NVIDIA H.264 Encoder MFT` to stall the video stream on client handshakes.
- **DryRun Support**: Run with `-DryRun` to inspect pending changes without modifying registry keys.
- **Safe Service Restart**: Automatically skips `TermService` restarts when executed from within an active RDP session.

#### Usage:
```powershell
# Apply 60 FPS and TCP stability optimizations (auto-prompts for UAC elevation)
powershell -ExecutionPolicy Bypass -File .\Optimize-RDP.ps1

# Test with 120 FPS cap
powershell -ExecutionPolicy Bypass -File .\Optimize-RDP.ps1 -TargetFPS 120

# Audit current configuration without making changes
powershell -ExecutionPolicy Bypass -File .\Optimize-RDP.ps1 -DryRun
```

### 2. `Restore-RDP.ps1`
Restores standard Windows Remote Desktop settings or resets policies back to clean Windows defaults:
```powershell
# Reset all custom RDP policies back to Windows defaults
powershell -ExecutionPolicy Bypass -File .\Restore-RDP.ps1 -ResetAll

# Keep TCP-only mode but remove GPU encoder overrides
powershell -ExecutionPolicy Bypass -File .\Restore-RDP.ps1 -ForceTCPOnly
```

### 3. `Configure-Sunshine-Resolution.ps1`
Configures the Sunshine game stream host to dynamically match the display resolution and aspect ratio of connecting Moonlight clients (eliminating black bars) and restore native host resolution upon disconnect:
- **Aspect Ratio Remapping**: Automatically maps non-standard client resolutions (e.g., MacBook Pro 16:10 `3024x1964`, `2560x1664` -> `2560x1600`) to supported display modelines so physical TVs/monitors that reject arbitrary custom resolutions do not fail validation (Error 1610).
- **Auto-Revert on Disconnect**: Enables `dd_config_revert_on_disconnect` with a 500ms safety buffer (`dd_config_revert_delay = 500`) to restore native 4K (`3840x2160 @ 60Hz`) as soon as Moonlight closes or disconnects.
- **Fail-Safe Session Undo Hook**: Injects an `undo` prep-command in `apps.json` for the Desktop app to enforce resolution recovery on session exit.
- **BOM-Safe Configuration**: Guarantees `sunshine.conf` is written in ASCII without Byte Order Marks (BOM), preventing Sunshine configuration parsing failures.
- **DryRun Support**: Supports `-DryRun` to inspect proposed configuration changes before applying them.

#### Usage:
```powershell
# Apply resolution matching and auto-revert (auto-prompts for UAC elevation)
powershell -ExecutionPolicy Bypass -File .\Configure-Sunshine-Resolution.ps1

# Preview configuration changes without writing files or restarting SunshineService
powershell -ExecutionPolicy Bypass -File .\Configure-Sunshine-Resolution.ps1 -DryRun
```

### 4. `Reset-DisplayResolution.ps1`
Queries or resets Windows display resolution and refresh rate directly via native Win32 `user32.dll` APIs (`EnumDisplaySettings` and `ChangeDisplaySettingsEx`) without requiring third-party tools:
- **Native Win32 Integration**: Instantly changes display mode and persists it to the user registry.
- **Configurable Mode**: Defaults to resetting `\\.\DISPLAY1` to `3840x2160 @ 60Hz`, with configurable `-Width`, `-Height`, `-RefreshRate`, and `-DeviceName`.

#### Usage:
```powershell
# Query current display resolution
powershell -ExecutionPolicy Bypass -File .\Reset-DisplayResolution.ps1 -QueryOnly

# Reset primary monitor to 4K 60Hz
powershell -ExecutionPolicy Bypass -File .\Reset-DisplayResolution.ps1

# Set custom resolution and refresh rate
powershell -ExecutionPolicy Bypass -File .\Reset-DisplayResolution.ps1 -Width 2560 -Height 1600 -RefreshRate 60
```

