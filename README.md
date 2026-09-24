# claude-windows-shortcuts

Windows helpers for [Claude Code](https://claude.com/claude-code).

- **Tuxedo-general tray icon**: `start-tuxedo-general.ps1` keeps a disposable background session called `Tuxedo-general` running, with Remote Control on, in `~\Desktop`. Each fresh start deletes the previous one and its transcript. `tuxedo-tray.ps1` adds a taskbar tray icon:
  - left-click opens the session in Windows Terminal, docked to the bottom-right corner
  - right-click offers *Open in browser* (Remote Control URL), *Restart session* and *Hide icon*
- **Start Menu sessions**: `claude-start-menu.ps1` puts shortcuts to the 5 most recently active sessions in *Start → Claude Sessions*. Each one runs `claude --resume <id>` in that session's folder.

## Requirements

Windows 11, Windows Terminal (`wt.exe`), and Claude Code at `~\.local\bin\claude.exe`.

## Install

```powershell
git clone https://github.com/toladner/claude-windows-shortcuts
cd claude-windows-shortcuts
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer registers two logon tasks:

- `Claude Tuxedo-general` starts the session and the tray icon.
- `Claude Start Menu Sessions` refreshes the shortcuts every 15 minutes.

To uninstall, remove both tasks in Task Scheduler.
