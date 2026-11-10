# WallSwitcher.ps1 - 007 Wall Switcher: a wallpaper library and auto-changer for Windows.
# Add your wallpapers, click one to set it, or let it change on a timer.
#
# Usage:
#   WallSwitcher.ps1         open the app
#   WallSwitcher.ps1 -Tray   start hidden in the tray (used by "Start with Windows")

param([switch]$Tray)

$AppVersion = '1.0.0'
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
$script:Mutex = New-Object System.Threading.Mutex($true, 'Global\007WallSwitcher', [ref]$created)
if (-not $created) {
    [System.Windows.Forms.MessageBox]::Show("$AppName is already running. Look for it in the tray, next to the clock.", $AppName) | Out-Null
    exit
}

# ---------- Paths and settings ----------
$DataDir      = Join-Path $env:APPDATA '007WallSwitcher'
$ThumbDir     = Join-Path $DataDir 'thumbs'
$SettingsFile = Join-Path $DataDir 'settings.json'
New-Item -ItemType Directory -Force -Path $ThumbDir | Out-Null
$ImageExt = @('.jpg', '.jpeg', '.png', '.bmp')

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
                if ($s.PSObject.Properties[$p.Name]) { $s.($p.Name) = $p.Value }
            }
        } catch { }
    }
    $s.Library = @($s.Library | Where-Object { $_ })
    return $s
}

function Save-Settings { $script:S | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SettingsFile -Encoding UTF8 }

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
    $reg = 'HKCU:\Software\007WallSwitcher'
    if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
    $first = (Get-ItemProperty -Path $reg -Name FirstRun -ErrorAction SilentlyContinue).FirstRun
    if (-not $first) { $first = (Get-Date).ToUniversalTime().Ticks.ToString(); Set-ItemProperty -Path $reg -Name FirstRun -Value $first }
    $used = ((Get-Date).ToUniversalTime() - [datetime]::new([long]$first, 'Utc')).TotalDays
    return [math]::Max(0, [math]::Ceiling($TrialDays - $used))
}

function Test-Unlocked { return ((Test-Key $script:S.Key) -or ((Get-TrialLeft) -gt 0)) }

# ---------- Wallpaper ----------
# Fit: registry values for the classic method, plus the IDesktopWallpaper position number.
$FitModes = [ordered]@{ Fill = @(10, 0, 4); Fit = @(6, 0, 3); Stretch = @(2, 0, 2); Center = @(0, 0, 0); Tile = @(0, 1, 1); Span = @(22, 0, 5) }

function Get-Screens {
    $list = @()
    try {
        $n = [Desk]::Count()
        for ($i = 0; $i -lt $n; $i++) {
            $id = [Desk]::Id($i); $r = [Desk]::Rect($id)
            if (($r.Right - $r.Left) -gt 0) { $list += [pscustomobject]@{ Id = $id; Name = "Screen $($list.Count + 1)  ·  $($r.Right - $r.Left) x $($r.Bottom - $r.Top)" } }
        }
    } catch { }
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
    } catch { return $false }
}

# target: 'all', 'lock', or a screen index (0, 1, ...). Empty = the screen chosen in the app.
function Set-Wallpaper([string]$path, $target = $null) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    if (-not (Test-Unlocked)) { Show-KeyDialog; return $false }
    if ($null -eq $target) { $target = $(if ([int]$script:S.Screen -le 0) { 'all' } else { [int]$script:S.Screen - 1 }) }
    if ($target -eq 'lock') { $ok = Set-LockScreen $path; if (-not $ok) { [Windows.Forms.MessageBox]::Show('Windows did not allow changing the lock screen. Some work or school PCs block this.', $AppName) | Out-Null }; return $ok }
    $mode = $FitModes[$script:S.Fit]; if (-not $mode) { $mode = $FitModes['Fill'] }
    $desk = 'HKCU:\Control Panel\Desktop'
    Set-ItemProperty -Path $desk -Name WallpaperStyle -Value ([string]$mode[0])
    Set-ItemProperty -Path $desk -Name TileWallpaper -Value ([string]$mode[1])
    $done = $false
    try {
        [Desk]::Position($mode[2])
        if ($target -eq 'all' -or -not $script:Screens.Count) { [Desk]::Set($null, $path) }
        else { [Desk]::Set($script:Screens[[math]::Min([int]$target, $script:Screens.Count - 1)].Id, $path) }
        $done = $true
    } catch { }
    if (-not $done) { [void][W007]::SystemParametersInfo(20, 0, $path, 3) }
    if ($script:S.LockScreen -and $target -eq 'all') { [void](Set-LockScreen $path) }
    $script:S.Current = $path; Save-Settings
    Update-Status
    return $true
}

function Get-ImagesIn([string]$folder) {
    if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { return @() }
    @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object { $ImageExt -contains $_.Extension.ToLower() } | ForEach-Object { $_.FullName })
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
        $slot = Get-ImagesIn $script:S.(Get-Slot)
        if ($slot.Count) { return $slot }
    }
    return @($script:S.Library | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-NextFrom($pool, [string]$current, [int]$dir) {
    if ($script:S.Shuffle -and $pool.Count -gt 1 -and $dir -gt 0) {
        $next = $current
        while ($next -eq $current) { $next = $pool[(Get-Random -Maximum $pool.Count)] }
        return $next
    }
    $i = [array]::IndexOf($pool, $current)
    return $pool[(($i + $dir) % $pool.Count + $pool.Count) % $pool.Count]
}

function Step-Wallpaper([int]$dir = 1) {
    $pool = @(Get-Pool)
    if (-not $pool.Count) { return }
    if ($script:S.EachScreen -and $script:Screens.Count -gt 1 -and [int]$script:S.Screen -le 0) {
        # A different picture on every screen.
        $picks = @($pool | Sort-Object { Get-Random })
        for ($i = 0; $i -lt $script:Screens.Count; $i++) {
            if (-not (Set-Wallpaper $picks[$i % $picks.Count] $i)) { return }
        }
        Reset-Timer; return
    }
    if (Set-Wallpaper (Get-NextFrom $pool $script:S.Current $dir)) { Reset-Timer }
}

# ---------- Theme ----------
$C = @{
    Bg = [Drawing.Color]::FromArgb(11, 11, 12); Panel = [Drawing.Color]::FromArgb(20, 20, 22)
    Line = [Drawing.Color]::FromArgb(40, 40, 44); Text = [Drawing.Color]::FromArgb(243, 239, 230)
    Dim = [Drawing.Color]::FromArgb(150, 146, 138); Gold = [Drawing.Color]::FromArgb(201, 169, 106)
}
$FontUi    = New-Object Drawing.Font('Segoe UI', 9.5)
$FontSmall = New-Object Drawing.Font('Segoe UI', 8.5)
$FontTitle = New-Object Drawing.Font('Georgia', 17)
$FontHead  = New-Object Drawing.Font('Segoe UI Semibold', 8.5)

function New-Btn($text, $x, $y, $w = 120, $gold = $false) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 34)
    $b.FlatStyle = 'Flat'; $b.Font = $FontUi; $b.Cursor = 'Hand'
    $b.FlatAppearance.BorderColor = $(if ($gold) { $C.Gold } else { $C.Line })
    $b.BackColor = $(if ($gold) { $C.Gold } else { $C.Panel })
    $b.ForeColor = $(if ($gold) { $C.Bg } else { $C.Text })
    return $b
}
function New-Lbl($text, $x, $y, $font = $FontUi, $color = $null, $w = 300) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, 22)
    $l.Font = $font; $l.ForeColor = $(if ($color) { $color } else { $C.Text }); $l.BackColor = 'Transparent'
    return $l
}
function New-Chk($text, $x, $y, $checked) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $text; $c.Location = New-Object Drawing.Point($x, $y); $c.Size = New-Object Drawing.Size(250, 24)
    $c.Font = $FontUi; $c.ForeColor = $C.Text; $c.Checked = [bool]$checked; $c.Cursor = 'Hand'
    return $c
}
function New-Combo($items, $selected, $x, $y, $w = 130) {
    $c = New-Object Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'; $c.FlatStyle = 'Flat'; $c.Font = $FontUi
    $c.BackColor = $C.Panel; $c.ForeColor = $C.Text
    $c.Location = New-Object Drawing.Point($x, $y); $c.Width = $w
    foreach ($i in $items) { [void]$c.Items.Add($i) }
    $c.SelectedItem = $selected; if ($c.SelectedIndex -lt 0) { $c.SelectedIndex = 0 }
    return $c
}

# ---------- Main window ----------
$form = New-Object Windows.Forms.Form
$form.Text = $AppName; $form.Size = New-Object Drawing.Size(1100, 860); $form.MinimumSize = New-Object Drawing.Size(980, 860)
$form.StartPosition = 'CenterScreen'; $form.BackColor = $C.Bg; $form.ForeColor = $C.Text; $form.Font = $FontUi
$iconPath = Join-Path $PSScriptRoot '007.ico'
$appIcon = if (Test-Path -LiteralPath $iconPath) { New-Object Drawing.Icon($iconPath) } else { [Drawing.SystemIcons]::Application }
$form.Icon = $appIcon

$title = New-Lbl '007 · WALL SWITCHER' 24 18 $FontTitle $C.Text 400; $title.Height = 34
$sub   = New-Lbl 'Add your wallpapers. Click one to set it, right-click for more, or press Ctrl + Alt + W anywhere.' 26 54 $FontSmall $C.Dim 600
$form.Controls.AddRange(@($title, $sub))

# Library grid
$thumbs = New-Object Windows.Forms.ImageList
$thumbs.ImageSize = New-Object Drawing.Size(192, 108); $thumbs.ColorDepth = 'Depth32Bit'
$list = New-Object Windows.Forms.ListView
$list.View = 'LargeIcon'; $list.LargeImageList = $thumbs; $list.MultiSelect = $true
$list.BackColor = $C.Bg; $list.ForeColor = $C.Dim; $list.BorderStyle = 'None'; $list.Font = $FontSmall
$list.Location = New-Object Drawing.Point(24, 90); $list.Anchor = 'Top, Bottom, Left, Right'
$list.Size = New-Object Drawing.Size(690, 640)
$list.AllowDrop = $true
$form.Controls.Add($list)

$empty = New-Lbl 'No wallpapers yet. Click "Add pictures" or "Add folder", or drag images here.' 40 110 $FontUi $C.Dim 620
$empty.BackColor = $C.Bg
$form.Controls.Add($empty); $empty.BringToFront()

$bAdd    = New-Btn 'Add pictures' 24 746 130 $true
$bFolder = New-Btn 'Add folder' 162 746 120
$bRemove = New-Btn 'Remove' 290 746 100
foreach ($b in $bAdd, $bFolder, $bRemove) { $b.Anchor = 'Bottom, Left'; $form.Controls.Add($b) }

# Side panel
$side = New-Object Windows.Forms.Panel
$side.BackColor = $C.Panel; $side.Location = New-Object Drawing.Point(734, 90); $side.Size = New-Object Drawing.Size(330, 690)
$side.Anchor = 'Top, Bottom, Right'
$form.Controls.Add($side)

$y = 16
$side.Controls.Add((New-Lbl 'NOW SHOWING' 18 $y $FontHead $C.Gold)); $y += 24
$lCurrent = New-Lbl '-' 18 $y $FontUi $C.Text 280; $side.Controls.Add($lCurrent); $y += 30
$bPrev = New-Btn '< Prev' 18 $y 132; $bNext = New-Btn 'Next >' 160 $y 132 $true
$side.Controls.AddRange(@($bPrev, $bNext)); $y += 52

$side.Controls.Add((New-Lbl 'APPLY TO' 18 $y $FontHead $C.Gold)); $y += 24
$screenNames = @('All screens') + @($script:Screens | ForEach-Object { $_.Name })
$cbScreen = New-Combo $screenNames $screenNames[[math]::Min([int]$script:S.Screen, $screenNames.Count - 1)] 18 $y 274; $side.Controls.Add($cbScreen); $y += 32
$cEach = New-Chk 'Different picture on each screen' 18 $y $script:S.EachScreen; $cEach.Width = 280; $side.Controls.Add($cEach); $y += 26
$cLock = New-Chk 'Also change the lock screen' 18 $y $script:S.LockScreen; $cLock.Width = 280; $side.Controls.Add($cLock); $y += 36

$side.Controls.Add((New-Lbl 'AUTO CHANGE' 18 $y $FontHead $C.Gold)); $y += 24
$cAuto = New-Chk 'Change wallpaper every' 18 $y $script:S.AutoChange; $side.Controls.Add($cAuto); $y += 28
$Intervals = [ordered]@{ '1 minute' = 1; '5 minutes' = 5; '15 minutes' = 15; '30 minutes' = 30; '1 hour' = 60; '3 hours' = 180; '6 hours' = 360; '1 day' = 1440 }
$curInt = ($Intervals.Keys | Where-Object { $Intervals[$_] -eq [int]$script:S.Interval } | Select-Object -First 1)
$cbInt = New-Combo $Intervals.Keys $curInt 38 $y 150; $side.Controls.Add($cbInt); $y += 34
$cShuffle = New-Chk 'Shuffle' 18 $y $script:S.Shuffle; $side.Controls.Add($cShuffle); $y += 28
$lNext = New-Lbl '' 38 $y $FontSmall $C.Dim 260; $side.Controls.Add($lNext); $y += 30

$side.Controls.Add((New-Lbl 'TIME OF DAY' 18 $y $FontHead $C.Gold)); $y += 24
$cTod = New-Chk 'Use a folder per time of day' 18 $y $script:S.TimeOfDay; $side.Controls.Add($cTod); $y += 28
$bTod = New-Btn 'Choose folders...' 38 $y 150; $side.Controls.Add($bTod); $y += 50

$side.Controls.Add((New-Lbl 'OPTIONS' 18 $y $FontHead $C.Gold)); $y += 24
$side.Controls.Add((New-Lbl 'Picture position' 18 ($y + 4) $FontUi $C.Text 120))
$cbFit = New-Combo $FitModes.Keys $script:S.Fit 150 $y 140; $side.Controls.Add($cbFit); $y += 34
$cStart = New-Chk 'Start with Windows' 18 $y $script:S.Startup; $side.Controls.Add($cStart); $y += 26
$cHot = New-Chk 'Quick picker: Ctrl + Alt + W' 18 $y $script:S.Hotkey; $cHot.Width = 280; $side.Controls.Add($cHot); $y += 40

$lLic = New-Lbl '' 18 $y $FontSmall $C.Dim 280; $side.Controls.Add($lLic); $y += 24
$bKey = New-Btn 'Enter key' 18 $y 132; $bBuy = New-Btn 'Buy key $2.99' 160 $y 132 $true
$side.Controls.AddRange(@($bKey, $bBuy)); $y += 46

$lPacks = New-Object Windows.Forms.LinkLabel
$lPacks.Text = 'Get 007 Signature wallpaper packs'; $lPacks.Location = New-Object Drawing.Point(18, $y); $lPacks.Size = New-Object Drawing.Size(280, 20)
$lPacks.LinkColor = $C.Gold; $lPacks.ActiveLinkColor = $C.Text; $lPacks.Font = $FontSmall
$side.Controls.Add($lPacks)

$footer = New-Lbl "v$AppVersion  ·  Closing the window keeps it running in the tray." 24 792 $FontSmall $C.Dim 640
$footer.Anchor = 'Bottom, Left'; $form.Controls.Add($footer)

# ---------- Library ----------
function Get-ThumbKey([string]$path) {
    $md5 = [Security.Cryptography.MD5]::Create()
    $t = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
    return ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$path|$t"))) -replace '-', '')
}

function Get-Thumb([string]$path) {
    $key = Get-ThumbKey $path
    $file = Join-Path $ThumbDir "$key.jpg"
    if (-not (Test-Path -LiteralPath $file)) {
        $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($path))
        $src = [Drawing.Image]::FromStream($ms)
        $tw = 192; $th = 108
        $bmp = New-Object Drawing.Bitmap($tw, $th)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = 'HighQualityBicubic'; $g.Clear($C.Panel)
        $scale = [math]::Max($tw / $src.Width, $th / $src.Height)
        $w = $src.Width * $scale; $h = $src.Height * $scale
        $g.DrawImage($src, [single](($tw - $w) / 2), [single](($th - $h) / 2), [single]$w, [single]$h)
        $g.Dispose(); $src.Dispose(); $ms.Dispose()
        $bmp.Save($file, [Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
    }
    $ms2 = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($file))
    return [Drawing.Image]::FromStream($ms2)
}

function Refresh-Library {
    $list.BeginUpdate(); $list.Items.Clear(); $thumbs.Images.Clear()
    $keep = @()
    foreach ($p in $script:S.Library) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $thumbs.Images.Add($p, (Get-Thumb $p))
            $item = New-Object Windows.Forms.ListViewItem([IO.Path]::GetFileNameWithoutExtension($p), $p)
            $item.Tag = $p; $item.ToolTipText = $p
            [void]$list.Items.Add($item); $keep += $p
        } catch { }
        [Windows.Forms.Application]::DoEvents()
    }
    $list.EndUpdate()
    $script:S.Library = $keep; Save-Settings
    $empty.Visible = ($keep.Count -eq 0)
    Update-Status
}

function Add-ToLibrary([string[]]$paths) {
    $form.Cursor = 'WaitCursor'
    $lib = [Collections.Generic.List[string]]::new()
    foreach ($p in $script:S.Library) { $lib.Add($p) }
    foreach ($p in $paths) {
        if ((Test-Path -LiteralPath $p -PathType Container)) { foreach ($f in (Get-ImagesIn $p)) { if (-not $lib.Contains($f)) { $lib.Add($f) } } }
        elseif ($ImageExt -contains ([IO.Path]::GetExtension($p).ToLower()) -and -not $lib.Contains($p)) { $lib.Add($p) }
    }
    $script:S.Library = @($lib)
    Refresh-Library
    $form.Cursor = 'Default'
}

# ---------- Timer and status ----------
$script:NextAt = (Get-Date).AddMinutes([int]$script:S.Interval)
$script:LastSlot = Get-Slot
function Reset-Timer { $script:NextAt = (Get-Date).AddMinutes([int]$script:S.Interval) }

function Update-Status {
    $lCurrent.Text = $(if ($script:S.Current) { [IO.Path]::GetFileNameWithoutExtension($script:S.Current) } else { '-' })
    $lNext.Text = $(if ($script:S.AutoChange -and @(Get-Pool).Count) { 'Next change at ' + $script:NextAt.ToString('HH:mm') } else { 'Paused' })
    if (Test-Key $script:S.Key) { $lLic.Text = 'Full version. Thank you!'; $lLic.ForeColor = $C.Gold; $bKey.Visible = $false; $bBuy.Visible = $false }
    else {
        $left = Get-TrialLeft
        $lLic.Text = $(if ($left -gt 0) { "Free trial: $left day$(if ($left -ne 1) { 's' }) left" } else { 'Trial ended. Enter a key to keep using it.' })
        $lLic.ForeColor = $(if ($left -gt 0) { $C.Dim } else { $C.Gold })
    }
    if ($script:TrayPause) { $script:TrayPause.Text = $(if ($script:S.AutoChange) { 'Pause auto change' } else { 'Resume auto change' }) }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    $slot = Get-Slot
    $slotChanged = ($script:S.TimeOfDay -and $slot -ne $script:LastSlot)
    $script:LastSlot = $slot
    if ($script:S.AutoChange -and ($slotChanged -or (Get-Date) -ge $script:NextAt) -and (Test-Unlocked)) { Step-Wallpaper 1 }
})

# ---------- Dialogs ----------
function Show-KeyDialog {
    $d = New-Object Windows.Forms.Form
    $d.Text = 'Unlock 007 Wall Switcher'; $d.Size = New-Object Drawing.Size(460, 290); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.BackColor = $C.Bg; $d.ForeColor = $C.Text; $d.Icon = $appIcon
    $d.Controls.Add((New-Lbl 'Unlock the full version' 24 20 (New-Object Drawing.Font('Georgia', 14)) $C.Text 400))
    $info = New-Lbl "Buy a key for `$2.99 with Whish or crypto on the 007 website. You get the key in your Discord ticket. Paste it below." 24 58 $FontSmall $C.Dim 400
    $info.Height = 40; $d.Controls.Add($info)
    $tb = New-Object Windows.Forms.TextBox
    $tb.Location = New-Object Drawing.Point(24, 108); $tb.Width = 396; $tb.Font = New-Object Drawing.Font('Consolas', 12)
    $tb.BackColor = $C.Panel; $tb.ForeColor = $C.Text; $tb.BorderStyle = 'FixedSingle'; $tb.CharacterCasing = 'Upper'
    $tb.Text = $script:S.Key
    $d.Controls.Add($tb)
    $msg = New-Lbl '' 24 146 $FontSmall $C.Gold 400; $d.Controls.Add($msg)
    $ok = New-Btn 'Activate' 24 180 190 $true; $buy = New-Btn 'Buy a key ($2.99)' 230 180 190
    $d.Controls.AddRange(@($ok, $buy)); $d.AcceptButton = $ok
    $ok.Add_Click({
        if (Test-Key $tb.Text) {
            $script:S.Key = ($tb.Text.ToUpper() -replace '\s', ''); Save-Settings; Update-Status
            [Windows.Forms.MessageBox]::Show('Activated. Enjoy the full version!', $AppName) | Out-Null; $d.Close()
        } else { $msg.Text = 'That key is not valid. Check it and try again.' }
    })
    $buy.Add_Click({ Start-Process $ShopUrl })
    [void]$d.ShowDialog($form)
}

function Show-TodDialog {
    $d = New-Object Windows.Forms.Form
    $d.Text = 'Time of day folders'; $d.Size = New-Object Drawing.Size(560, 330); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.BackColor = $C.Bg; $d.ForeColor = $C.Text; $d.Icon = $appIcon
    $d.Controls.Add((New-Lbl 'Pick a folder for each time of day. Empty slots use your library.' 20 16 $FontSmall $C.Dim 500))
    $slots = [ordered]@{ Morning = '6:00 - 12:00'; Day = '12:00 - 17:00'; Evening = '17:00 - 21:00'; Night = '21:00 - 6:00' }
    $boxes = @{}; $yy = 48
    foreach ($name in $slots.Keys) {
        $d.Controls.Add((New-Lbl $name 20 ($yy + 6) $FontUi $C.Text 80))
        $d.Controls.Add((New-Lbl $slots[$name] 100 ($yy + 6) $FontSmall $C.Dim 100))
        $tb = New-Object Windows.Forms.TextBox
        $tb.Location = New-Object Drawing.Point(200, ($yy + 3)); $tb.Width = 230; $tb.ReadOnly = $true
        $tb.BackColor = $C.Panel; $tb.ForeColor = $C.Text; $tb.BorderStyle = 'FixedSingle'; $tb.Text = $script:S.$name
        $d.Controls.Add($tb); $boxes[$name] = $tb
        $b = New-Btn 'Browse' 440 $yy 80; $b.Tag = $name
        $b.Add_Click({
            $fb = New-Object Windows.Forms.FolderBrowserDialog
            if ($fb.ShowDialog() -eq 'OK') { $boxes[$this.Tag].Text = $fb.SelectedPath }
        })
        $d.Controls.Add($b); $yy += 44
    }
    $save = New-Btn 'Save' 20 ($yy + 10) 120 $true; $clear = New-Btn 'Clear all' 150 ($yy + 10) 120
    $save.Add_Click({ foreach ($n in $boxes.Keys) { $script:S.$n = $boxes[$n].Text }; Save-Settings; $d.Close() })
    $clear.Add_Click({ foreach ($n in $boxes.Keys) { $boxes[$n].Text = '' } })
    $d.Controls.AddRange(@($save, $clear))
    [void]$d.ShowDialog($form)
}

function Set-Startup([bool]$on) {
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($on) {
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Tray"
        Set-ItemProperty -Path $run -Name '007 Wall Switcher' -Value $cmd
    } else { Remove-ItemProperty -Path $run -Name '007 Wall Switcher' -ErrorAction SilentlyContinue }
}

# ---------- Events ----------
$bAdd.Add_Click({
    $od = New-Object Windows.Forms.OpenFileDialog
    $od.Multiselect = $true; $od.Title = 'Add wallpapers'
    $od.Filter = 'Images (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp'
    if ($od.ShowDialog() -eq 'OK') { Add-ToLibrary $od.FileNames }
})
$bFolder.Add_Click({
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Add every image in this folder'
    if ($fb.ShowDialog() -eq 'OK') { Add-ToLibrary @($fb.SelectedPath) }
})
$bRemove.Add_Click({
    $sel = @($list.SelectedItems | ForEach-Object { $_.Tag })
    if (-not $sel.Count) { return }
    $script:S.Library = @($script:S.Library | Where-Object { $sel -notcontains $_ })
    Refresh-Library
})
$list.Add_DragEnter({ if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
$list.Add_DragDrop({ Add-ToLibrary ([string[]]$_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)) })
$list.Add_ItemActivate({ if ($list.SelectedItems.Count) { if (Set-Wallpaper $list.SelectedItems[0].Tag) { Reset-Timer; Update-Status } } })
$list.Add_KeyDown({ if ($_.KeyCode -eq 'Delete') { $bRemove.PerformClick() } })

$bNext.Add_Click({ Step-Wallpaper 1 })
$bPrev.Add_Click({ Step-Wallpaper -1 })
$cAuto.Add_CheckedChanged({ $script:S.AutoChange = $cAuto.Checked; Reset-Timer; Save-Settings; Update-Status })
$cbInt.Add_SelectedIndexChanged({ $script:S.Interval = $Intervals[$cbInt.SelectedItem]; Reset-Timer; Save-Settings; Update-Status })
$cShuffle.Add_CheckedChanged({ $script:S.Shuffle = $cShuffle.Checked; Save-Settings })
$cTod.Add_CheckedChanged({ $script:S.TimeOfDay = $cTod.Checked; Save-Settings; if ($cTod.Checked -and -not ($script:S.Morning + $script:S.Day + $script:S.Evening + $script:S.Night)) { Show-TodDialog } })
$bTod.Add_Click({ Show-TodDialog })
$cbFit.Add_SelectedIndexChanged({ $script:S.Fit = [string]$cbFit.SelectedItem; Save-Settings; if ($script:S.Current -and (Test-Unlocked)) { [void](Set-Wallpaper $script:S.Current) } })
$cStart.Add_CheckedChanged({ $script:S.Startup = $cStart.Checked; Set-Startup $cStart.Checked; Save-Settings })
$bKey.Add_Click({ Show-KeyDialog })
$bBuy.Add_Click({ Start-Process $ShopUrl })
$lPacks.Add_LinkClicked({ Start-Process $PacksUrl })

$cbScreen.Add_SelectedIndexChanged({ $script:S.Screen = $cbScreen.SelectedIndex; Save-Settings })
$cEach.Add_CheckedChanged({ $script:S.EachScreen = $cEach.Checked; Save-Settings })
$cLock.Add_CheckedChanged({ $script:S.LockScreen = $cLock.Checked; Save-Settings })

# Right-click a wallpaper: choose where it goes.
$itemMenu = New-Object Windows.Forms.ContextMenuStrip
$list.ContextMenuStrip = $itemMenu
$itemMenu.Add_Opening({
    $itemMenu.Items.Clear()
    if (-not $list.SelectedItems.Count) { $_.Cancel = $true; return }
    $p = $list.SelectedItems[0].Tag
    $m = $itemMenu.Items.Add('Set on all screens'); $m.Tag = @($p, 'all'); $m.Add_Click({ [void](Set-Wallpaper $this.Tag[0] $this.Tag[1]); Reset-Timer })
    for ($i = 0; $i -lt $script:Screens.Count; $i++) {
        $m = $itemMenu.Items.Add("Set on $($script:Screens[$i].Name)"); $m.Tag = @($p, $i); $m.Add_Click({ [void](Set-Wallpaper $this.Tag[0] $this.Tag[1]); Reset-Timer })
    }
    $m = $itemMenu.Items.Add('Set as lock screen'); $m.Tag = @($p, 'lock'); $m.Add_Click({ [void](Set-Wallpaper $this.Tag[0] $this.Tag[1]) })
    [void]$itemMenu.Items.Add('-')
    $m = $itemMenu.Items.Add('Show in folder'); $m.Tag = $p; $m.Add_Click({ Start-Process explorer.exe "/select,`"$($this.Tag)`"" })
    $m = $itemMenu.Items.Add('Remove from library'); $m.Add_Click({ $bRemove.PerformClick() })
    $_.Cancel = $false
})

# ---------- Quick picker (Ctrl + Alt + W) ----------
$picker = New-Object Windows.Forms.Form
$picker.FormBorderStyle = 'None'; $picker.WindowState = 'Maximized'; $picker.TopMost = $true; $picker.ShowInTaskbar = $false
$picker.BackColor = $C.Bg; $picker.Opacity = 0.97; $picker.KeyPreview = $true; $picker.StartPosition = 'Manual'
$pTitle = New-Lbl 'Pick a wallpaper' 60 40 (New-Object Drawing.Font('Georgia', 24)) $C.Text 600; $pTitle.Height = 44
$pHint  = New-Lbl 'Click to set it  ·  Right-click for more  ·  Esc to close' 62 90 $FontUi $C.Dim 700
$pList = New-Object Windows.Forms.ListView
$pList.View = 'LargeIcon'; $pList.LargeImageList = $thumbs; $pList.MultiSelect = $false; $pList.Activation = 'OneClick'; $pList.HotTracking = $true
$pList.BackColor = $C.Bg; $pList.ForeColor = $C.Dim; $pList.BorderStyle = 'None'; $pList.Font = $FontSmall
$pList.Location = New-Object Drawing.Point(60, 130); $pList.Anchor = 'Top, Bottom, Left, Right'
$pList.ContextMenuStrip = $itemMenu
$picker.Controls.AddRange(@($pTitle, $pHint, $pList))
$picker.Add_Resize({ $pList.Size = New-Object Drawing.Size(($picker.ClientSize.Width - 120), ($picker.ClientSize.Height - 170)) })
$picker.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $picker.Hide() } })
$picker.Add_Deactivate({ if (-not $itemMenu.Visible) { $picker.Hide() } })
$picker.Add_FormClosing({ if (-not $script:Exiting) { $_.Cancel = $true; $picker.Hide() } })
$pList.Add_ItemActivate({
    if ($pList.SelectedItems.Count) { $p = $pList.SelectedItems[0].Tag; $picker.Hide(); if (Set-Wallpaper $p) { Reset-Timer } }
})
# Right-click in the picker uses the same menu, but it reads the main list's selection; keep them in sync.
$pList.Add_MouseDown({
    $hit = $pList.HitTest($_.Location)
    if ($hit.Item) { $list.SelectedItems.Clear(); foreach ($it in $list.Items) { if ($it.Tag -eq $hit.Item.Tag) { $it.Selected = $true } } }
})

function Show-Picker {
    if (-not $list.Items.Count) { Show-Main; return }
    $pList.BeginUpdate(); $pList.Items.Clear()
    foreach ($it in $list.Items) {
        $n = New-Object Windows.Forms.ListViewItem($it.Text, $it.ImageKey); $n.Tag = $it.Tag
        [void]$pList.Items.Add($n)
    }
    $pList.EndUpdate()
    $scr = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position)
    $picker.WindowState = 'Normal'; $picker.Bounds = $scr.Bounds; $picker.WindowState = 'Maximized'
    $picker.Show(); $picker.Activate(); $pList.Focus()
}

$script:Hot = New-Object HotkeyWindow
$script:Hot.add_Pressed({ if ($picker.Visible) { $picker.Hide() } else { Show-Picker } })
function Set-Hotkey([bool]$on) {
    [void][W007]::UnregisterHotKey($script:Hot.Handle, 1)
    if ($on) {
        # MOD_ALT 0x1 + MOD_CONTROL 0x2 + MOD_NOREPEAT 0x4000, key W = 0x57
        if (-not [W007]::RegisterHotKey($script:Hot.Handle, 1, 0x4003, 0x57)) {
            $cHot.Text = 'Quick picker: Ctrl + Alt + W (in use by another app)'
        }
    }
}
$cHot.Add_CheckedChanged({ $script:S.Hotkey = $cHot.Checked; Set-Hotkey $cHot.Checked; Save-Settings })
Set-Hotkey ([bool]$script:S.Hotkey)

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
$miSite = $menu.Items.Add('Get wallpaper packs')
$miExit = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu

function Show-Main { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }
$miOpen.Add_Click({ Show-Main })
$tray.Add_MouseDoubleClick({ Show-Main })
$miNext.Add_Click({ Step-Wallpaper 1 })
$miPick.Add_Click({ Show-Picker })
$script:TrayPause.Add_Click({ $cAuto.Checked = -not $cAuto.Checked })
$miSite.Add_Click({ Start-Process $PacksUrl })
$miExit.Add_Click({ $script:Exiting = $true; $tray.Visible = $false; $timer.Stop(); $form.Close(); [Windows.Forms.Application]::Exit() })

$form.Add_FormClosing({
    if (-not $script:Exiting -and $_.CloseReason -eq 'UserClosing') {
        $_.Cancel = $true; $form.Hide()
        if (-not $script:ToldTray) {
            $tray.ShowBalloonTip(3000, $AppName, 'Still running here. Right-click this icon to change wallpaper or exit.', 'Info'); $script:ToldTray = $true
        }
    }
})
$form.Add_Shown({
    Refresh-Library
    if (-not (Test-Unlocked)) { Show-KeyDialog }
})

# ---------- Start ----------
if ($script:S.Startup) { Set-Startup $true }   # keep the startup path current if the app was moved
Update-Status
$timer.Start()
$appCtx = New-Object Windows.Forms.ApplicationContext
if (-not $Tray) { Show-Main } else { Refresh-Library }
[Windows.Forms.Application]::Run($appCtx)
$tray.Dispose()
[void][W007]::UnregisterHotKey($script:Hot.Handle, 1); $script:Hot.Dispose()
$script:Mutex.ReleaseMutex()
