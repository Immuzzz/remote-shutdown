# Stop-RemoteShutdown.ps1
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$pidFile = Join-Path $scriptDir "process.pid"
if (Test-Path $pidFile) {
    try {
        $pids = Get-Content $pidFile -Raw | ConvertFrom-Json
        if ($pids.serverPid) {
            Stop-Process -Id $pids.serverPid -Force -ErrorAction SilentlyContinue
        }
        if ($pids.cfPid) {
            Stop-Process -Id $pids.cfPid -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } catch {}
}

# Also stop Scheduled Task if running
try {
    Stop-ScheduledTask -TaskName "RemoteShutdownAlwaysOnline" -ErrorAction SilentlyContinue
} catch {}

# Also ensure any lingering cloudflared processes from this folder are stopped
Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "Remote Shutdown server and tunnel have been stopped." -ForegroundColor Green
