# Start-RemoteShutdown.ps1
param(
    [switch]$NoBrowser
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

# 1. Ensure config exists
$configFile = Join-Path $scriptDir "config.json"
if (-not (Test-Path $configFile)) {
    @{
        port = 8080
        pin = "1234"
        grace_period_seconds = 30
        allow_restart = $true
        allow_sleep = $true
        allow_lock = $true
    } | ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8
}
$config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
$port = [int]$config.port
$pin = [string]$config.pin

# 2. Cleanup any old running instances
Write-Host "Checking for existing instances..." -ForegroundColor Gray
Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# 3. Start PowerShell HTTP Server in background
Write-Host "Starting Remote Shutdown Server on port $port..." -ForegroundColor Cyan
$serverScript = Join-Path $scriptDir "server.ps1"
$serverProc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$serverScript`"" -WindowStyle Hidden -PassThru

# 4. Start Cloudflare Tunnel
$cfExe = Join-Path $scriptDir "cloudflared.exe"
if (-not (Test-Path $cfExe)) {
    Write-Host "Downloading Cloudflare tunnel agent..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $cfExe
}

$logFile = Join-Path $scriptDir "tunnel.log"
if (Test-Path $logFile) { Remove-Item $logFile -Force }

Write-Host "Starting Secure Internet Tunnel..." -ForegroundColor Cyan
$cfProc = Start-Process -FilePath $cfExe -ArgumentList "tunnel", "--url", "http://localhost:$port" -RedirectStandardError $logFile -WindowStyle Hidden -PassThru

# Save PIDs for clean stopping
@{
    serverPid = $serverProc.Id
    cfPid = $cfProc.Id
} | ConvertTo-Json | Set-Content -Path (Join-Path $scriptDir "process.pid") -Encoding UTF8

# 5. Wait for public URL
Write-Host "Establishing secure public connection (this takes a few seconds)..." -ForegroundColor Yellow
$publicUrl = ""
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $logFile) {
        $matches = Get-Content $logFile -ErrorAction SilentlyContinue | Select-String -Pattern "https://[a-zA-Z0-9-]+\.trycloudflare\.com"
        if ($matches) {
            $publicUrl = $matches.Matches[0].Value
            break
        }
    }
}

$localIp = "127.0.0.1"
try {
    $detectedIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notmatch '^169\.' }).IPAddress | Select-Object -First 1
    if ($detectedIp) { $localIp = $detectedIp }
} catch {}

$localUrl = "http://${localIp}:${port}"

$tailscaleIp = ""
try {
    $tsExe = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path $tsExe) {
        $tsOut = & $tsExe ip -4 2>$null
        if ($tsOut) { $tailscaleIp = $tsOut.Trim() }
    }
} catch {}
$tailscaleUrl = if ($tailscaleIp) { "http://${tailscaleIp}:${port}" } else { "" }

# Save URLs
$urlsContent = "Tailscale (Permanent) : $tailscaleUrl (or http://$($env:COMPUTERNAME.ToLower()):$port)`r`n" +
               "Cloudflare (Public)   : $publicUrl`r`n" +
               "Local Wi-Fi           : $localUrl`r`n" +
               "PIN Code              : $pin`r`n" +
               "Updated At            : $(Get-Date)"
Set-Content -Path (Join-Path $scriptDir "current_urls.txt") -Value $urlsContent -Encoding UTF8

# Create URL desktop shortcut file in current directory
$primaryUrl = if ($tailscaleUrl) { $tailscaleUrl } else { $publicUrl }
if ($primaryUrl) {
    "[InternetShortcut]`r`nURL=$primaryUrl" | Set-Content -Path (Join-Path $scriptDir "Open-RemoteShutdown.url") -Encoding ASCII
}

# 6. Display Dashboard
Clear-Host
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Red
Write-Host "      POWER SWITCH · REMOTE SHUTDOWN IS ONLINE                    " -ForegroundColor White
Write-Host "  ================================================================" -ForegroundColor Red
Write-Host ""
if ($tailscaleUrl) {
    Write-Host "  PERMANENT TAILSCALE URL (Never changes · Access from anywhere):" -ForegroundColor Green
    Write-Host "     $tailscaleUrl" -ForegroundColor Cyan
    Write-Host "     (or http://$($env:COMPUTERNAME.ToLower()):$port)" -ForegroundColor DarkCyan
    Write-Host ""
}
Write-Host "  PUBLIC INTERNET TUNNEL (Cloudflare Quick Tunnel):" -ForegroundColor Green
if ($publicUrl) {
    Write-Host "     $publicUrl" -ForegroundColor White
} else {
    Write-Host "     Tunnel starting..." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  LOCAL WI-FI URL (When on same home network):" -ForegroundColor Green
Write-Host "     $localUrl" -ForegroundColor White
Write-Host ""
Write-Host "  SECURITY PIN:" -ForegroundColor Green
Write-Host "     $pin" -ForegroundColor Yellow
Write-Host ""
Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  MOBILE SETUP TIP:" -ForegroundColor Gray
Write-Host "     1. On your phone, connect to Tailscale" -ForegroundColor Gray
Write-Host "     2. Open $tailscaleUrl in your phone browser" -ForegroundColor Gray
Write-Host "     3. Tap Share / Menu -> Add to Home Screen" -ForegroundColor Gray
Write-Host "     This button will work permanently forever!" -ForegroundColor Gray
Write-Host "  ----------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To stop the server at any time, run: .\Stop-RemoteShutdown.ps1" -ForegroundColor DarkYellow
Write-Host "  Or press Q in this window to quit." -ForegroundColor DarkYellow
Write-Host ""

if (-not $NoBrowser -and $primaryUrl) {
    Start-Process $primaryUrl
}

# Keep process alive (and allow pressing Q if running in an interactive console)
while ($true) {
    try {
        if ([console]::KeyAvailable) {
            $k = [console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Q) {
                Write-Host "Stopping services..." -ForegroundColor Yellow
                & (Join-Path $scriptDir "Stop-RemoteShutdown.ps1")
                break
            }
        }
    } catch {
        # Headless / hidden window style without console attached
    }
    Start-Sleep -Seconds 1
}
