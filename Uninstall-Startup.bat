@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'RemoteShutdownSwitch.lnk'; ^
   if (Test-Path $shortcutPath) { ^
       Remove-Item $shortcutPath -Force; ^
       Write-Host 'Removed Remote Shutdown shortcut from Startup folder.' -ForegroundColor Green; ^
   }; ^
   try { ^
       Unregister-ScheduledTask -TaskName 'RemoteShutdownAlwaysOnline' -Confirm:$false -ErrorAction SilentlyContinue; ^
       Write-Host 'Removed RemoteShutdownAlwaysOnline Scheduled Task.' -ForegroundColor Green; ^
   } catch {}"
pause
