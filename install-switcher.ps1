# install.ps1 - installs 007 Wall Switcher for the current user.
# Copies the app to %LOCALAPPDATA%\007WallSwitcher and adds Desktop + Start Menu shortcuts.
# Works from the extracted zip, or online in one line (no Smart App Control block):
#   irm https://raw.githubusercontent.com/6idriss/wallpapers/main/install-switcher.ps1 | iex
# Uninstall:  powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall

param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$repoRaw    = 'https://raw.githubusercontent.com/6idriss/wallpapers/main'
$installDir = Join-Path $env:LOCALAPPDATA '007WallSwitcher'
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '007 Wall Switcher.lnk'
$startLnk   = Join-Path ([Environment]::GetFolderPath('Programs')) '007 Wall Switcher.lnk'

# Close a running copy first.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*WallSwitcher.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if ($Uninstall) {
    Remove-Item -LiteralPath $desktopLnk, $startLnk -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name '007 Wall Switcher' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '007 Wall Switcher uninstalled. Your pictures were not touched.' -ForegroundColor Green
    return
}

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
# Use the local copy if this runs from an extracted zip, otherwise download it.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
foreach ($file in 'WallSwitcher.ps1', '007.ico') {
    $dest  = Join-Path $installDir $file
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot $file } else { $null }
    if ($local -and (Test-Path -LiteralPath $local)) {
        Copy-Item -LiteralPath $local -Destination $dest -Force
    } else {
        Invoke-WebRequest -Uri "$repoRaw/$file" -OutFile $dest -UseBasicParsing
    }
    Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue
}

$shell = New-Object -ComObject WScript.Shell
foreach ($lnk in $desktopLnk, $startLnk) {
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = 'powershell.exe'
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installDir\WallSwitcher.ps1`""
    $s.IconLocation = "$installDir\007.ico"
    $s.WorkingDirectory = $installDir
    $s.Description = '007 Wall Switcher'
    $s.Save()
}
Write-Host '007 Wall Switcher installed. Open it from the Desktop or Start Menu.' -ForegroundColor Green
Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installDir\WallSwitcher.ps1`""
