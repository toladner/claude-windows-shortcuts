# Ensures a temporary background Claude session "<computer-name>-temp" with Remote Control is running in the Desktop folder.
# Each start discards previous sessions of that name and their transcripts, so nothing is kept long term.
# Set CLAUDE_TEMP_SESSION to use a different session name.
$name = if ($env:CLAUDE_TEMP_SESSION) { $env:CLAUDE_TEMP_SESSION } else { "$($env:COMPUTERNAME.ToLower())-temp" }
$cwd = Join-Path $env:USERPROFILE 'Desktop'
$claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$claudeHome = Join-Path $env:USERPROFILE '.claude'
$log = Join-Path $PSScriptRoot 'start-temp-session.log'

Set-Location $cwd
# Give networking and login a moment to settle after boot.
Start-Sleep -Seconds 20

# Parentheses unroll the JSON array; Windows PowerShell 5.1 otherwise passes it to Where-Object as one object.
$sessions = @((& $claude agents --json --all 2>$null | ConvertFrom-Json) | Where-Object { $_.name -eq $name })
$running = $sessions | Where-Object { $_.pid -and (Get-Process -Id $_.pid -ErrorAction SilentlyContinue) } | Select-Object -First 1

if ($running) {
    "$(Get-Date -Format s) already running ($($running.id))" | Add-Content $log
    exit 0
}

# --no-session-persistence only works with --print, so old sessions are deleted by hand instead.
foreach ($s in $sessions) {
    $sid = $s.sessionId
    if (-not $sid) { continue }
    & $claude rm $sid 2>&1 | Out-Null
    Get-ChildItem (Join-Path $claudeHome 'projects') -Directory | ForEach-Object {
        Get-ChildItem $_.FullName -Filter "$sid*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($dir in 'file-history', 'session-env', 'todos') {
        Get-ChildItem (Join-Path $claudeHome $dir) -Filter "$sid*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($s.id) { Remove-Item (Join-Path $claudeHome "jobs\$($s.id)") -Recurse -Force -ErrorAction SilentlyContinue }
    "$(Get-Date -Format s) discarded $sid" | Add-Content $log
}

$out = & $claude --bg --name $name --remote-control $name --model opus 2>&1
"$(Get-Date -Format s) started new: $out" | Add-Content $log
