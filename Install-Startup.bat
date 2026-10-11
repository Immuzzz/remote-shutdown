@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ws = New-Object -ComObject WScript.Shell; ^
   $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'RemoteShutdownSwitch.lnk'; ^
   $s = $ws.CreateShortcut($shortcutPath); ^
   $s.TargetPath = 'powershell.exe'; ^
   $s.Arguments = '-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File \"' + '%SCRIPT_DIR%Start-RemoteShutdown.ps1\" -NoBrowser'; ^
   $s.WorkingDirectory = '%SCRIPT_DIR%'; ^
   $s.WindowStyle = 7; ^
   $s.Description = 'Automatic Remote Shutdown Switch'; ^
   $s.Save(); ^
   Write-Host 'Successfully installed to Windows Startup folder!' -ForegroundColor Green; ^
   Write-Host ('Shortcut: ' + $shortcutPath) -ForegroundColor Gray"
pause
