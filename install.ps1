# Registers logon tasks for the temp session + tray icon and the Start Menu session shortcuts.
$dir = $PSScriptRoot
$user = "$env:USERDOMAIN\$env:USERNAME"

function New-HiddenAction($file, $extra = '') {
    # conhost --headless keeps a console window from flashing up at logon.
    New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass $extra -File `"$dir\$file`""
}

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0

Register-ScheduledTask -TaskName 'Claude Temp Session' -Force -Settings $settings `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
    -Action (New-HiddenAction 'start-temp-session.ps1'), (New-HiddenAction 'temp-session-tray.ps1' '-STA') | Out-Null

$menuTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
# Refresh periodically so the shortcuts follow recently used sessions.
$menuTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)).Repetition
Register-ScheduledTask -TaskName 'Claude Start Menu Sessions' -Force -Settings $settings `
    -Trigger $menuTrigger -Action (New-HiddenAction 'claude-start-menu.ps1') | Out-Null

'Installed. Start now with: Start-ScheduledTask "Claude Temp Session"; Start-ScheduledTask "Claude Start Menu Sessions"'
