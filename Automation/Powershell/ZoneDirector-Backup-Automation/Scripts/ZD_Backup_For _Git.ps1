[CmdletBinding()]
param(
    # Leave blank to back up both sample ZoneDirector controllers.
    # Supply one known IP to test only that controller.
    [ValidateSet('192.168.100.100', '192.168.100.101')]
    [string]$ControllerIP,

    [string]$BasePath = 'D:\Automation\ZoneDirectorBackup'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =========================================================
# Sample ZoneDirector inventory and execution order
# =========================================================

$ConfiguredControllers = @(
    [PSCustomObject]@{
        IP   = '192.168.100.100'
        Name = 'ZoneController-01'
    }
    [PSCustomObject]@{
        IP   = '192.168.100.101'
        Name = 'ZoneController-02'
    }
)

if ([string]::IsNullOrWhiteSpace($ControllerIP)) {
    $Controllers = $ConfiguredControllers
}
else {
    $Controllers = @(
        $ConfiguredControllers |
            Where-Object { $_.IP -eq $ControllerIP }
    )

    if ($Controllers.Count -ne 1) {
        throw "Controller IP is not configured: $ControllerIP"
    }
}

$ConfigPath = Join-Path $BasePath 'Config'
$BackupPath = Join-Path $BasePath 'Backups'
$LogsPath = Join-Path $BasePath 'Logs'
$CredentialFile = Join-Path $ConfigPath 'ZD_Credential.xml'
$LogFile = Join-Path $LogsPath ("ZoneDirectorBackup_{0}.log" -f (Get-Date -Format 'yyyy-MM'))

function ConvertTo-CurlConfigValue {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -match "[`r`n]") {
        throw 'A credential value contains an unsupported line break.'
    }

    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Invoke-CurlProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Arguments,
        [string[]]$ConfigLines = @()
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'C:\Windows\System32\curl.exe'
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw 'curl.exe could not be started.'
        }

        foreach ($line in $ConfigLines) {
            $process.StandardInput.WriteLine($line)
        }
        $process.StandardInput.Close()

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0) {
            throw "curl.exe failed with exit code $($process.ExitCode): $($stderr.Trim())"
        }

        return $stdout.Trim()
    }
    finally {
        $process.Dispose()
    }
}

function Write-Log {
    param([string]$Message)

    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Invoke-ZoneDirectorBackup {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Controller,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory = $true)]
        [string]$PlainPassword
    )

    $controllerIP = $Controller.IP
    $controllerName = $Controller.Name
    $baseUri = "https://$controllerIP/admin10"
    $loginUri = "$baseUri/login.jsp"
    $backupPageUri = "$baseUri/admin_backup.jsp"

    $tempFile = $null
    $cookieJar = Join-Path $env:TEMP ("ZD_cookie_{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $loginPageFile = Join-Path $env:TEMP ("ZD_login_{0}.html" -f [guid]::NewGuid().ToString('N'))
    $loginHeadersFile = Join-Path $env:TEMP ("ZD_headers_{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $startTime = Get-Date

    try {
        Write-Log "============================================================"
        Write-Log "Starting configuration backup for $controllerName ($controllerIP)."

        # curl.exe is used because this older ZoneDirector TLS stack is not
        # compatible with Invoke-WebRequest on some PowerShell 5.1 systems.
        [void](Invoke-CurlProcess -Arguments (
            '-k -sS --fail --connect-timeout 30 --max-time 60 ' +
            '--cookie-jar "{0}" --cookie "{0}" --output "{1}" "{2}"' -f
            $cookieJar, $loginPageFile, $loginUri
        ))

        # Credentials are passed through standard input, not the command line.
        $loginConfig = @(
            'data-urlencode = "username={0}"' -f (ConvertTo-CurlConfigValue $Credential.UserName)
            'data-urlencode = "password={0}"' -f (ConvertTo-CurlConfigValue $PlainPassword)
            'data-urlencode = "ok=Log In"'
        )

        $loginResult = Invoke-CurlProcess -Arguments (
            '-k -sS --fail --location --connect-timeout 30 --max-time 60 ' +
            '--cookie-jar "{0}" --cookie "{0}" --output "{1}" ' +
            '--dump-header "{2}" --write-out "%{{url_effective}}|%{{http_code}}" --config - "{3}"' -f
            $cookieJar, $loginPageFile, $loginHeadersFile, $loginUri
        ) -ConfigLines $loginConfig

        if ($loginResult -notmatch '/admin10/(dashboard|app)\.jsp[^|]*\|200$') {
            throw "ZoneDirector login was not confirmed. Result: $loginResult"
        }

        Write-Log "HTTPS login successful for user $($Credential.UserName)."

        $csrfHeader = Get-Content -LiteralPath $loginHeadersFile |
            Where-Object { $_ -match '(?i)^Http_x_csrf_token\s*:' } |
            Select-Object -Last 1

        if (-not $csrfHeader) {
            throw 'ZoneDirector login succeeded but its CSRF token was not returned.'
        }

        $csrfToken = ($csrfHeader -split ':', 2)[1].Trim()
        if ([string]::IsNullOrWhiteSpace($csrfToken)) {
            throw 'ZoneDirector returned an empty CSRF token.'
        }

        Write-Log 'ZoneDirector CSRF token received.'

        # Open the Backup page first to establish the administration context.
        $backupPageResult = Invoke-CurlProcess -Arguments (
            '-k -sS --fail --location --connect-timeout 30 --max-time 60 ' +
            '--cookie-jar "{0}" --cookie "{0}" --referer "{1}" ' +
            '--header "X-CSRF-Token: {2}" --header "Http_x_csrf_token: {2}" --output "{3}" ' +
            '--write-out "%{{url_effective}}|%{{http_code}}" "{4}"' -f
            $cookieJar, $loginResult.Split('|')[0], $csrfToken, $loginPageFile, $backupPageUri
        )

        if ($backupPageResult -match '(?i)/login\.jsp[^|]*\|') {
            throw "ZoneDirector session returned to the login page before backup. Result: $backupPageResult"
        }

        if ($backupPageResult -notmatch '(?i)/admin10/admin_backup\.jsp[^|]*\|200$') {
            throw "ZoneDirector backup page could not be confirmed. Result: $backupPageResult"
        }

        $timestamp = Get-Date -Format 'MMddyy_HH_mm'
        $backupUri = "$baseUri/_savebackup.jsp?time=$timestamp"
        $fileName = "{0}_db_{1}.bak" -f $controllerName, $timestamp
        $outputFile = Join-Path $BackupPath $fileName
        $tempFile = Join-Path $env:TEMP ("ZD_{0}_{1}.tmp" -f $controllerIP.Replace('.', '_'), [guid]::NewGuid().ToString('N'))

        [void](Invoke-CurlProcess -Arguments (
            '-k -sS --fail --location --connect-timeout 30 --max-time 300 ' +
            '--cookie-jar "{0}" --cookie "{0}" --referer "{1}" ' +
            '--header "X-CSRF-Token: {2}" --header "Http_x_csrf_token: {2}" --output "{3}" "{4}"' -f
            $cookieJar, $backupPageUri, $csrfToken, $tempFile, $backupUri
        ))

        if (-not (Test-Path -LiteralPath $tempFile)) {
            throw 'ZoneDirector did not return a backup file.'
        }

        $stream = [System.IO.File]::OpenRead($tempFile)
        try {
            $buffer = New-Object byte[] 512
            $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
            $openingText = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead)
        }
        finally {
            $stream.Dispose()
        }

        $download = Get-Item -LiteralPath $tempFile

        if ($openingText -match '(?i)<html|<!doctype') {
            $diagnosticFile = Join-Path $LogsPath ("FailedBackupResponse_{0}_{1}.html" -f $controllerName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item -LiteralPath $tempFile -Destination $diagnosticFile -Force
            throw "ZoneDirector returned an HTML page instead of a backup. Diagnostic saved: $diagnosticFile"
        }

        if ($download.Length -lt 102400) {
            $diagnosticFile = Join-Path $LogsPath ("FailedBackupResponse_{0}_{1}.bin" -f $controllerName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item -LiteralPath $tempFile -Destination $diagnosticFile -Force
            throw "Downloaded response is too small to be a valid backup ($($download.Length) bytes). Diagnostic saved: $diagnosticFile"
        }

        Move-Item -LiteralPath $tempFile -Destination $outputFile -Force
        $tempFile = $null

        $savedFile = Get-Item -LiteralPath $outputFile
        $duration = (Get-Date) - $startTime

        Write-Log "SUCCESS: Backup saved to $outputFile ($($savedFile.Length) bytes)."
        Write-Host "SUCCESS: $outputFile" -ForegroundColor Green
        Write-Host "SIZE: $($savedFile.Length) bytes"

        return [PSCustomObject]@{
            Controller = $controllerName
            IP         = $controllerIP
            Status     = 'SUCCESS'
            File       = $outputFile
            Bytes      = $savedFile.Length
            Duration   = $duration.ToString('hh\:mm\:ss')
            Error      = $null
        }
    }
    catch {
        $duration = (Get-Date) - $startTime
        $errorMessage = $_.Exception.Message

        Write-Log "ERROR: $controllerName ($controllerIP): $errorMessage"
        Write-Host "FAILED: $controllerName ($controllerIP): $errorMessage" -ForegroundColor Red

        return [PSCustomObject]@{
            Controller = $controllerName
            IP         = $controllerIP
            Status     = 'FAILED'
            File       = $null
            Bytes      = 0
            Duration   = $duration.ToString('hh\:mm\:ss')
            Error      = $errorMessage
        }
    }
    finally {
        if ($null -ne $tempFile -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }

        foreach ($temporaryPath in @($cookieJar, $loginPageFile, $loginHeadersFile)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# =========================================================
# Preparation
# =========================================================

New-Item -ItemType Directory -Path $ConfigPath -Force | Out-Null
New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null

if (-not (Test-Path -LiteralPath $CredentialFile)) {
    throw "Encrypted credential file not found: $CredentialFile"
}

if (-not (Get-Command 'curl.exe' -ErrorAction SilentlyContinue)) {
    throw 'curl.exe was not found on this Windows system.'
}

$credential = Import-Clixml -LiteralPath $CredentialFile
$plainPassword = $null
$results = New-Object System.Collections.Generic.List[object]

try {
    $plainPassword = $credential.GetNetworkCredential().Password

    foreach ($controller in $Controllers) {
        # Each controller is isolated; failure does not stop the next one.
        $result = Invoke-ZoneDirectorBackup `
            -Controller $controller `
            -Credential $credential `
            -PlainPassword $plainPassword

        $results.Add($result)
    }
}
finally {
    $plainPassword = $null
    $credential = $null
}

# =========================================================
# Final summary and exit code
# =========================================================

$successful = @($results | Where-Object Status -eq 'SUCCESS').Count
$failed = @($results | Where-Object Status -eq 'FAILED').Count

Write-Log '============================================================'
Write-Log 'FINAL ZONEDIRECTOR BACKUP SUMMARY'

foreach ($result in $results) {
    $summary = "{0} ({1}): {2}; duration {3}" -f `
        $result.Controller,
        $result.IP,
        $result.Status,
        $result.Duration

    if ($result.Status -eq 'SUCCESS') {
        Write-Host $summary -ForegroundColor Green
    }
    else {
        Write-Host "$summary; error: $($result.Error)" -ForegroundColor Red
    }

    Write-Log $summary
}

Write-Log "Successful: $successful; Failed: $failed."

if ($failed -eq 0) {
    Write-Host 'ALL ZONEDIRECTOR BACKUPS SUCCESSFUL' -ForegroundColor Green
    exit 0
}

if ($successful -gt 0) {
    Write-Host 'PARTIAL SUCCESS: One ZoneDirector backup failed; the other controller was still processed.' -ForegroundColor Yellow
    exit 2
}

Write-Host 'ALL ZONEDIRECTOR BACKUPS FAILED' -ForegroundColor Red
exit 1
