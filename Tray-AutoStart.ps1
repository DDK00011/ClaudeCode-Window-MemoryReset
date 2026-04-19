#Requires -Version 5.1
<#
.SYNOPSIS
    Toggle MemoryReset Tray registration/unregistration in Windows Startup.

.DESCRIPTION
    %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ Create/delete .lnk shortcut.
    Administrator privileges not required (registers only in user Startup).

.PARAMETER Remove
    Unregister (default is register).

.EXAMPLE
    .\Tray-AutoStart.ps1            # Register
    .\Tray-AutoStart.ps1 -Remove    # Unregister
#>

[CmdletBinding()]
param(
    [switch]$Remove
)

$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'MemoryReset-Tray.lnk'
$trayBat = Join-Path $PSScriptRoot 'Tray.bat'

if ($Remove) {
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        Write-Host "[OK] Unregistered from Startup: $shortcutPath" -ForegroundColor Green
    } else {
        Write-Host "[i] Not registered in Startup." -ForegroundColor DarkGray
    }
    exit 0
}

# Register
if (-not (Test-Path $trayBat)) {
    Write-Host "[X] Cannot find Tray.bat in the same folder: $trayBat" -ForegroundColor Red
    exit 1
}

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $shortcut = $WshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath        = $trayBat
    $shortcut.WorkingDirectory  = $PSScriptRoot
    $shortcut.WindowStyle       = 7    # 7 = Minimized (hide even a brief console display)
    $shortcut.Description       = "Memory Reset system tray daemon — memory threshold alert"
    $shortcut.Save()
    Write-Host "[OK] Startup registration complete: $shortcutPath" -ForegroundColor Green
    Write-Host "    → System tray daemon starts automatically on next Windows boot" -ForegroundColor DarkGray
    Write-Host "    → To unregister: .\Tray-AutoStart.ps1 -Remove" -ForegroundColor DarkGray
} catch {
    Write-Host "[X] Registration failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
