# Tray icon for the "Tuxedo-general" background Claude session.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$name = 'Tuxedo-general'
$claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$desktop = Join-Path $env:USERPROFILE 'Desktop'
$scriptDir = $PSScriptRoot

# Single instance, so repeated logons or manual runs don't stack icons.
$mutex = New-Object System.Threading.Mutex($false, 'Local\TuxedoGeneralTray')
if (-not $mutex.WaitOne(0)) { exit 0 }

function Get-Session {
    # Parentheses unroll the JSON array; Windows PowerShell 5.1 otherwise passes it to Where-Object as one object.
    (& $claude agents --json 2>$null | ConvertFrom-Json) | Where-Object { $_.name -eq $name } | Select-Object -First 1
}

function Get-RemoteUrl($session) {
    $text = (& $claude logs $session.id 2>&1) -join "`n"
    $m = [regex]::Matches($text, 'https://claude\.ai/code/session_[A-Za-z0-9]+')
    if ($m.Count) { $m[$m.Count - 1].Value }
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-Object System.Drawing.Icon (Join-Path $PSScriptRoot 'tuxedo-tray.ico'), 32, 32
$tray.Text = $name
$tray.Visible = $true

$openWeb = {
    $s = Get-Session
    $url = if ($s) { Get-RemoteUrl $s }
    if ($url) { Start-Process $url }
    else { $tray.ShowBalloonTip(3000, $name, 'Session not running or no Remote Control URL yet.', 'Warning') }
}

Add-Type -Namespace Tuxedo -Name Win32 -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int w, int ht, uint flags);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
public struct RECT { public int Left, Top, Right, Bottom; }
'@
# Physical pixels, so screen and window coordinates agree under display scaling.
[Tuxedo.Win32]::SetProcessDPIAware() | Out-Null

function Get-TerminalWindows {
    $found = New-Object System.Collections.Generic.List[IntPtr]
    $cb = [Tuxedo.Win32+EnumProc] {
        param($h, $p)
        $sb = New-Object System.Text.StringBuilder 64
        [Tuxedo.Win32]::GetClassName($h, $sb, 64) | Out-Null
        if ($sb.ToString() -eq 'CASCADIA_HOSTING_WINDOW_CLASS' -and [Tuxedo.Win32]::IsWindowVisible($h)) { $found.Add($h) }
        $true
    }
    [Tuxedo.Win32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    , $found
}

# Pixel size of the terminal window and the offset between wt.exe --pos and where the window lands, learned from the last launch.
$geometryFile = Join-Path $PSScriptRoot 'tuxedo-tray-geometry.json'
$script:geometry = try { Get-Content $geometryFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
if (-not ($script:geometry.w -gt 0 -and $script:geometry.h -gt 0)) { $script:geometry = [pscustomobject]@{ w = 1039; h = 673; dx = -8; dy = 0 } }

# Loading popup shown in the corner while the terminal starts.
$scale = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero).DpiX / 96
$splash = New-Object System.Windows.Forms.Form
$splash.FormBorderStyle = 'None'
$splash.ShowInTaskbar = $false
$splash.TopMost = $true
$splash.StartPosition = 'Manual'
$splash.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
$splash.Size = New-Object System.Drawing.Size ([int](280 * $scale)), ([int](56 * $scale))
$splashLabel = New-Object System.Windows.Forms.Label
$splashLabel.Dock = 'Fill'
$splashLabel.TextAlign = 'MiddleLeft'
$splashLabel.Padding = New-Object System.Windows.Forms.Padding ([int](16 * $scale)), 0, 0, 0
$splashLabel.ForeColor = [System.Drawing.Color]::White
$splashLabel.Font = New-Object System.Drawing.Font 'Segoe UI', 11
$splash.Controls.Add($splashLabel)

$spinnerFrames = [char[]]'⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
$script:frame = 0
$spinner = New-Object System.Windows.Forms.Timer
$spinner.Interval = 80
$spinner.add_Tick({
    $script:frame = ($script:frame + 1) % $spinnerFrames.Length
    $splashLabel.Text = "$($spinnerFrames[$script:frame])   Opening $name…"
})

function Hide-Splash { $spinner.Stop(); $poll.Stop(); $splash.Hide(); $script:opening = $false }

# Waits for the new terminal window without blocking the UI thread, so the spinner keeps animating.
$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 50
$poll.add_Tick({
    $script:pollTicks++
    if ($script:pollTicks -gt 200) { Hide-Splash; return }
    $new = (Get-TerminalWindows) | Where-Object { $script:before -notcontains $_ } | Select-Object -First 1
    if (-not $new) { return }

    $r = New-Object Tuxedo.Win32+RECT
    [Tuxedo.Win32]::GetWindowRect($new, [ref]$r) | Out-Null
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $area = $script:area
    # The window is created off-screen and only then moved to --pos; wait for that.
    if ($r.Right -le $area.Left -or $r.Bottom -le $area.Top) { return }
    $x = $area.Right - [Math]::Min($w, $area.Width); $y = $area.Bottom - [Math]::Min($h, $area.Height)
    # Only correct (and remember) when the guess was off, e.g. on first launch or after a display scaling change.
    if ($r.Left -ne $x -or $r.Top -ne $y) {
        # SWP_NOZORDER | SWP_NOACTIVATE
        [Tuxedo.Win32]::SetWindowPos($new, [IntPtr]::Zero, $x, $y, [Math]::Min($w, $area.Width), [Math]::Min($h, $area.Height), 0x14) | Out-Null
        $dx = $r.Left - $script:posX; $dy = $r.Top - $script:posY
        # A large offset means wt.exe clamped the position rather than applying it, so keep the known offset.
        if ([Math]::Abs($dx) -gt 50 -or [Math]::Abs($dy) -gt 50) { $dx = $script:geometry.dx; $dy = $script:geometry.dy }
        $script:geometry = [pscustomobject]@{ w = $w; h = $h; dx = $dx; dy = $dy }
        $script:geometry | ConvertTo-Json | Set-Content $geometryFile
    }
    [Tuxedo.Win32]::SetForegroundWindow($new) | Out-Null
    Hide-Splash
})

$openTerminal = {
    if ($script:opening) { return }
    $script:opening = $true

    # The clicked icon sits on the taskbar of the screen under the cursor.
    $script:area = $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $splash.Location = New-Object System.Drawing.Point ($area.Right - $splash.Width - [int](12 * $scale)), ($area.Bottom - $splash.Height - [int](12 * $scale))
    $splashLabel.Text = "$($spinnerFrames[0])   Opening $name…"
    $splash.Show()
    $splash.Refresh()
    $spinner.Start()

    $s = Get-Session
    if (-not $s) { Hide-Splash; $tray.ShowBalloonTip(3000, $name, 'Session not running.', 'Warning'); return }

    # Open directly at the corner, so the window doesn't jump there after appearing.
    $g = $script:geometry
    $script:posX = $area.Right - $g.w - $g.dx
    $script:posY = $area.Bottom - $g.h - $g.dy
    $script:before = Get-TerminalWindows
    $script:pollTicks = 0
    Start-Process wt.exe -ArgumentList "-w new --size 110,32 --pos $($script:posX),$($script:posY) -d `"$desktop`" `"$claude`" attach $($s.id)"
    $poll.Start()
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Items.Add('Open in browser', $null, $openWeb) | Out-Null
$menu.Items.Add('Open in terminal', $null, $openTerminal) | Out-Null
$menu.Items.Add('Restart session', $null, {
    $s = Get-Session
    if ($s) { & $claude stop $s.id 2>&1 | Out-Null }
    Start-Process conhost.exe -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptDir\start-tuxedo-general.ps1`""
}) | Out-Null
$menu.Items.Add('-') | Out-Null
$menu.Items.Add('Hide icon', $null, { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() }) | Out-Null

# Refresh the hover text with the live status whenever the menu opens.
$menu.add_Opening({
    $s = Get-Session
    $tray.Text = if ($s) { "$name ($($s.status))" } else { "$name (not running)" }
})

$tray.ContextMenuStrip = $menu
# Left click opens the terminal; right click shows the menu.
$tray.add_MouseClick({ if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $openTerminal } })

[System.Windows.Forms.Application]::Run()
$tray.Dispose()
