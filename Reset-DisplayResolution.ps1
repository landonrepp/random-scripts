<#
.SYNOPSIS
    Queries or resets Windows display resolution and refresh rate using native Win32 APIs.

.DESCRIPTION
    Interacts directly with user32.dll (EnumDisplaySettings and ChangeDisplaySettingsEx) to
    switch monitor resolution and refresh rate without requiring third-party executables.
    Defaults to resetting the primary display (\\.\DISPLAY1) back to 3840x2160 @ 60Hz.

.PARAMETER Width
    Target horizontal resolution in pixels (default: 3840).

.PARAMETER Height
    Target vertical resolution in pixels (default: 2160).

.PARAMETER RefreshRate
    Target display refresh rate in Hz (default: 60).

.PARAMETER DeviceName
    Target display adapter name (default: \\.\DISPLAY1).

.PARAMETER QueryOnly
    Displays the current display resolution and refresh rate without modifying it.
#>

[CmdletBinding()]
param(
    [int]$Width = 3840,
    [int]$Height = 2160,
    [int]$RefreshRate = 60,
    [string]$DeviceName = "\\.\DISPLAY1",
    [switch]$QueryOnly
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Win32DisplayHelper {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    public const int ENUM_CURRENT_SETTINGS = -1;
    public const int CDS_UPDATEREGISTRY = 0x01;
    public const int DISP_CHANGE_SUCCESSFUL = 0;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public short dmLogPixels;
        public short dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    public static string GetCurrentMode(string deviceName) {
        DEVMODE dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref dm) != 0) {
            return string.Format("{0}x{1}@{2}Hz", dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency);
        }
        return "Unknown";
    }

    public static int SetResolution(string deviceName, int width, int height, int frequency) {
        DEVMODE dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref dm) == 0) {
            return -1;
        }
        dm.dmPelsWidth = width;
        dm.dmPelsHeight = height;
        dm.dmDisplayFrequency = frequency;
        dm.dmFields = 0x00080000 | 0x00100000 | 0x00400000; // DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY
        return ChangeDisplaySettingsEx(deviceName, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
    }
}
"@ -PassThru | Out-Null

$currentMode = [Win32DisplayHelper]::GetCurrentMode($DeviceName)
Write-Host "Display [$DeviceName] Current Mode: $currentMode" -ForegroundColor Cyan

if ($QueryOnly) {
    exit 0
}

$targetMode = "${Width}x${Height}@${RefreshRate}Hz"

if ($currentMode -eq $targetMode) {
    Write-Host "[OK] Display is already set to target mode ($targetMode)." -ForegroundColor Green
    exit 0
}

Write-Host "Changing display mode to $targetMode..." -ForegroundColor Yellow
$status = [Win32DisplayHelper]::SetResolution($DeviceName, $Width, $Height, $RefreshRate)

if ($status -eq 0) {
    Write-Host "[OK] Successfully set display mode to $targetMode." -ForegroundColor Green
} else {
    Write-Error "ChangeDisplaySettingsEx failed with return code: $status"
    exit $status
}
