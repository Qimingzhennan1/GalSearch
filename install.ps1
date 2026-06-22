param(
    [switch]$DesktopOnly,
    [switch]$StartMenu,
    [switch]$AllUsers
)

<#
.SYNOPSIS
    Install Gal Search MVP shortcuts.
.DESCRIPTION
    Creates shortcuts on desktop and/or Start Menu for Gal Search MVP.
    By default creates desktop shortcut only.
    Run: powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
.PARAMETER DesktopOnly
    Create shortcut only on desktop (default behavior).
.PARAMETER StartMenu
    Create shortcut in Start Menu instead of desktop.
.PARAMETER AllUsers
    Create shortcut for all users (requires admin). Only valid with -StartMenu.
#>

$AppName = 'Gal Search MVP'
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PowerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$ScriptPath = Join-Path $AppDir 'GalSearch.ps1'
$Description = 'Gal 资源搜索工具 - 搜索和浏览分享页面'

if (-not (Test-Path $ScriptPath)) {
    Write-Error "Script not found: $ScriptPath"
    Write-Error "Make sure GalSearch.ps1 is in the same folder as install.ps1"
    exit 1
}

function Create-Shortcut {
    param(
        [string]$TargetPath,
        [string]$ShortcutPath,
        [string]$Arguments = '',
        [string]$Description = '',
        [string]$IconLocation = '',
        [string]$WorkingDirectory = ''
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    if ($Arguments) { $shortcut.Arguments = $Arguments }
    if ($Description) { $shortcut.Description = $Description }
    if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
    if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
    $shortcut.WindowStyle = 7
    $shortcut.Save()
    Write-Host "  Created: $ShortcutPath"
}

# Determine shortcut locations
$locations = @()

if (-not $StartMenu -or $DesktopOnly) {
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $locations += @{
        Path = Join-Path $desktopPath "$AppName.lnk"
        Desc = 'Desktop'
    }
}

if ($StartMenu -or (-not $DesktopOnly -and -not $StartMenu)) {
    if ($AllUsers) {
        $startMenuPath = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    } else {
        $startMenuPath = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    }
    $appFolder = Join-Path $startMenuPath $AppName
    if (-not (Test-Path $appFolder)) {
        New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
    }
    $locations += @{
        Path = Join-Path $appFolder "$AppName.lnk"
        Desc = 'Start Menu'
    }
}

# Create shortcuts
Write-Host "Installing Gal Search MVP shortcuts..."
Write-Host ""

$shellArgs = "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$ScriptPath`""

foreach ($loc in $locations) {
    Create-Shortcut `
        -TargetPath $PowerShellPath `
        -Arguments $shellArgs `
        -ShortcutPath $loc.Path `
        -Description $Description `
        -WorkingDirectory $AppDir
}

Write-Host ""
Write-Host "Done! You can now launch '$AppName' from $($locations[0].Desc)."
Write-Host ""
Write-Host "To uninstall, just delete the shortcuts."
Write-Host "The app itself is portable - delete the folder to fully remove it."
