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
