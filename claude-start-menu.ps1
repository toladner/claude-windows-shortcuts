<#
Mirrors the 5 most recently active Claude Code sessions into Start Menu\Programs\Claude Sessions.
Each shortcut opens Windows Terminal in the session's working directory and runs `claude --resume <id>`.
#>
param([int]$Count = 5, [string]$Exclude = '^Tuxedo')

$projects = Join-Path $env:USERPROFILE '.claude\projects'
$menuDir  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude Sessions'
$claude   = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$wt       = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'

function Get-SessionInfo($file) {
    $title = $null; $prompt = $null; $cwd = $null
    # Titles can be re-set later in the session, so the last one wins.
    foreach ($m in Select-String -LiteralPath $file.FullName -Pattern '"type":"(custom-title|ai-title)"' -SimpleMatch:$false) {
        $o = $m.Line | ConvertFrom-Json
        if ($o.customTitle) { $title = $o.customTitle } elseif (-not $title -and $o.aiTitle) { $title = $o.aiTitle }
    }
    $reader = [IO.StreamReader]::new($file.FullName)
    try {
        # The cwd and first prompt sit near the top; avoid reading multi-MB transcripts in full.
        for ($i = 0; $i -lt 400 -and -not ($cwd -and $prompt); $i++) {
            $line = $reader.ReadLine(); if ($null -eq $line) { break }
            if ($line -notmatch '"type":"user"') { continue }
            $o = try { $line | ConvertFrom-Json } catch { continue }
            if (-not $cwd -and $o.cwd) { $cwd = $o.cwd }
            if (-not $prompt -and -not $o.isMeta) {
                $c = $o.message.content
                $text = if ($c -is [string]) { $c } else { ($c | Where-Object type -eq 'text' | Select-Object -First 1).text }
                if ($text -and $text -notmatch '^\s*<') { $prompt = $text }
            }
        }
    } finally { $reader.Dispose() }
    if (-not $cwd) { return $null }
    if (-not $title) { $title = if ($prompt) { $prompt } else { Split-Path $cwd -Leaf } }
    $title = ($title -replace '\s+', ' ').Trim()
    if ($title.Length -gt 60) { $title = $title.Substring(0, 57) + '...' }
    [pscustomobject]@{ Id = $file.BaseName; Cwd = $cwd; Title = $title; Time = $file.LastWriteTime }
}

$sessions = Get-ChildItem $projects -Directory | ForEach-Object {
    Get-ChildItem $_.FullName -Filter *.jsonl -File | Where-Object { $_.BaseName -match '^[0-9a-f-]{36}$' }
} | Sort-Object LastWriteTime -Descending | ForEach-Object { Get-SessionInfo $_ } |
    Where-Object { $_ -and $_.Title -notmatch $Exclude } | Select-Object -First $Count

New-Item -ItemType Directory -Force $menuDir | Out-Null
$shell = New-Object -ComObject WScript.Shell

$wanted = [ordered]@{}
foreach ($s in $sessions) {
    $name = ($s.Title -replace '[\/:*?"<>|]', '_').TrimEnd('.', ' ')
    if ($wanted.Contains("$name.lnk")) { $name += " ($($s.Id.Substring(0, 8)))" }
    $wanted["$name.lnk"] = $s
}

# Only touch changed shortcuts: rewriting a .lnk makes Start list it again as "recently added".
foreach ($f in Get-ChildItem $menuDir -Filter *.lnk) {
    $s = $wanted[$f.Name]
    if (-not $s -or $shell.CreateShortcut($f.FullName).Arguments -notmatch [regex]::Escape($s.Id)) { Remove-Item $f.FullName -Force }
}
foreach ($name in $wanted.Keys) {
    $path = Join-Path $menuDir $name
    if (Test-Path $path) { continue }
    $s = $wanted[$name]
    $lnk = $shell.CreateShortcut($path)
    if (Test-Path $wt) {
        $lnk.TargetPath = $wt
        $lnk.Arguments  = "-d `"$($s.Cwd)`" `"$claude`" --resume $($s.Id)"
    } else {
        $lnk.TargetPath = (Get-Command powershell.exe).Source
        $lnk.Arguments  = "-NoExit -Command & '$claude' --resume $($s.Id)"
    }
    $lnk.WorkingDirectory = $s.Cwd
    $lnk.IconLocation     = "$claude,0"
    $lnk.Description      = $s.Cwd
    $lnk.Save()
}
