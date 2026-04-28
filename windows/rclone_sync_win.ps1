# =============================================================================
# rclone_sync.ps1 — Local ↔ Wasabi Bisync with email notifications
# v1.8 — Configurable working directory, Lock Age, Recovery Email, OS Detect
#         Fix: rclone output in log, array args for paths with spaces
# =============================================================================

# --- AUTO-DETECT OS AND MACHINE NAME ---
$HostName = $env:COMPUTERNAME
$OsType = "Windows"
$RcloneCmd = "C:\rclone\rclone.exe"

# --- WORKING DIRECTORY ---
# This is where the log, lockfile, fail counter, and bisync marker are written.
#
# Three ways to set it (in order of priority):
#
# 1. Environment variable in Task Scheduler (most flexible):
#    Add RCLONE_SYNC_DIR=C:\rclone_data to the task's environment variables
#
# 2. In your PowerShell profile ($PROFILE):
#    $env:RCLONE_SYNC_DIR = "C:\rclone"
#
# 3. Hardcoded fallback below (used only if neither 1 nor 2 are set).
#    Comment the line out to fall back to the user's home directory.
if (-not $env:RCLONE_SYNC_DIR) { $env:RCLONE_SYNC_DIR = "C:\rclone_data" }
#
# If none of the three is set, the default is the user's home directory.
$HomeDir = $env:USERPROFILE
$WorkDir = if ($env:RCLONE_SYNC_DIR) { $env:RCLONE_SYNC_DIR } else { $HomeDir }

# Create the directory only if it does not exist
if (-not (Test-Path $WorkDir)) {
    try {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    } catch {
        Write-Error "ERROR: cannot create working directory $WorkDir"
        exit 1
    }
}

# --- STATE FILE PATHS ---
$LogFile      = "$WorkDir\rclone_sync.log"
$FailFile     = "$WorkDir\rclone_fail_count.txt"
$AlertFlag    = "$WorkDir\.rclone_alert_sent"
$LockFile     = "$WorkDir\rclone_sync.lock"
$BisyncMarker = "$WorkDir\.rclone_bisync_initialized"

# --- DEBUG (true=enabled, false=silent) ---
$DebugLog = $true

# --- RCLONE SETTINGS ---
# LocalPath: path to the local folder you want to sync (e.g. your Cryptomator vault mount point)
# RemotePath: rclone remote in the form "<remote-name>:<bucket>/<path>"
$LocalPath = "C:\Users\YourUser\YourVault"
$RemotePath = "wasabi-remote:your-bucket/your-folder"

# --- EMAIL SETTINGS (Resend API) ---
# Get your API key at https://resend.com
$ResendApiKey = "re_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
$EmailFrom    = "noreply@example.com"
$EmailTo      = "your-email@example.com"
$MaxFails     = 3

# --- LOCKFILE: maximum age in seconds (4 hours) ---
$LockMaxAge = 14400

# =============================================================================
# FUNCTIONS
# =============================================================================

function Write-Log ($Message) {
    if ($DebugLog) {
        $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $Line = "[$Timestamp] [$HostName|$OsType] $Message"
        Add-Content -Path $LogFile -Value $Line
    }
}

function Send-Alert ($Reason, $Subject, $BodyText) {
    Write-Log "Sending email: $Subject"
    $Headers = @{
        "Authorization" = "Bearer $ResendApiKey"
        "Content-Type"  = "application/json"
    }
    $Body = @{
        from    = $EmailFrom
        to      = $EmailTo
        subject = $Subject
        html    = $BodyText
    } | ConvertTo-Json -Depth 3

    try {
        Invoke-RestMethod `
            -Uri "https://api.resend.com/emails" `
            -Method Post `
            -Headers $Headers `
            -Body $Body | Out-Null
        Write-Log "Email sent successfully"
        return $true
    } catch {
        $HttpCode = $_.Exception.Response.StatusCode.value__
        if ($HttpCode) {
            Write-Log "WARNING: email not sent — HTTP $HttpCode — $($_.Exception.Message)"
        } else {
            Write-Log "WARNING: Resend API exception — $($_.Exception.Message)"
        }
        return $false
    }
}

function Add-Failure ($Reason) {
    Write-Log "ERROR: $Reason"

    $Count = 0
    if (Test-Path $FailFile) {
        $RawCount = (Get-Content $FailFile -Raw).Trim()
        if ($RawCount -match '^\d+$') { $Count = [int]$RawCount }
    }

    $Count++
    Set-Content -Path $FailFile -Value $Count
    Write-Log "Consecutive failures: $Count / $MaxFails"

    # Send alert email only the first time we cross the threshold
    # (counter keeps growing until sync recovers, but no spam every cron cycle)
    if ($Count -ge $MaxFails -and -not (Test-Path $AlertFlag)) {
        $Subject  = "KO Wasabi alert on $HostName ($OsType)"
        $BodyText = "<p>Hi there,</p><p>Rclone has failed on <strong>$HostName</strong> ($OsType) <strong>$MaxFails consecutive times</strong>.<br>Last error reason: <code>$Reason</code></p>"
        $Sent = Send-Alert -Reason $Reason -Subject $Subject -BodyText $BodyText
        if ($Sent) {
            New-Item -Path $AlertFlag -ItemType File -Force | Out-Null
            Write-Log "Alert email sent — flag created (recovery email will fire on next successful sync)"
        } else {
            Write-Log "Alert email NOT delivered — will retry next cycle"
        }
    }
}

function Reset-FailWithRecoveryEmail {
    # Send recovery only if an alert was previously fired
    if (Test-Path $AlertFlag) {
        $PrevCount = 0
        if (Test-Path $FailFile) {
            $RawCount = (Get-Content $FailFile -Raw).Trim()
            if ($RawCount -match '^\d+$') { $PrevCount = [int]$RawCount }
        }
        $Subject  = "OK Wasabi on ${HostName}: sync restored"
        $BodyText = "<p>Hi there,</p><p>Wasabi sync on <strong>$HostName</strong> is back to working correctly after <strong>$PrevCount consecutive errors</strong>.</p>"
        $Sent = Send-Alert -Reason "recovery" -Subject $Subject -BodyText $BodyText
        if ($Sent) {
            Remove-Item $AlertFlag -Force
            Write-Log "Recovery email sent (was at $PrevCount failures)"
        } else {
            Write-Log "Recovery email NOT sent — will retry on next successful sync"
        }
    }
    Set-Content -Path $FailFile -Value 0
}

function Invoke-Rclone ($RcloneArgs) {
    # Runs rclone with an argument array and captures output to the log
    if ($DebugLog) {
        $Output = & $RcloneCmd @RcloneArgs 2>&1
        $Output | ForEach-Object { Add-Content -Path $LogFile -Value $_ }
    } else {
        & $RcloneCmd @RcloneArgs 2>$null | Out-Null
    }
    return $LASTEXITCODE
}

function Exit-Script {
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force }
    Write-Log "Clean exit"
    exit 0
}

# =============================================================================
# LOG ROTATION — if > 1MB keep the last 1000 lines and save .old backup
# =============================================================================
if (Test-Path $LogFile) {
    $FileInfo = Get-Item $LogFile
    if ($FileInfo.Length -gt 1MB) {
        Copy-Item $LogFile "$LogFile.old" -Force
        $Tail = Get-Content $LogFile -Tail 1000
        Set-Content -Path $LogFile -Value $Tail
        Write-Log "Log rotation performed (backup saved as .old)"
    }
}

# =============================================================================
# EXECUTION START
# =============================================================================
Write-Log "=============================="
Write-Log "Script started (PID $PID)"
Write-Log "Working directory: $WorkDir"
$RcloneVer = (& $RcloneCmd version 2>$null) | Select-Object -First 1
Write-Log "rclone: $RcloneVer"

try {

    # --- LOCKFILE WITH AGE CHECK ---
    if (Test-Path $LockFile) {
        $LockPid   = (Get-Content $LockFile -Raw).Trim()
        $LockMTime = (Get-Item $LockFile).LastWriteTime
        $LockAge   = [math]::Round((New-TimeSpan -Start $LockMTime -End (Get-Date)).TotalSeconds)
        $Running   = Get-Process -Id $LockPid -ErrorAction SilentlyContinue

        if ($Running) {
            if ($LockAge -gt $LockMaxAge) {
                Write-Log "WARNING: rclone (PID $LockPid) has been running for ${LockAge}s — likely stuck, attempting graceful kill"
                Stop-Process -Id $LockPid -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                # Escalate to forced kill if still alive
                if (Get-Process -Id $LockPid -ErrorAction SilentlyContinue) {
                    Write-Log "Process $LockPid still alive after graceful kill — forcing"
                    Stop-Process -Id $LockPid -Force -ErrorAction SilentlyContinue
                }
                Remove-Item $LockFile -Force
                Add-Failure "rclone stuck for ${LockAge}s — forced kill"
            } else {
                Write-Log "EXIT: rclone already running (PID $LockPid, age ${LockAge}s), skipping"
                Exit-Script
            }
        } else {
            Write-Log "Stale lockfile found (PID $LockPid does not exist, age ${LockAge}s), removing"
            Remove-Item $LockFile -Force
        }
    }

    $PID | Out-File -FilePath $LockFile -Encoding ASCII
    Write-Log "Lock acquired (PID $PID)"

    # --- LOCAL FOLDER CHECK ---
    if (-not (Test-Path $LocalPath)) {
        Write-Log "EXIT: local folder not found ($LocalPath) — vault not mounted?"
        Exit-Script
    }
    Write-Log "Local folder OK ($LocalPath)"

    # --- INTERNET CHECK ---
    $Ping = Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $Ping) {
        Write-Log "EXIT: no internet connection"
        Exit-Script
    }
    Write-Log "Internet connection OK"

    # --- FIRST RUN: automatic --resync if never initialized ---
    if (-not (Test-Path $BisyncMarker)) {
        Write-Log "First run detected — performing initial bisync --resync..."
        $ResyncArgs = @("bisync", $LocalPath, $RemotePath, "--resync", "--log-level", "INFO")
        $ResyncExit = Invoke-Rclone $ResyncArgs
        if ($ResyncExit -eq 0) {
            New-Item -Path $BisyncMarker -ItemType File -Force | Out-Null
            Write-Log "Initial resync completed — marker created"
        } else {
            Add-Failure "initial resync failed (exit code $ResyncExit)"
            Remove-Item $LockFile -Force
            Write-Log "Script terminated with error during initial resync"
            exit 1
        }
    }

    # --- RCLONE EXECUTION ---
    $StartTime = Get-Date
    Write-Log "Starting rclone bisync..."

    $LogLevel   = if ($DebugLog) { "INFO" } else { "ERROR" }
    $RcloneArgs = @("bisync", $LocalPath, $RemotePath, "--contimeout", "60s", "--timeout", "5m", "--log-level", $LogLevel)
    $RcloneExit = Invoke-Rclone $RcloneArgs

    $Duration = [math]::Round((New-TimeSpan -Start $StartTime -End (Get-Date)).TotalSeconds)
    Write-Log "rclone exit code: $RcloneExit — duration: ${Duration}s"

    # --- RESULT HANDLING ---
    Remove-Item $LockFile -Force
    Write-Log "Lock released"

    if ($RcloneExit -eq 0) {
        Write-Log "Sync completed successfully"
        Reset-FailWithRecoveryEmail
    } else {
        Add-Failure "rclone exited with code $RcloneExit"
    }

} catch {
    $ErrMsg = $_.Exception.Message
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force }
    Add-Failure "PS1 script crash: $ErrMsg"
}

Write-Log "Script finished"