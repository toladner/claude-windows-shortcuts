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

# A bridge only archives its claude.ai session on a clean exit, so sessions killed by shutdown linger in the
# Remote Control list. None is running locally now, so every remote one with this name is stale.
try {
    $token = (Get-Content (Join-Path $claudeHome '.credentials.json') -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
    # Regex, not ConvertFrom-Json: .claude.json has project keys differing only in case, which it rejects.
    $org = [regex]::Match((Get-Content (Join-Path $env:USERPROFILE '.claude.json') -Raw), '"organizationUuid"\s*:\s*"([0-9a-f-]+)"').Groups[1].Value
    $headers = @{
        'Authorization'      = "Bearer $token"
        'anthropic-version'  = '2023-06-01'
        'anthropic-beta'     = 'ccr-byoc-2025-07-29'
        'x-organization-uuid' = $org
    }
    $api = 'https://api.anthropic.com/v1/sessions'
    $stale = @()
    $after = $null
    do {
        $url = $api + $(if ($after) { "?after_id=$after" } else { '' })
        $page = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 30
        $stale += @($page.data | Where-Object { $_.title -eq $name -and $_.environment_kind -eq 'bridge' -and $_.session_status -ne 'archived' -and $_.connection_status -ne 'connected' })
        $after = $page.last_id
    } while ($page.has_more -and $after)
    foreach ($r in $stale) {
        Invoke-RestMethod -Uri "$api/$($r.id)/archive" -Headers $headers -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec 30 | Out-Null
        "$(Get-Date -Format s) archived remote $($r.id)" | Add-Content $log
    }
} catch {
    "$(Get-Date -Format s) remote cleanup failed: $($_.Exception.Message)" | Add-Content $log
}

$out = & $claude --bg --name $name --remote-control $name --model opus 2>&1
"$(Get-Date -Format s) started new: $out" | Add-Content $log
