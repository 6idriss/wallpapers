# WallSwitcher.ps1 - 007 Wall Switcher: a wallpaper library and auto-changer for Windows.
# Add your wallpapers, click one to set it, or let it change on a timer.
#
# Usage:
#   WallSwitcher.ps1         open the app
#   WallSwitcher.ps1 -Tray   start hidden in the tray (used by "Start with Windows")

param([switch]$Tray)

$AppVersion = '1.1.0'
$AppName    = '007 Wall Switcher'
$ShopUrl    = 'https://6idriss.github.io/wallpapers/#switcher'
$PacksUrl   = 'https://6idriss.github.io/wallpapers/#shop'
$DiscordUrl = 'https://discord.gg/FjSraGbJPa'
$TrialDays  = 3

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class W007 {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SystemParametersInfo(int action, int param, string value, int flags);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, int mods, int vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    // Dark title bar and rounded corners on Windows 10/11. Ignored where not supported.
    public static void DarkFrame(IntPtr hwnd) {
        int on = 1, round = 2;
        try { DwmSetWindowAttribute(hwnd, 20, ref on, 4); } catch { }
        try { DwmSetWindowAttribute(hwnd, 19, ref on, 4); } catch { }
        try { DwmSetWindowAttribute(hwnd, 33, ref round, 4); } catch { }
    }
}

[StructLayout(LayoutKind.Sequential)]
public struct WRect { public int Left, Top, Right, Bottom; }

[ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDesktopWallpaper {
    void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
    uint GetMonitorDevicePathCount();
    WRect GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    void SetBackgroundColor(uint color);
    uint GetBackgroundColor();
    void SetPosition(int position);
    int GetPosition();
}

[ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")]
public class DesktopWallpaperClass { }

public static class Desk {
    static IDesktopWallpaper W() { return (IDesktopWallpaper)new DesktopWallpaperClass(); }
    public static int Count() { return (int)W().GetMonitorDevicePathCount(); }
    public static string Id(int i) { return W().GetMonitorDevicePathAt((uint)i); }
    public static WRect Rect(string id) { return W().GetMonitorRECT(id); }
    public static void Set(string id, string path) { W().SetWallpaper(id, path); }
    public static void Position(int p) { W().SetPosition(p); }
}

public class HotkeyWindow : NativeWindow, IDisposable {
    public event EventHandler Pressed;
    public HotkeyWindow() { CreateHandle(new CreateParams()); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) { Pressed(this, EventArgs.Empty); }
        base.WndProc(ref m);
    }
    public void Dispose() { DestroyHandle(); }
}
"@

# ---------- Single instance ----------
$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\007WallSwitcher', [ref]$created)
if (-not $created) {
    [System.Windows.Forms.MessageBox]::Show("$AppName is already running. Look for its icon in the tray, next to the clock.", $AppName) | Out-Null
    exit
}

# ---------- Paths, log and settings ----------
$DataDir      = Join-Path $env:APPDATA '007WallSwitcher'
$ThumbDir     = Join-Path $DataDir 'thumbs'
$SettingsFile = Join-Path $DataDir 'settings.json'
$LogFile      = Join-Path $DataDir 'log.txt'
New-Item -ItemType Directory -Force -Path $ThumbDir | Out-Null
$ImageExt = @('.jpg', '.jpeg', '.jfif', '.png', '.bmp')

function Write-Log([string]$text) {
    try {
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 512KB) { Remove-Item -LiteralPath $LogFile -Force }
        Add-Content -LiteralPath $LogFile -Value "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  $text"
    } catch { }
}

# Runs a block and logs any error instead of letting the app crash.
function Invoke-Safe([scriptblock]$block, [string]$what = 'action') {
    try { & $block } catch { Write-Log "$what failed: $($_.Exception.Message)" }
}

function New-Settings {
    [pscustomobject]@{
        Library = @(); Interval = 30; AutoChange = $true; Shuffle = $true; Fit = 'Fill'
        TimeOfDay = $false; Morning = ''; Day = ''; Evening = ''; Night = ''
        Current = ''; Key = ''; Startup = $false; Screen = 0; EachScreen = $false; LockScreen = $false; Hotkey = $true
    }
}

function Load-Settings {
    $s = New-Settings
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $saved = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($s.PSObject.Properties[$p.Name] -and $null -ne $p.Value) { $s.($p.Name) = $p.Value }
            }
        } catch { Write-Log "Settings file was damaged and has been reset: $($_.Exception.Message)" }
    }
    $s.Library = @($s.Library | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if ([int]$s.Interval -lt 1) { $s.Interval = 30 }
    return $s
}

function Save-Settings {
    try {
        $tmp = "$SettingsFile.tmp"
        $script:S | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $SettingsFile -Force
    } catch { Write-Log "Could not save settings: $($_.Exception.Message)" }
}

$script:S = Load-Settings

# ---------- License ----------
# Keys look like 007W-ABCD-EFGH-WXYZ. The last group is a checksum of the first two.
$LicenseSecret = '616c4353c0071c717fd2a74a3d99917aed7a18c09a77496a'

function ConvertTo-Base32([byte[]]$bytes) {
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bits = 0; $value = 0; $out = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        $value = ($value -shl 8) -bor $b; $bits += 8
        while ($bits -ge 5) { [void]$out.Append($alphabet[($value -shr ($bits - 5)) -band 31]); $bits -= 5 }
        $value = $value -band 0xFF
    }
    return $out.ToString()
}

function Get-KeyCheck([string]$body) {
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [Text.Encoding]::UTF8.GetBytes($LicenseSecret)
    $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("007W$body"))
    return (ConvertTo-Base32 $hash).Substring(0, 4)
}

function Test-Key([string]$key) {
    if (-not $key) { return $false }
    $k = ($key.ToUpper() -replace '\s', '')
    if ($k -notmatch '^007W-([A-Z2-7]{4})-([A-Z2-7]{4})-([A-Z2-7]{4})$') { return $false }
    return ((Get-KeyCheck ($Matches[1] + $Matches[2])) -eq $Matches[3])
}

function Get-TrialLeft {
    try {
        $reg = 'HKCU:\Software\007WallSwitcher'
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
        $first = (Get-ItemProperty -Path $reg -Name FirstRun -ErrorAction SilentlyContinue).FirstRun
        if (-not $first) { $first = (Get-Date).ToUniversalTime().Ticks.ToString(); Set-ItemProperty -Path $reg -Name FirstRun -Value $first }
        $used = ((Get-Date).ToUniversalTime() - [datetime]::new([long]$first, 'Utc')).TotalDays
        return [int][math]::Max(0, [math]::Ceiling($TrialDays - $used))
    } catch { return 0 }
}

function Test-Licensed { return (Test-Key $script:S.Key) }
function Test-Unlocked { return ((Test-Licensed) -or ((Get-TrialLeft) -gt 0)) }

# ---------- Wallpaper ----------
# Fit: registry values for the classic method, plus the IDesktopWallpaper position number.
$FitModes = [ordered]@{ Fill = @(10, 0, 4); Fit = @(6, 0, 3); Stretch = @(2, 0, 2); Center = @(0, 0, 0); Tile = @(0, 1, 1); Span = @(22, 0, 5) }

function Get-Screens {
    $list = @()
    try {
        $n = [Desk]::Count()
        for ($i = 0; $i -lt $n; $i++) {
            $id = [Desk]::Id($i); $r = [Desk]::Rect($id)
            if (($r.Right - $r.Left) -gt 0) { $list += [pscustomobject]@{ Id = $id; Name = "Screen $($list.Count + 1)  ($($r.Right - $r.Left) x $($r.Bottom - $r.Top))" } }
        }
    } catch { Write-Log "Could not list screens: $($_.Exception.Message)" }
    return $list
}
$script:Screens = @(Get-Screens)

function Set-LockScreen([string]$path) {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $methods = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
        $asTaskOp  = $methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
        $asTaskAct = $methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
        [void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
        [void][Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
        $t = $asTaskOp.MakeGenericMethod([Windows.Storage.StorageFile]).Invoke($null, @([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)))
        $t.Wait(); $file = $t.Result
        $asTaskAct.Invoke($null, @([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($file))).Wait()
        return $true
    } catch { Write-Log "Lock screen failed: $($_.Exception.Message)"; return $false }
}

# target: 'all', 'lock', or a screen index (0, 1, ...). Empty = the screen chosen in Settings.
function Set-Wallpaper([string]$path, $target = $null) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    if (-not (Test-Unlocked)) { Show-KeyDialog; return $false }
    if ($null -eq $target) { $target = $(if ([int]$script:S.Screen -le 0) { 'all' } else { [int]$script:S.Screen - 1 }) }
    if ("$target" -eq 'lock') {
        $ok = Set-LockScreen $path
        if (-not $ok) { [Windows.Forms.MessageBox]::Show('Windows did not allow changing the lock screen. Some work or school PCs block this.', $AppName) | Out-Null }
        return $ok
    }
    $mode = $FitModes[[string]$script:S.Fit]; if (-not $mode) { $mode = $FitModes['Fill'] }
    try {
        $desk = 'HKCU:\Control Panel\Desktop'
        Set-ItemProperty -Path $desk -Name WallpaperStyle -Value ([string]$mode[0])
        Set-ItemProperty -Path $desk -Name TileWallpaper -Value ([string]$mode[1])
    } catch { }
    $done = $false
    try {
        [Desk]::Position($mode[2])
        if ("$target" -eq 'all' -or -not $script:Screens.Count) { [Desk]::Set($null, $path) }
        else { [Desk]::Set($script:Screens[[math]::Min([int]$target, $script:Screens.Count - 1)].Id, $path) }
        $done = $true
    } catch { Write-Log "Desktop wallpaper API failed, using the classic method: $($_.Exception.Message)" }
    if (-not $done) { [void][W007]::SystemParametersInfo(20, 0, $path, 3) }
    if ($script:S.LockScreen -and "$target" -eq 'all') { [void](Set-LockScreen $path) }
    $script:S.Current = $path; Save-Settings
    Update-Status; Mark-Current
    return $true
}

function Get-ImagesIn([string]$folder) {
    if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { return @() }
    @(Get-ChildItem -LiteralPath $folder -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Where-Object { $ImageExt -contains $_.Extension.ToLower() } | ForEach-Object { $_.FullName })
}

function Get-Slot {
    $h = (Get-Date).Hour
    if ($h -ge 6 -and $h -lt 12) { return 'Morning' }
    if ($h -ge 12 -and $h -lt 17) { return 'Day' }
    if ($h -ge 17 -and $h -lt 21) { return 'Evening' }
    return 'Night'
}

function Get-Pool {
    if ($script:S.TimeOfDay) {
        $slot = @(Get-ImagesIn ([string]$script:S.(Get-Slot)))
        if ($slot.Count) { return $slot }
    }
    return @($script:S.Library | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-NextFrom($pool, [string]$current, [int]$dir) {
    if ($pool.Count -eq 1) { return $pool[0] }
    if ($script:S.Shuffle -and $dir -gt 0) {
        $others = @($pool | Where-Object { $_ -ne $current })
        return $others[(Get-Random -Maximum $others.Count)]
    }
    $i = [array]::IndexOf($pool, $current)
    return $pool[(($i + $dir) % $pool.Count + $pool.Count) % $pool.Count]
}

function Step-Wallpaper([int]$dir = 1) {
    $pool = @(Get-Pool)
    if (-not $pool.Count) { return }
    if ($script:S.EachScreen -and $script:Screens.Count -gt 1 -and [int]$script:S.Screen -le 0) {
        $picks = @($pool | Sort-Object { Get-Random })
        for ($i = 0; $i -lt $script:Screens.Count; $i++) {
            if (-not (Set-Wallpaper $picks[$i % $picks.Count] $i)) { return }
        }
        Reset-Timer; return
    }
    if (Set-Wallpaper (Get-NextFrom $pool $script:S.Current $dir)) { Reset-Timer }
}

# ---------- Look ----------
$C = @{
    Bg = [Drawing.Color]::FromArgb(14, 14, 16); Bar = [Drawing.Color]::FromArgb(22, 22, 25); Panel = [Drawing.Color]::FromArgb(30, 30, 34)
    Line = [Drawing.Color]::FromArgb(48, 48, 54); Text = [Drawing.Color]::FromArgb(243, 239, 230)
    Dim = [Drawing.Color]::FromArgb(150, 146, 138); Gold = [Drawing.Color]::FromArgb(212, 178, 112)
}
$FontUi    = New-Object Drawing.Font('Segoe UI', 10)
$FontSmall = New-Object Drawing.Font('Segoe UI', 9)
$FontTitle = New-Object Drawing.Font('Segoe UI Semibold', 14)
$FontBig   = New-Object Drawing.Font('Segoe UI Semibold', 16)
$FontHead  = New-Object Drawing.Font('Segoe UI Semibold', 8.5)

$iconPath = Join-Path $PSScriptRoot '007.ico'
$appIcon = if (Test-Path -LiteralPath $iconPath) { New-Object Drawing.Icon($iconPath) } else { [Drawing.SystemIcons]::Application }
$logoImg = $null
try { $logoImg = (New-Object Drawing.Icon($iconPath, 64, 64)).ToBitmap() } catch { }

function New-Btn($text, $x, $y, $w = 120, $gold = $false, $h = 36) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.Font = $FontUi; $b.Cursor = 'Hand'; $b.TabStop = $true
    $b.FlatAppearance.BorderSize = $(if ($gold) { 0 } else { 1 })
    $b.FlatAppearance.BorderColor = $C.Line
    $b.FlatAppearance.MouseOverBackColor = $(if ($gold) { [Drawing.Color]::FromArgb(228, 198, 140) } else { $C.Line })
    $b.BackColor = $(if ($gold) { $C.Gold } else { $C.Panel })
    $b.ForeColor = $(if ($gold) { $C.Bg } else { $C.Text })
    return $b
}
function New-Lbl($text, $x, $y, $font = $FontUi, $color = $null, $w = 300, $h = 22) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, $h)
    $l.Font = $font; $l.ForeColor = $(if ($color) { $color } else { $C.Text }); $l.BackColor = 'Transparent'
    return $l
}
function New-Chk($text, $x, $y, $checked, $w = 300) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $text; $c.Location = New-Object Drawing.Point($x, $y); $c.Size = New-Object Drawing.Size($w, 26)
    $c.Font = $FontUi; $c.ForeColor = $C.Text; $c.Checked = [bool]$checked; $c.Cursor = 'Hand'; $c.BackColor = 'Transparent'
    return $c
}
function New-Combo($items, $selected, $x, $y, $w = 140) {
    $c = New-Object Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'; $c.FlatStyle = 'Flat'; $c.Font = $FontUi
    $c.BackColor = $C.Panel; $c.ForeColor = $C.Text
    $c.Location = New-Object Drawing.Point($x, $y); $c.Width = $w
    foreach ($i in $items) { [void]$c.Items.Add($i) }
    $c.SelectedItem = $selected; if ($c.SelectedIndex -lt 0 -and $c.Items.Count) { $c.SelectedIndex = 0 }
    return $c
}
function New-Link($text, $x, $y, $w = 200) {
    $l = New-Object Windows.Forms.LinkLabel
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, 22)
    $l.LinkColor = $C.Gold; $l.ActiveLinkColor = $C.Text; $l.VisitedLinkColor = $C.Gold; $l.Font = $FontSmall
    $l.LinkBehavior = 'HoverUnderline'; $l.BackColor = 'Transparent'
    return $l
}
function Set-DarkFrame($f) { $f.Add_HandleCreated({ try { [W007]::DarkFrame($this.Handle) } catch { } }) }

# ---------- Main window ----------
$form = New-Object Windows.Forms.Form
$form.Text = $AppName; $form.Size = New-Object Drawing.Size(1000, 680); $form.MinimumSize = New-Object Drawing.Size(760, 520)
$form.StartPosition = 'CenterScreen'; $form.BackColor = $C.Bg; $form.ForeColor = $C.Text; $form.Font = $FontUi
$form.Icon = $appIcon; $form.Opacity = 0.94; $form.KeyPreview = $true
Set-DarkFrame $form

# Header
$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 72; $header.BackColor = $C.Bg
if ($logoImg) {
    $pic = New-Object Windows.Forms.PictureBox
    $pic.Image = $logoImg; $pic.SizeMode = 'Zoom'; $pic.Location = New-Object Drawing.Point(22, 16); $pic.Size = New-Object Drawing.Size(40, 40); $pic.BackColor = 'Transparent'
    $header.Controls.Add($pic)
}
$header.Controls.Add((New-Lbl $AppName 72 14 $FontTitle $C.Text 360 28))
$lCount = New-Lbl '' 74 42 $FontSmall $C.Dim 360 20; $header.Controls.Add($lCount)
$bAdd = New-Btn '+  Add wallpapers' 0 18 160 $true; $bAdd.Anchor = 'Top, Right'
$bSet = New-Btn 'Settings' 0 18 100; $bSet.Anchor = 'Top, Right'
$header.Controls.AddRange(@($bAdd, $bSet))
$header.Add_Resize({ $bSet.Left = $header.Width - 122; $bAdd.Left = $header.Width - 292 })

$addMenu = New-Object Windows.Forms.ContextMenuStrip
$miAddPics   = $addMenu.Items.Add('Pictures...')
$miAddFolder = $addMenu.Items.Add('A whole folder...')
$miAddMine   = $addMenu.Items.Add('My Pictures folder')
$miAddWin    = $addMenu.Items.Add('Windows wallpapers')

# Bottom bar
$bar = New-Object Windows.Forms.Panel
$bar.Dock = 'Bottom'; $bar.Height = 64; $bar.BackColor = $C.Bar
$bPrev = New-Btn '<' 20 14 44 $false; $bNext = New-Btn 'Next wallpaper' 70 14 150 $true
$cAuto = New-Chk 'Change every' 240 19 $script:S.AutoChange 118
$Intervals = [ordered]@{ '1 minute' = 1; '5 minutes' = 5; '15 minutes' = 15; '30 minutes' = 30; '1 hour' = 60; '3 hours' = 180; '6 hours' = 360; '1 day' = 1440 }
$curInt = ($Intervals.Keys | Where-Object { $Intervals[$_] -eq [int]$script:S.Interval } | Select-Object -First 1)
$cbInt = New-Combo $Intervals.Keys $curInt 360 18 120
$cShuffle = New-Chk 'Shuffle' 496 19 $script:S.Shuffle 90
$lStatus = New-Lbl '' 0 12 $FontSmall $C.Dim 260 20; $lStatus.TextAlign = 'MiddleRight'; $lStatus.Anchor = 'Top, Right'
$lLic = New-Link '' 0 32 260; $lLic.TextAlign = 'MiddleRight'; $lLic.Anchor = 'Top, Right'
$bar.Controls.AddRange(@($bPrev, $bNext, $cAuto, $cbInt, $cShuffle, $lStatus, $lLic))
$bar.Add_Resize({ $lStatus.Left = $bar.Width - 282; $lLic.Left = $bar.Width - 282 })

# Grid
$thumbs = New-Object Windows.Forms.ImageList
$thumbs.ImageSize = New-Object Drawing.Size(200, 112); $thumbs.ColorDepth = 'Depth32Bit'
$list = New-Object Windows.Forms.ListView
$list.View = 'LargeIcon'; $list.LargeImageList = $thumbs; $list.MultiSelect = $true; $list.Activation = 'OneClick'; $list.HotTracking = $false
$list.BackColor = $C.Bg; $list.ForeColor = $C.Dim; $list.BorderStyle = 'None'; $list.Font = $FontSmall
$list.Dock = 'Fill'; $list.AllowDrop = $true; $list.ShowItemToolTips = $true
$gridWrap = New-Object Windows.Forms.Panel
$gridWrap.Dock = 'Fill'; $gridWrap.Padding = New-Object Windows.Forms.Padding(18, 6, 8, 6); $gridWrap.BackColor = $C.Bg
$gridWrap.Controls.Add($list)

# Empty state (first run)
$empty = New-Object Windows.Forms.Panel
$empty.Dock = 'Fill'; $empty.BackColor = $C.Bg; $empty.AllowDrop = $true
$eTitle = New-Lbl 'Add your wallpapers to get started' 0 0 $FontBig $C.Text 520 34; $eTitle.TextAlign = 'MiddleCenter'
$eSub   = New-Lbl 'Pick a folder, or drag pictures into this window.' 0 0 $FontUi $C.Dim 520 24; $eSub.TextAlign = 'MiddleCenter'
$eFolder = New-Btn 'Choose a folder' 0 0 170 $true 42
$eMine   = New-Btn 'Use My Pictures' 0 0 170 $false 42
$eWin    = New-Link 'or start with the Windows wallpapers' 0 0 300; $eWin.TextAlign = 'MiddleCenter'
$empty.Controls.AddRange(@($eTitle, $eSub, $eFolder, $eMine, $eWin))
$empty.Add_Resize({
    $cx = [int]($empty.Width / 2); $cy = [int]($empty.Height / 2) - 70
    $eTitle.Location = New-Object Drawing.Point(($cx - 260), $cy)
    $eSub.Location   = New-Object Drawing.Point(($cx - 260), ($cy + 40))
    $eFolder.Location = New-Object Drawing.Point(($cx - 178), ($cy + 84))
    $eMine.Location   = New-Object Drawing.Point(($cx + 8), ($cy + 84))
    $eWin.Location    = New-Object Drawing.Point(($cx - 150), ($cy + 140))
})

$form.Controls.Add($gridWrap); $form.Controls.Add($empty); $form.Controls.Add($bar); $form.Controls.Add($header)
$empty.BringToFront()

# ---------- Library ----------
function Get-ThumbKey([string]$path) {
    $md5 = [Security.Cryptography.MD5]::Create()
    $t = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
    return ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($path.ToLower())|$t|v2"))) -replace '-', '')
}

function Get-Thumb([string]$path) {
    $file = Join-Path $ThumbDir "$(Get-ThumbKey $path).jpg"
    if (-not (Test-Path -LiteralPath $file)) {
        $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($path))
        try {
            $src = [Drawing.Image]::FromStream($ms, $false, $false)
            $tw = $thumbs.ImageSize.Width; $th = $thumbs.ImageSize.Height
            $bmp = New-Object Drawing.Bitmap($tw, $th)
            $g = [Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = 'HighQualityBicubic'; $g.Clear($C.Panel)
            $scale = [math]::Max($tw / $src.Width, $th / $src.Height)
            $w = $src.Width * $scale; $h = $src.Height * $scale
            $g.DrawImage($src, [single](($tw - $w) / 2), [single](($th - $h) / 2), [single]$w, [single]$h)
            $g.Dispose(); $src.Dispose()
            $bmp.Save($file, [Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
        } finally { $ms.Dispose() }
    }
    $ms2 = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($file))
    return [Drawing.Image]::FromStream($ms2)
}

function Mark-Current {
    foreach ($it in $list.Items) {
        $isCur = ($it.Tag -eq $script:S.Current)
        $it.ForeColor = $(if ($isCur) { $C.Gold } else { $C.Dim })
        $it.Text = $(if ($isCur) { [char]0x25CF + ' ' } else { '' }) + [IO.Path]::GetFileNameWithoutExtension($it.Tag)
    }
}

function Refresh-Library {
    $form.Cursor = 'WaitCursor'
    $list.BeginUpdate(); $list.Items.Clear(); $thumbs.Images.Clear()
    $keep = New-Object Collections.Generic.List[string]
    $n = 0
    foreach ($p in $script:S.Library) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $thumbs.Images.Add($p, (Get-Thumb $p))
            $item = New-Object Windows.Forms.ListViewItem([IO.Path]::GetFileNameWithoutExtension($p), $p)
            $item.Tag = $p; $item.ToolTipText = $p
            [void]$list.Items.Add($item); $keep.Add($p)
        } catch { Write-Log "Skipped a picture that could not be read: $p ($($_.Exception.Message))" }
        $n++; if ($n % 12 -eq 0) { [Windows.Forms.Application]::DoEvents() }
    }
    $list.EndUpdate()
    $script:S.Library = @($keep); Save-Settings
    $has = ($keep.Count -gt 0)
    $empty.Visible = -not $has; $gridWrap.Visible = $has
    $lCount.Text = $(if ($has) { "$($keep.Count) wallpaper$(if ($keep.Count -ne 1) { 's' })  ·  click one to set it, right-click for more" } else { 'Your wallpaper library' })
    Mark-Current; Update-Status
    $form.Cursor = 'Default'
}

function Add-ToLibrary([string[]]$paths) {
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $lib = New-Object Collections.Generic.List[string]
    foreach ($p in $script:S.Library) { if ($seen.Add($p)) { $lib.Add($p) } }
    $before = $lib.Count
    foreach ($p in $paths) {
        if (-not $p) { continue }
        if (Test-Path -LiteralPath $p -PathType Container) { foreach ($f in (Get-ImagesIn $p)) { if ($seen.Add($f)) { $lib.Add($f) } } }
        elseif ($ImageExt -contains ([IO.Path]::GetExtension($p).ToLower())) { if ($seen.Add($p)) { $lib.Add($p) } }
    }
    $script:S.Library = @($lib)
    Refresh-Library
    if ($lib.Count -eq $before) { [Windows.Forms.MessageBox]::Show('No new pictures found there. Supported: JPG, PNG, BMP.', $AppName) | Out-Null }
    elseif (-not $script:S.Current) { Step-Wallpaper 1 }
}

function Pick-Folder {
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Choose a folder with wallpapers (subfolders are included)'
    if ($fb.ShowDialog($form) -eq 'OK') { Add-ToLibrary @($fb.SelectedPath) }
}
function Pick-Files {
    $od = New-Object Windows.Forms.OpenFileDialog
    $od.Multiselect = $true; $od.Title = 'Add wallpapers'
    $od.Filter = 'Pictures (*.jpg;*.jpeg;*.jfif;*.png;*.bmp)|*.jpg;*.jpeg;*.jfif;*.png;*.bmp'
    if ($od.ShowDialog($form) -eq 'OK') { Add-ToLibrary $od.FileNames }
}
$WinWallDir = Join-Path $env:SystemRoot 'Web\Wallpaper'

# ---------- Timer and status ----------
$script:NextAt = (Get-Date).AddMinutes([int]$script:S.Interval)
$script:LastSlot = Get-Slot
function Reset-Timer { $script:NextAt = (Get-Date).AddMinutes([int]$script:S.Interval); Update-Status }

function Update-Status {
    $lStatus.Text = $(if (-not $list.Items.Count) { '' } elseif ($script:S.AutoChange) { 'Next change at ' + $script:NextAt.ToString('HH:mm') } else { 'Auto change is off' })
    if (Test-Licensed) { $lLic.Text = 'Full version'; $lLic.LinkColor = $C.Dim }
    else {
        $left = Get-TrialLeft
        $lLic.Text = $(if ($left -gt 0) { "Free trial: $left day$(if ($left -ne 1) { 's' }) left  ·  Unlock" } else { 'Trial ended  ·  Unlock now' })
        $lLic.LinkColor = $C.Gold
    }
    $cbInt.Enabled = $cAuto.Checked
    if ($script:TrayPause) { $script:TrayPause.Text = $(if ($script:S.AutoChange) { 'Pause auto change' } else { 'Resume auto change' }) }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    Invoke-Safe {
        $slot = Get-Slot
        $slotChanged = ($script:S.TimeOfDay -and $slot -ne $script:LastSlot)
        $script:LastSlot = $slot
        if ($script:S.AutoChange -and ($slotChanged -or (Get-Date) -ge $script:NextAt)) {
            if (Test-Unlocked) { Step-Wallpaper 1 } else { Reset-Timer }
        }
    } 'Timer'
})

# ---------- Dialogs ----------
function New-Dialog($title, $w, $h) {
    $d = New-Object Windows.Forms.Form
    $d.Text = $title; $d.ClientSize = New-Object Drawing.Size($w, $h); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
    $d.BackColor = $C.Bg; $d.ForeColor = $C.Text; $d.Font = $FontUi; $d.Icon = $appIcon; $d.Opacity = 0.97
    Set-DarkFrame $d
    return $d
}

function Show-KeyDialog {
    $d = New-Dialog 'Unlock 007 Wall Switcher' 440 250
    $d.Controls.Add((New-Lbl 'Unlock the full version' 24 20 $FontBig $C.Text 400 30))
    $info = New-Lbl "Buy a key for `$2.99 with Whish or crypto on the 007 website. You get it in your Discord ticket. Paste it here:" 24 56 $FontSmall $C.Dim 392 40
    $d.Controls.Add($info)
    $tb = New-Object Windows.Forms.TextBox
    $tb.Location = New-Object Drawing.Point(24, 102); $tb.Width = 392; $tb.Font = New-Object Drawing.Font('Consolas', 13)
    $tb.BackColor = $C.Panel; $tb.ForeColor = $C.Text; $tb.BorderStyle = 'FixedSingle'; $tb.CharacterCasing = 'Upper'
    $tb.Text = $script:S.Key
    $d.Controls.Add($tb)
    $msg = New-Lbl '' 24 140 $FontSmall $C.Gold 392; $d.Controls.Add($msg)
    $ok = New-Btn 'Activate' 24 180 186 $true 40; $buy = New-Btn 'Buy a key  ($2.99)' 230 180 186 $false 40
    $d.Controls.AddRange(@($ok, $buy)); $d.AcceptButton = $ok
    $ok.Add_Click({
        $k = ($tb.Text.ToUpper() -replace '\s', '')
        if (Test-Key $k) {
            $script:S.Key = $k; Save-Settings; Update-Status
            [Windows.Forms.MessageBox]::Show('Activated. Enjoy the full version!', $AppName) | Out-Null; $d.Close()
        } elseif (-not $k) { $msg.Text = 'Paste your key first. It looks like 007W-XXXX-XXXX-XXXX.' }
        else { $msg.Text = 'That key is not valid. Check it and try again.' }
    })
    $buy.Add_Click({ Start-Process $ShopUrl })
    $owner = $(if ($form.Visible) { $form } else { $null })
    [void]$d.ShowDialog($owner)
}

function Show-TodDialog($owner) {
    $d = New-Dialog 'Time of day folders' 540 300
    $d.Controls.Add((New-Lbl 'Pick a folder for each time of day. Empty ones use your library.' 20 16 $FontSmall $C.Dim 500))
    $slots = [ordered]@{ Morning = '6:00 - 12:00'; Day = '12:00 - 17:00'; Evening = '17:00 - 21:00'; Night = '21:00 - 6:00' }
    $boxes = @{}; $yy = 48
    foreach ($name in $slots.Keys) {
        $d.Controls.Add((New-Lbl $name 20 ($yy + 7) $FontUi $C.Text 80))
        $d.Controls.Add((New-Lbl $slots[$name] 100 ($yy + 8) $FontSmall $C.Dim 100))
        $tb = New-Object Windows.Forms.TextBox
        $tb.Location = New-Object Drawing.Point(200, ($yy + 4)); $tb.Width = 220; $tb.ReadOnly = $true
        $tb.BackColor = $C.Panel; $tb.ForeColor = $C.Text; $tb.BorderStyle = 'FixedSingle'; $tb.Text = [string]$script:S.$name
        $d.Controls.Add($tb); $boxes[$name] = $tb
        $b = New-Btn 'Browse' 430 $yy 90 $false 32; $b.Tag = $name
        $b.Add_Click({
            $fb = New-Object Windows.Forms.FolderBrowserDialog
            if ($fb.ShowDialog() -eq 'OK') { $boxes[$this.Tag].Text = $fb.SelectedPath }
        })
        $d.Controls.Add($b); $yy += 46
    }
    $save = New-Btn 'Save' 20 ($yy + 14) 120 $true; $clear = New-Btn 'Clear all' 150 ($yy + 14) 120
    $save.Add_Click({ foreach ($n in $boxes.Keys) { $script:S.$n = $boxes[$n].Text }; Save-Settings; $d.Close() })
    $clear.Add_Click({ foreach ($n in $boxes.Keys) { $boxes[$n].Text = '' } })
    $d.Controls.AddRange(@($save, $clear))
    [void]$d.ShowDialog($owner)
}

function Set-Startup([bool]$on) {
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        if ($on) {
            $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Tray"
            Set-ItemProperty -Path $run -Name '007 Wall Switcher' -Value $cmd
        } else { Remove-ItemProperty -Path $run -Name '007 Wall Switcher' -ErrorAction SilentlyContinue }
    } catch { Write-Log "Start with Windows failed: $($_.Exception.Message)" }
}

function Show-Settings {
    $d = New-Dialog 'Settings' 460 590
    $y = 18
    function Add-Head($t) { $d.Controls.Add((New-Lbl $t 24 $script:sy $FontHead $C.Gold 400 18)); $script:sy += 24 }
    $script:sy = $y

    Add-Head 'SCREENS'
    $screenNames = @('All screens') + @($script:Screens | ForEach-Object { $_.Name })
    $cbScreen = New-Combo $screenNames $screenNames[[math]::Min([int]$script:S.Screen, $screenNames.Count - 1)] 24 $script:sy 300; $d.Controls.Add($cbScreen); $script:sy += 36
    $cEach = New-Chk 'Different picture on each screen' 24 $script:sy $script:S.EachScreen 400; $d.Controls.Add($cEach); $script:sy += 28
    if ($script:Screens.Count -lt 2) { $cEach.Enabled = $false; $cEach.Text = 'Different picture on each screen (needs 2+ screens)' }
    $cLock = New-Chk 'Also change the lock screen' 24 $script:sy $script:S.LockScreen 400; $d.Controls.Add($cLock); $script:sy += 40

    Add-Head 'PICTURE POSITION'
    $cbFit = New-Combo $FitModes.Keys ([string]$script:S.Fit) 24 $script:sy 160; $d.Controls.Add($cbFit); $script:sy += 44

    Add-Head 'TIME OF DAY'
    $cTod = New-Chk 'Use a different folder for morning, day, evening, night' 24 $script:sy $script:S.TimeOfDay 410; $d.Controls.Add($cTod); $script:sy += 30
    $bTod = New-Btn 'Choose folders...' 24 $script:sy 160 $false 32; $d.Controls.Add($bTod); $script:sy += 48

    Add-Head 'GENERAL'
    $cStart = New-Chk 'Start with Windows' 24 $script:sy $script:S.Startup 400; $d.Controls.Add($cStart); $script:sy += 28
    $cHot = New-Chk 'Quick picker with Ctrl + Alt + W' 24 $script:sy $script:S.Hotkey 400; $d.Controls.Add($cHot); $script:sy += 40

    Add-Head 'LICENSE'
    $licText = $(if (Test-Licensed) { 'Full version. Thank you!' } else { $l = Get-TrialLeft; if ($l -gt 0) { "Free trial: $l day$(if ($l -ne 1) { 's' }) left" } else { 'Trial ended' } })
    $d.Controls.Add((New-Lbl $licText 24 $script:sy $FontUi $C.Text 220))
    if (-not (Test-Licensed)) { $bKey = New-Btn 'Enter key' 250 ($script:sy - 6) 90 $false 32; $bBuy = New-Btn 'Buy $2.99' 346 ($script:sy - 6) 90 $true 32; $d.Controls.AddRange(@($bKey, $bBuy))
        $bKey.Add_Click({ $script:OpenKeyAfter = $true; $d.Close() }); $bBuy.Add_Click({ Start-Process $ShopUrl }) }
    $script:sy += 46

    $lp = New-Link 'Get 007 Signature wallpaper packs' 24 $script:sy 230; $lp.Add_LinkClicked({ Start-Process $PacksUrl })
    $ld = New-Link 'Help on Discord' 260 $script:sy 120; $ld.Add_LinkClicked({ Start-Process $DiscordUrl })
    $lo = New-Link 'Open log' 384 $script:sy 70; $lo.Add_LinkClicked({ if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe $LogFile } })
    $d.Controls.AddRange(@($lp, $ld, $lo)); $script:sy += 28
    $d.Controls.Add((New-Lbl "Version $AppVersion" 24 $script:sy $FontSmall $C.Dim 200))
    $done = New-Btn 'Done' 336 ($d.ClientSize.Height - 54) 100 $true; $d.Controls.Add($done); $d.AcceptButton = $done
    $done.Add_Click({ $d.Close() })

    $cbScreen.Add_SelectedIndexChanged({ $script:S.Screen = $cbScreen.SelectedIndex; Save-Settings })
    $cEach.Add_CheckedChanged({ $script:S.EachScreen = $cEach.Checked; Save-Settings })
    $cLock.Add_CheckedChanged({ $script:S.LockScreen = $cLock.Checked; Save-Settings })
    $cbFit.Add_SelectedIndexChanged({ $script:S.Fit = [string]$cbFit.SelectedItem; Save-Settings; if ($script:S.Current -and (Test-Unlocked)) { [void](Set-Wallpaper $script:S.Current) } })
    $cTod.Add_CheckedChanged({ $script:S.TimeOfDay = $cTod.Checked; Save-Settings; if ($cTod.Checked -and -not ("$($script:S.Morning)$($script:S.Day)$($script:S.Evening)$($script:S.Night)")) { Show-TodDialog $d } })
    $bTod.Add_Click({ Show-TodDialog $d })
    $cStart.Add_CheckedChanged({ $script:S.Startup = $cStart.Checked; Set-Startup $cStart.Checked; Save-Settings })
    $cHot.Add_CheckedChanged({ $script:S.Hotkey = $cHot.Checked; Set-Hotkey $cHot.Checked; Save-Settings })
    $script:OpenKeyAfter = $false
    [void]$d.ShowDialog($form)
    if ($script:OpenKeyAfter) { Show-KeyDialog }
}

# ---------- Events ----------
$bAdd.Add_Click({ $addMenu.Show($bAdd, (New-Object Drawing.Point(0, $bAdd.Height))) })
$miAddPics.Add_Click({ Invoke-Safe { Pick-Files } 'Add pictures' })
$miAddFolder.Add_Click({ Invoke-Safe { Pick-Folder } 'Add folder' })
$miAddMine.Add_Click({ Invoke-Safe { Add-ToLibrary @([Environment]::GetFolderPath('MyPictures')) } 'Add My Pictures' })
$miAddWin.Add_Click({ Invoke-Safe { Add-ToLibrary @($WinWallDir) } 'Add Windows wallpapers' })
$eFolder.Add_Click({ Invoke-Safe { Pick-Folder } 'Add folder' })
$eMine.Add_Click({ Invoke-Safe { Add-ToLibrary @([Environment]::GetFolderPath('MyPictures')) } 'Add My Pictures' })
$eWin.Add_LinkClicked({ Invoke-Safe { Add-ToLibrary @($WinWallDir) } 'Add Windows wallpapers' })
$bSet.Add_Click({ Invoke-Safe { Show-Settings } 'Settings' })

function Remove-Selected {
    $sel = @($list.SelectedItems | ForEach-Object { $_.Tag })
    if (-not $sel.Count) { return }
    $script:S.Library = @($script:S.Library | Where-Object { $sel -notcontains $_ })
    Refresh-Library
}

foreach ($target in $list, $empty) {
    $target.Add_DragEnter({ if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
    $target.Add_DragDrop({ $files = [string[]]$_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); Invoke-Safe { Add-ToLibrary $files } 'Drop' })
}
$list.Add_ItemActivate({ if ($list.SelectedItems.Count -eq 1) { $p = $list.SelectedItems[0].Tag; Invoke-Safe { if (Set-Wallpaper $p) { Reset-Timer } } 'Set wallpaper' } })
$form.Add_KeyDown({
    if ($_.KeyCode -eq 'Delete' -and $list.Focused) { Remove-Selected }
    elseif ($_.KeyCode -eq 'Right' -and $_.Control) { Step-Wallpaper 1 }
    elseif ($_.KeyCode -eq 'Left' -and $_.Control) { Step-Wallpaper -1 }
})

$bNext.Add_Click({ Invoke-Safe { Step-Wallpaper 1 } 'Next' })
$bPrev.Add_Click({ Invoke-Safe { Step-Wallpaper -1 } 'Previous' })
$cAuto.Add_CheckedChanged({ $script:S.AutoChange = $cAuto.Checked; Save-Settings; Reset-Timer })
$cbInt.Add_SelectedIndexChanged({ $script:S.Interval = $Intervals[[string]$cbInt.SelectedItem]; Save-Settings; Reset-Timer })
$cShuffle.Add_CheckedChanged({ $script:S.Shuffle = $cShuffle.Checked; Save-Settings })
$lLic.Add_LinkClicked({ if (Test-Licensed) { Show-Settings } else { Show-KeyDialog } })

# Right-click a wallpaper: choose where it goes.
$itemMenu = New-Object Windows.Forms.ContextMenuStrip
$list.ContextMenuStrip = $itemMenu
$itemMenu.Add_Opening({
    $itemMenu.Items.Clear()
    if (-not $list.SelectedItems.Count) { $_.Cancel = $true; return }
    $p = $list.SelectedItems[0].Tag
    $m = $itemMenu.Items.Add('Set on all screens'); $m.Tag = @($p, 'all'); $m.Add_Click({ Invoke-Safe { [void](Set-Wallpaper $this.Tag[0] $this.Tag[1]); Reset-Timer } 'Set' })
    for ($i = 0; $i -lt $script:Screens.Count -and $script:Screens.Count -gt 1; $i++) {
        $m = $itemMenu.Items.Add("Set on $($script:Screens[$i].Name)"); $m.Tag = @($p, $i); $m.Add_Click({ Invoke-Safe { [void](Set-Wallpaper $this.Tag[0] $this.Tag[1]); Reset-Timer } 'Set' })
    }
    $m = $itemMenu.Items.Add('Set as lock screen'); $m.Tag = @($p, 'lock'); $m.Add_Click({ Invoke-Safe { [void](Set-Wallpaper $this.Tag[0] $this.Tag[1]) } 'Lock screen' })
    [void]$itemMenu.Items.Add('-')
    $m = $itemMenu.Items.Add('Show in folder'); $m.Tag = $p; $m.Add_Click({ Start-Process explorer.exe "/select,`"$($this.Tag)`"" })
    $m = $itemMenu.Items.Add('Remove from library'); $m.Add_Click({ Remove-Selected })
    $_.Cancel = $false
})

# ---------- Quick picker (Ctrl + Alt + W) ----------
$picker = New-Object Windows.Forms.Form
$picker.FormBorderStyle = 'None'; $picker.TopMost = $true; $picker.ShowInTaskbar = $false; $picker.StartPosition = 'Manual'
$picker.BackColor = $C.Bg; $picker.Opacity = 0.9; $picker.KeyPreview = $true
$pTitle = New-Lbl 'Pick a wallpaper' 60 40 $FontBig $C.Text 600 34
$pHint  = New-Lbl 'Click to set it  ·  Esc to close' 62 78 $FontUi $C.Dim 700
$pList = New-Object Windows.Forms.ListView
$pList.View = 'LargeIcon'; $pList.LargeImageList = $thumbs; $pList.MultiSelect = $false; $pList.Activation = 'OneClick'
$pList.BackColor = $C.Bg; $pList.ForeColor = $C.Dim; $pList.BorderStyle = 'None'; $pList.Font = $FontSmall
$pList.Location = New-Object Drawing.Point(60, 120)
$picker.Controls.AddRange(@($pTitle, $pHint, $pList))
$picker.Add_Resize({ $pList.Size = New-Object Drawing.Size([math]::Max(100, $picker.ClientSize.Width - 120), [math]::Max(100, $picker.ClientSize.Height - 160)) })
$picker.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $picker.Hide() } })
$picker.Add_Deactivate({ $picker.Hide() })
$picker.Add_FormClosing({ if (-not $script:Exiting) { $_.Cancel = $true; $picker.Hide() } })
$pList.Add_ItemActivate({ if ($pList.SelectedItems.Count) { $p = $pList.SelectedItems[0].Tag; $picker.Hide(); Invoke-Safe { if (Set-Wallpaper $p) { Reset-Timer } } 'Picker' } })

function Show-Picker {
    if (-not $list.Items.Count) { Show-Main; return }
    $pList.BeginUpdate(); $pList.Items.Clear()
    foreach ($it in $list.Items) {
        $n = New-Object Windows.Forms.ListViewItem([IO.Path]::GetFileNameWithoutExtension($it.Tag), $it.ImageKey); $n.Tag = $it.Tag
        if ($it.Tag -eq $script:S.Current) { $n.ForeColor = $C.Gold }
        [void]$pList.Items.Add($n)
    }
    $pList.EndUpdate()
    $picker.Bounds = ([Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position)).WorkingArea
    $picker.Show(); $picker.Activate(); [void]$pList.Focus()
}

$script:Hot = New-Object HotkeyWindow
$script:Hot.add_Pressed({ if ($picker.Visible) { $picker.Hide() } else { Invoke-Safe { Show-Picker } 'Picker' } })
function Set-Hotkey([bool]$on) {
    [void][W007]::UnregisterHotKey($script:Hot.Handle, 1)
    if ($on) {
        # MOD_ALT 0x1 + MOD_CONTROL 0x2 + MOD_NOREPEAT 0x4000, key W = 0x57
        if (-not [W007]::RegisterHotKey($script:Hot.Handle, 1, 0x4003, 0x57)) {
            Write-Log 'Ctrl+Alt+W is already used by another app.'
            $tray.ShowBalloonTip(4000, $AppName, 'Ctrl + Alt + W is used by another app, so the quick picker shortcut is off. Use the tray menu instead.', 'Warning')
        }
    }
}

# ---------- Tray ----------
$script:Exiting = $false
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $appIcon; $tray.Text = $AppName; $tray.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Open 007 Wall Switcher')
$miPick = $menu.Items.Add('Quick picker  (Ctrl+Alt+W)')
$miNext = $menu.Items.Add('Next wallpaper')
$script:TrayPause = $menu.Items.Add('Pause auto change')
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu

function Show-Main { $form.Show(); if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }; $form.Activate() }
$miOpen.Add_Click({ Show-Main })
$tray.Add_MouseDoubleClick({ Show-Main })
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { Show-Main } })
$miPick.Add_Click({ Invoke-Safe { Show-Picker } 'Picker' })
$miNext.Add_Click({ Invoke-Safe { Step-Wallpaper 1 } 'Next' })
$script:TrayPause.Add_Click({ $cAuto.Checked = -not $cAuto.Checked })
$miExit.Add_Click({ $script:Exiting = $true; $tray.Visible = $false; $timer.Stop(); $picker.Close(); $form.Close(); [Windows.Forms.Application]::Exit() })

$form.Add_FormClosing({
    if (-not $script:Exiting -and $_.CloseReason -eq 'UserClosing') {
        $_.Cancel = $true; $form.Hide()
        if (-not $script:ToldTray) {
            $tray.ShowBalloonTip(3000, $AppName, 'Still running here. Click this icon to open it, right-click to exit.', 'Info'); $script:ToldTray = $true
        }
    }
})
$script:Loaded = $false
$form.Add_Shown({
    if (-not $script:Loaded) { $script:Loaded = $true; Invoke-Safe { Refresh-Library } 'Load library' }
    if (-not (Test-Unlocked)) { Show-KeyDialog }
})

# ---------- Start ----------
Write-Log "Started v$AppVersion"
if ($script:S.Startup) { Set-Startup $true }   # keep the startup path current if the app was moved
Set-Hotkey ([bool]$script:S.Hotkey)
Update-Status
$timer.Start()
$appCtx = New-Object Windows.Forms.ApplicationContext
if ($Tray) { Invoke-Safe { Refresh-Library } 'Load library'; $script:Loaded = $true } else { Show-Main }
[Windows.Forms.Application]::Run($appCtx)
$tray.Dispose()
[void][W007]::UnregisterHotKey($script:Hot.Handle, 1); $script:Hot.Dispose()
$script:Mutex.ReleaseMutex()
