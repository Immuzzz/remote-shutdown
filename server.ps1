param(
    [string]$ConfigPath = "config.json"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir $ConfigPath
}

if (-not (Test-Path $ConfigPath)) {
    $defaultConfig = @{
        port = 8080
        pin = "1234"
        grace_period_seconds = 30
        allow_restart = $true
        allow_sleep = $true
        allow_lock = $true
    }
    $defaultConfig | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$port = [int]$config.port
$pin = [string]$config.pin
$gracePeriod = [int]$config.grace_period_seconds

$webHtmlPath = Join-Path $scriptDir "web\index.html"
if (-not (Test-Path $webHtmlPath)) {
    Write-Error "web\index.html not found at $webHtmlPath"
    exit 1
}

$global:shutdownPending = $false
$global:shutdownEndTime = [DateTime]::MinValue
$global:shutdownAction = ""

$targetAppCatalog = @(
    @{ Name = "brave"; Display = "Brave Browser" },
    @{ Name = "msedge"; Display = "Microsoft Edge" },
    @{ Name = "chrome"; Display = "Google Chrome" },
    @{ Name = "firefox"; Display = "Mozilla Firefox" },
    @{ Name = "opera"; Display = "Opera Browser" },
    @{ Name = "vivaldi"; Display = "Vivaldi Browser" },
    @{ Name = "arc"; Display = "Arc Browser" },
    @{ Name = "tor"; Display = "Tor Browser" },
    @{ Name = "steam"; Display = "Steam" },
    @{ Name = "epicgameslauncher"; Display = "Epic Games" },
    @{ Name = "discord"; Display = "Discord" },
    @{ Name = "spotify"; Display = "Spotify" },
    @{ Name = "vlc"; Display = "VLC Media Player" },
    @{ Name = "WhatsApp.Root"; Display = "WhatsApp" },
    @{ Name = "telegram"; Display = "Telegram" },
    @{ Name = "slack"; Display = "Slack" },
    @{ Name = "zoom"; Display = "Zoom" },
    @{ Name = "teams"; Display = "Microsoft Teams" },
    @{ Name = "skype"; Display = "Skype" },
    @{ Name = "qbittorrent"; Display = "qBittorrent" },
    @{ Name = "utorrent"; Display = "uTorrent" },
    @{ Name = "notepad"; Display = "Notepad" },
    @{ Name = "notepad++"; Display = "Notepad++" },
    @{ Name = "code"; Display = "VS Code" },
    @{ Name = "devenv"; Display = "Visual Studio" },
    @{ Name = "sublime_text"; Display = "Sublime Text" },
    @{ Name = "winword"; Display = "Microsoft Word" },
    @{ Name = "excel"; Display = "Microsoft Excel" },
    @{ Name = "powerpnt"; Display = "PowerPoint" },
    @{ Name = "photoshop"; Display = "Photoshop" },
    @{ Name = "illustrator"; Display = "Illustrator" },
    @{ Name = "premiere"; Display = "Premiere Pro" },
    @{ Name = "obs64"; Display = "OBS Studio" },
    @{ Name = "blender"; Display = "Blender" },
    @{ Name = "Taskmgr"; Display = "Task Manager" }
)

function Get-RunningUserApps {
    $runningNames = Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique
    $found = @()
    foreach ($app in $targetAppCatalog) {
        if ($runningNames -contains $app.Name) {
            $found += $app
        }
    }
    return $found
}

function Close-UserAppsSafe {
    param(
        [string[]]$AppNames = $null
    )
    $apps = Get-RunningUserApps
    if ($AppNames -and $AppNames.Count -gt 0) {
        $apps = @($apps | Where-Object { $AppNames -contains $_.Name })
    }
    $closed = @()
    foreach ($app in $apps) {
        $exeName = "$($app.Name).exe"
        # 1. Graceful close signal first (WM_CLOSE so tabs/cache save)
        & taskkill /IM $exeName *>$null
        # 2. Brief wait for clean state saving
        Start-Sleep -Milliseconds 500
        # 3. Terminate process tree so tray/background helper processes exit
        & taskkill /T /F /IM $exeName *>$null
        $closed += $app.Display
    }
    return $closed
}

$ip = [System.Net.IPAddress]::Any
$listener = New-Object System.Net.Sockets.TcpListener($ip, $port)
try {
    $listener.Start()
} catch {
    Write-Error "Failed to start TCP listener on port $port : $($_.Exception.Message)"
    exit 1
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Power Switch · Remote Shutdown Server Running           " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Listening on: http://0.0.0.0:$port" -ForegroundColor Yellow
Write-Host "  Config PIN  : $pin" -ForegroundColor Yellow
Write-Host "  Grace Period: $gracePeriod seconds" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to terminate server." -ForegroundColor Gray

function Send-HttpResponse {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode = 200,
        [string]$StatusDescription = "OK",
        [string]$ContentType = "application/json; charset=utf-8",
        [string]$Content = "",
        [bool]$SendBody = $true
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $headerText = "HTTP/1.1 $StatusCode $StatusDescription`r`n" +
                  "Content-Type: $ContentType`r`n" +
                  "Content-Length: $($bytes.Length)`r`n" +
                  "Access-Control-Allow-Origin: *`r`n" +
                  "Access-Control-Allow-Methods: GET, POST, HEAD, OPTIONS`r`n" +
                  "Access-Control-Allow-Headers: Content-Type`r`n" +
                  "Connection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerText)
    try {
        $Stream.Write($headerBytes, 0, $headerBytes.Length)
        if ($SendBody -and $bytes.Length -gt 0) {
            $Stream.Write($bytes, 0, $bytes.Length)
        }
        $Stream.Flush()
    } catch {
        # Client may have disconnected early
    }
}

while ($true) {
    try {
        $client = $listener.AcceptTcpClient()
    } catch {
        break
    }

    try {
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)

        $requestLine = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($requestLine)) {
            $client.Close()
            continue
        }

        $parts = $requestLine.Split(' ')
        $method = $parts[0].ToUpper()
        $rawUrl = if ($parts.Length -ge 2) { $parts[1] } else { "/" }
        $urlPath = $rawUrl.Split('?')[0]

        $headers = @{}
        while ($line = $reader.ReadLine()) {
            if ([string]::IsNullOrWhiteSpace($line)) { break }
            $headerParts = $line.Split(':', 2)
            if ($headerParts.Length -eq 2) {
                $headers[$headerParts[0].Trim().ToLower()] = $headerParts[1].Trim()
            }
        }

        $body = ""
        if ($headers.ContainsKey("content-length")) {
            $contentLen = 0
            if ([int]::TryParse($headers["content-length"], [ref]$contentLen) -and $contentLen -gt 0) {
                $charBuffer = New-Object char[] $contentLen
                $totalRead = 0
                while ($totalRead -lt $contentLen) {
                    $readCount = $reader.Read($charBuffer, $totalRead, $contentLen - $totalRead)
                    if ($readCount -le 0) { break }
                    $totalRead += $readCount
                }
                $body = -join $charBuffer[0..($totalRead - 1)]
            }
        }

        if ($method -eq "OPTIONS") {
            Send-HttpResponse -Stream $stream -StatusCode 204 -StatusDescription "No Content" -ContentType "text/plain" -Content ""
            $client.Close()
            continue
        }

        $isHead = ($method -eq "HEAD")

        # Route matching
        if (($method -eq "GET" -or $isHead) -and ($urlPath -eq "/" -or $urlPath -eq "/index.html")) {
            $html = Get-Content -Path $webHtmlPath -Raw -Encoding UTF8
            Send-HttpResponse -Stream $stream -StatusCode 200 -StatusDescription "OK" -ContentType "text/html; charset=utf-8" -Content $html -SendBody (-not $isHead)
        }
        elseif (($method -eq "GET" -or $isHead) -and $urlPath -eq "/api/status") {
            $uptimeStr = "Unknown"
            try {
                $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
                if ($boot) {
                    $diff = (Get-Date) - $boot
                    $uptimeStr = "{0}d {1}h {2}m" -f $diff.Days, $diff.Hours, $diff.Minutes
                }
            } catch {}

            $localIp = "127.0.0.1"
            try {
                $detectedIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notmatch '^169\.' }).IPAddress | Select-Object -First 1
                if ($detectedIp) { $localIp = $detectedIp }
            } catch {}

            $remaining = 0
            if ($global:shutdownPending) {
                $diffSec = ($global:shutdownEndTime - (Get-Date)).TotalSeconds
                if ($diffSec -gt 0) {
                    $remaining = [math]::Ceiling($diffSec)
                } else {
                    $global:shutdownPending = $false
                }
            }

            $runningApps = Get-RunningUserApps
            $openAppsDetails = @($runningApps | ForEach-Object { @{ name = $_.Name; display = $_.Display } })
            $openAppsList = @($runningApps | ForEach-Object { $_.Display })

            $statusData = @{
                status = "ok"
                computerName = $env:COMPUTERNAME
                userName = $env:USERNAME
                uptime = $uptimeStr
                localIp = $localIp
                shutdownPending = $global:shutdownPending
                countdown = $remaining
                pendingAction = $global:shutdownAction
                openApps = $openAppsList
                openAppDetails = $openAppsDetails
                openAppCount = $openAppsList.Count
            }

            $json = $statusData | ConvertTo-Json
            Send-HttpResponse -Stream $stream -StatusCode 200 -StatusDescription "OK" -Content $json
        }
        elseif ($method -eq "POST" -and $urlPath -eq "/api/verify") {
            $reqPin = ""
            try {
                $jsonObj = $body | ConvertFrom-Json
                $reqPin = [string]$jsonObj.pin
            } catch {}

            if ($reqPin -eq $pin) {
                Send-HttpResponse -Stream $stream -StatusCode 200 -Content '{"status":"ok","message":"PIN valid"}'
            } else {
                Start-Sleep -Milliseconds 400
                Send-HttpResponse -Stream $stream -StatusCode 401 -StatusDescription "Unauthorized" -Content '{"status":"error","error":"invalid_pin"}'
            }
        }
        elseif ($method -eq "POST" -and $urlPath -eq "/api/shutdown") {
            $reqPin = ""
            $reqDelay = 0
            try {
                $jsonObj = $body | ConvertFrom-Json
                $reqPin = [string]$jsonObj.pin
                if ($jsonObj.delay -ne $null) {
                    $reqDelay = [int]$jsonObj.delay
                }
            } catch {}

            if ($reqPin -ne $pin) {
                Start-Sleep -Milliseconds 400
                Send-HttpResponse -Stream $stream -StatusCode 401 -StatusDescription "Unauthorized" -Content '{"status":"error","error":"invalid_pin"}'
            } else {
                Write-Host "[ACTION] Initiating Windows Shutdown in $reqDelay seconds..." -ForegroundColor Red
                $msg = if ($reqDelay -eq 0) { "Shutting down system immediately" } else { "Shutdown initiated ($reqDelay s window)" }
                Send-HttpResponse -Stream $stream -StatusCode 200 -Content (@{ status = "ok"; message = $msg } | ConvertTo-Json)
                Start-Sleep -Milliseconds 300
                if ($reqDelay -gt 0) {
                    $global:shutdownPending = $true
                    $global:shutdownEndTime = (Get-Date).AddSeconds($reqDelay)
                    $global:shutdownAction = "shutdown"
                } else {
                    $global:shutdownPending = $false
                }
                & shutdown.exe /s /f /t $reqDelay /c "Remote Shutdown triggered from web switch"
            }
        }
        elseif ($method -eq "POST" -and $urlPath -eq "/api/restart") {
            $reqPin = ""
            $reqDelay = 0
            try {
                $jsonObj = $body | ConvertFrom-Json
                $reqPin = [string]$jsonObj.pin
                if ($jsonObj.delay -ne $null) {
                    $reqDelay = [int]$jsonObj.delay
                }
            } catch {}

            if ($reqPin -ne $pin) {
                Start-Sleep -Milliseconds 400
                Send-HttpResponse -Stream $stream -StatusCode 401 -StatusDescription "Unauthorized" -Content '{"status":"error","error":"invalid_pin"}'
            } else {
                Write-Host "[ACTION] Initiating Windows Restart in $reqDelay seconds..." -ForegroundColor Yellow
                $msg = if ($reqDelay -eq 0) { "Restarting system immediately" } else { "Restart initiated ($reqDelay s window)" }
                Send-HttpResponse -Stream $stream -StatusCode 200 -Content (@{ status = "ok"; message = $msg } | ConvertTo-Json)
                Start-Sleep -Milliseconds 300
                if ($reqDelay -gt 0) {
                    $global:shutdownPending = $true
                    $global:shutdownEndTime = (Get-Date).AddSeconds($reqDelay)
                    $global:shutdownAction = "restart"
                } else {
                    $global:shutdownPending = $false
                }
                & shutdown.exe /r /f /t $reqDelay /c "Remote Restart triggered from web switch"
            }
        }
        elseif ($method -eq "POST" -and $urlPath -eq "/api/abort") {
            $reqPin = ""
            try {
                $jsonObj = $body | ConvertFrom-Json
                $reqPin = [string]$jsonObj.pin
            } catch {}

            if ($reqPin -ne $pin) {
                Start-Sleep -Milliseconds 400
                Send-HttpResponse -Stream $stream -StatusCode 401 -StatusDescription "Unauthorized" -Content '{"status":"error","error":"invalid_pin"}'
            } else {
                Write-Host "[ACTION] Aborting shutdown / restart..." -ForegroundColor Green
                & shutdown.exe /a 2>$null
                $global:shutdownPending = $false
                $global:shutdownEndTime = [DateTime]::MinValue
                $global:shutdownAction = ""
                Send-HttpResponse -Stream $stream -StatusCode 200 -Content '{"status":"ok","message":"Action aborted successfully"}'
            }
        }
        elseif ($method -eq "POST" -and $urlPath -eq "/api/sleep") {
            $reqPin = ""
            try {
                $jsonObj = $body | ConvertFrom-Json
                $reqPin = [string]$jsonObj.pin
            } catch {}

            if ($reqPin -ne $pin) {
                Start-Sleep -Milliseconds 400
                Send-HttpResponse -Stream $stream -StatusCode 401 -StatusDescription "Unauthorized" -Content '{"status":"error","error":"invalid_pin"}'
            } else {
                Write-Host "[ACTION] Putting system to sleep..." -ForegroundColor Cyan
                Send-HttpResponse -Stream $stream -StatusCode 200 -Content '{"status":"ok","message":"Entering Sleep state"}'
                Start-Sleep -Milliseconds 400
                try {
                    Add-Type -AssemblyName System.Windows.Forms
                    [System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $true, $false)
                } catch {
                    & rundll32.exe powrprof.dll,SetSuspendState 0,1,0
                }
            }
        }
        elseif ($method -eq "POST" -and $urlPath -eq "/api/lock") {
            $reqPin = ""
            try {
                $jsonObj = $body | ConvertFrom-Json
                $reqPin = [string]$jsonObj.pin
            } catch {}

            if ($reqPin -ne $pin) {
                Start-Sleep -Milliseconds 400
                Send-HttpResponse -Stream $stream -StatusCode 401 -StatusDescription "Unauthorized" -Content '{"status":"error","error":"invalid_pin"}'
            } else {
                Write-Host "[ACTION] Locking workstation..." -ForegroundColor Magenta
                & rundll32.exe user32.dll,LockWorkStation
                Send-HttpResponse -Stream $stream -StatusCode 200 -Content '{"status":"ok","message":"Workstation locked"}'
            }
        }
        elseif ($method -eq "POST" -and $urlPath -eq "/api/closeapps") {
            $reqPin = ""
            $reqApps = $null
            try {
                $jsonObj = $body | ConvertFrom-Json
                $reqPin = [string]$jsonObj.pin
                if ($jsonObj.apps) {
                    $reqApps = @($jsonObj.apps)
                }
            } catch {}

            if ($reqPin -ne $pin) {
                Start-Sleep -Milliseconds 400
                Send-HttpResponse -Stream $stream -StatusCode 401 -StatusDescription "Unauthorized" -Content '{"status":"error","error":"invalid_pin"}'
            } else {
                Write-Host "[ACTION] Safely closing user applications ($($reqApps -join ', '))..." -ForegroundColor Cyan
                $closedApps = Close-UserAppsSafe -AppNames $reqApps
                Start-Sleep -Milliseconds 1200
                $remainingApps = @(Get-RunningUserApps | ForEach-Object { $_.Display })
                $resObj = @{
                    status = "ok"
                    message = "Safe close signal sent to applications"
                    closed = $closedApps
                    closedCount = $closedApps.Count
                    remaining = $remainingApps
                    remainingCount = $remainingApps.Count
                }
                Send-HttpResponse -Stream $stream -StatusCode 200 -Content ($resObj | ConvertTo-Json)
            }
        }
        else {
            Send-HttpResponse -Stream $stream -StatusCode 404 -StatusDescription "Not Found" -Content '{"status":"error","error":"not_found"}'
        }

        $client.Close()
    } catch {
        if ($client -and $client.Connected) {
            $client.Close()
        }
    }
}

$listener.Stop()
