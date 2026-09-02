<#
.SYNOPSIS
    pg_clusterbackup 1.6.0 (PowerShell port)

.DESCRIPTION
    Backs up every database of every running PostgreSQL instance on the host into separate
    files. Don't edit the defaults here -- create an ini file instead.
    Full behavior contract: see SPEC.md ("Cluster / instance discovery", strategy 3).

    Windows has no pg_lsclusters equivalent. Every PostgreSQL install (EDB installer,
    Chocolatey, etc.) registers itself as its own named Windows service running pg_ctl.exe,
    one per version/instance -- so this discovers instances via Win32_Service, not a port
    scanner and not a blind directory scan (see SPEC.md for why).

    Note: PowerShell parameter names/aliases are case-insensitive, so this can't reuse -D
    (backup dir) and -d (debug level) as distinct flags like the PHP/Bash ports do. -D still
    works here (alias for -BackupDir); debug level moved to -DebugLevel / alias -dl.

.EXAMPLE
    ./pg_clusterbackup.ps1 -IniWrite
    ./pg_clusterbackup.ps1 -D C:\Backup\PostgreSQL -Email mail@to.me
#>
param(
    [Alias('i')][string]$IniFile,
    [Alias('h')][string]$Hostname,
    [Alias('D')][string]$BackupDir,
    [Alias('T')][string]$TempDir,
    [Alias('L')][string]$LogDir,
    [Alias('F')][string]$Format,
    [Alias('dl')][string]$DebugLevel,
    [Alias('n')][string]$MaxKeep,
    [Alias('j')][string]$Jobs,
    [string]$Email,
    [switch]$Help,
    [switch]$IniWrite,
    [switch]$IniShow
)

Set-StrictMode -Version Latest

$Version = '1.6.0'
$Bound   = $PSBoundParameters

$DEBUG_LOG     = 1
$DEBUG_TERSE   = 2
$DEBUG_VERBOSE = 3

$Settings           = [ordered]@{}
$script:PgDataGlobs = @()
$script:LogLines    = New-Object System.Collections.Generic.List[string]
$script:LockStream  = $null
$script:LogFile     = $null

# ---------- ini file ----------

function Import-Ini {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^([A-Za-z0-9_]+)(\[\])?\s*=\s*"(.*)"\s*$') {
            $key = $Matches[1]; $isArray = $Matches[2]; $val = $Matches[3]
            if ($isArray) {
                if ($key -eq 'pgdata_globs') { $script:PgDataGlobs += $val }
            }
            else {
                $Settings[$key] = $val
            }
        }
    }
}

function Format-Ini {
    $lines = @()
    foreach ($key in $Settings.Keys) {
        $lines += ('{0,-20} = "{1}"' -f $key, $Settings[$key])
    }
    foreach ($g in $script:PgDataGlobs) {
        $lines += ('{0,-20} = "{1}"' -f 'pgdata_globs[]', $g)
    }
    return ($lines -join "`n") + "`n"
}

# ---------- logging / lock / helpers ----------

function Write-Log {
    param([string]$Text, [int]$Level = 0)
    $debugLevel = [int]($Settings['debug_level'])
    if ($debugLevel -ge $Level) {
        $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        $script:LogLines.Add($line)
        Add-Content -LiteralPath $script:LogFile -Value $line
    }
}

function New-BackupDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Stop-WithError {
    param([string]$Message)
    Write-Log "FATAL: $Message"
    Send-BackupMail '🟥 failed'
    Exit-Lock
    exit 1
}

function Send-BackupMail {
    param([string]$Status = '🟢 OK')
    if ([string]::IsNullOrEmpty($Settings['email']) -or $script:LogLines.Count -eq 0) { return }
    if ([string]::IsNullOrEmpty($Settings['smtp_server'])) {
        Write-Log 'Mail not sent: no smtp_server configured (Windows has no local MTA)' $DEBUG_LOG
        return
    }
    $subject = "{0} {1} PG Backup Log" -f $Status, $Settings['hostname']
    $body = $script:LogLines -join "`r`n"
    try {
        Send-MailMessage -To $Settings['email'] -From "root@$($Settings['hostname'])" `
            -Subject $subject -Body $body -SmtpServer $Settings['smtp_server'] `
            -Encoding ([System.Text.Encoding]::UTF8) -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to send mail: $($_.Exception.Message)"
    }
}

function Enter-Lock {
    $lockPath = Join-Path $Settings['tempdir'] 'pg_clusterbackup.lock'
    try {
        $script:LockStream = [System.IO.File]::Open(
            $lockPath, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch {
        Stop-WithError "Another backup run seems to be in progress (lock: $lockPath)"
    }
}

function Exit-Lock {
    if ($script:LockStream) {
        $script:LockStream.Dispose()
        $script:LockStream = $null
    }
}

function Move-BackupFile {
    param([string]$From, [string]$To)
    try {
        Move-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
    }
    catch {
        try {
            Copy-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
            Remove-Item -LiteralPath $From -Force -ErrorAction Stop
        }
        catch {
            Stop-WithError "Failed to move $From to $To"
        }
    }
}

# ---------- cluster / instance discovery ----------
# See SPEC.md "Cluster / instance discovery" strategy 3. Primary: enumerate Windows services
# running pg_ctl.exe (authoritative -- no port scanning, no guessing install paths). Fallback:
# scan pgdata_globs for portable/non-service installs.

function Get-BinDir {
    param([string]$DataDir)
    # Standard EDB installer layout: <version>\data and <version>\bin are siblings.
    Join-Path (Split-Path $DataDir -Parent) 'bin'
}

function Get-PgDataDirDetails {
    param([string]$DataDir, [string]$Cluster, [bool]$RunningHint)
    $versionFile = Join-Path $DataDir 'PG_VERSION'
    if (-not (Test-Path -LiteralPath $versionFile)) { return $null }
    $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()

    $pidFile = Join-Path $DataDir 'postmaster.pid'
    $running = $RunningHint -and (Test-Path -LiteralPath $pidFile)
    $port = $null
    if ($running) {
        $lines = Get-Content -LiteralPath $pidFile
        if ($lines.Count -ge 4) { $port = $lines[3] }
    }

    [PSCustomObject]@{
        Version   = $version
        Cluster   = $Cluster
        Running   = [int]$running
        Port      = $port
        SocketDir = $null
        BinDir    = Get-BinDir $DataDir
    }
}

function Get-PgInstancesFromServices {
    $results = @()
    $services = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -match 'pg_ctl\.exe' }
    foreach ($svc in $services) {
        $dataDir = $null
        if ($svc.PathName -match '-D\s+"([^"]+)"') { $dataDir = $Matches[1] }
        elseif ($svc.PathName -match '-D\s+(\S+)') { $dataDir = $Matches[1] }
        if (-not $dataDir) { continue }

        $details = Get-PgDataDirDetails -DataDir $dataDir -Cluster $svc.Name -RunningHint ($svc.State -eq 'Running')
        if ($details) { $results += $details }
    }
    return $results
}

function Get-PgInstancesFromScan {
    $results = @()
    foreach ($pattern in $script:PgDataGlobs) {
        $matches_ = Resolve-Path -Path $pattern -ErrorAction SilentlyContinue
        foreach ($m in $matches_) {
            $details = Get-PgDataDirDetails -DataDir $m.Path -Cluster 'main' -RunningHint $true
            if ($details) { $results += $details }
        }
    }
    return $results
}

function Get-PgInstances {
    $fromServices = @(Get-PgInstancesFromServices)
    if ($fromServices.Count -gt 0) { return $fromServices }
    return @(Get-PgInstancesFromScan)
}

# ---------- backup ----------

function Backup-Cluster {
    param($Instance, [string]$Date)
    $path = Join-Path $Settings['backupdir'] (Join-Path $Date (Join-Path $Instance.Version $Instance.Cluster))
    Write-Log "Starting backup Cluster: $($Instance.Cluster)"
    New-BackupDir $path

    $psqlExe       = Join-Path $Instance.BinDir 'psql.exe'
    $pgDumpExe     = Join-Path $Instance.BinDir 'pg_dump.exe'
    $pgDumpallExe  = Join-Path $Instance.BinDir 'pg_dumpall.exe'
    if (-not (Test-Path -LiteralPath $psqlExe)) { $psqlExe = 'psql' }
    if (-not (Test-Path -LiteralPath $pgDumpExe)) { $pgDumpExe = 'pg_dump' }
    if (-not (Test-Path -LiteralPath $pgDumpallExe)) { $pgDumpallExe = 'pg_dumpall' }

    $sql = "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"
    $databases = & $psqlExe -h localhost -p $Instance.Port -U postgres --tuples-only -P format=unaligned -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-WithError "Error listing databases for cluster $($Instance.Cluster): $databases" }

    $dbList = @($databases -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($dbList.Count -eq 0) {
        Write-Log 'No databases for backup!'
    }
    else {
        Backup-Databases -Databases $dbList -Path $path -PgDumpExe $pgDumpExe -Instance $Instance
    }

    Write-Log 'Starting backup globals' $DEBUG_LOG
    $globalsFile = Join-Path $Settings['tempdir'] 'globals.sql'
    $out = & $pgDumpallExe -h localhost -p $Instance.Port -g -f $globalsFile 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-WithError "Error dumping globals for cluster $($Instance.Cluster): $out" }
    Move-BackupFile $globalsFile (Join-Path $path 'globals.sql')
}

# Dumps up to `parallel_jobs` databases concurrently (default 1 = unchanged sequential
# behavior). Not pg_dump's own -j/--jobs: that requires the directory format and would break
# the single-file-per-database restore story. See SPEC.md "Parallel database dumps". Uses
# Start-Process (real pg_dump.exe processes) rather than PowerShell background jobs, since
# there's no scriptblock work here -- just external processes to launch and poll.
function Backup-Databases {
    param([string[]]$Databases, [string]$Path, [string]$PgDumpExe, $Instance)
    $jobs = [int]$Settings['parallel_jobs']
    if ($jobs -lt 1) { $jobs = 1 }

    $queue = [System.Collections.Generic.Queue[string]]::new([string[]]$Databases)
    $active = @{}
    $failed = $null

    while (($queue.Count -gt 0 -and -not $failed) -or $active.Count -gt 0) {
        while ($queue.Count -gt 0 -and -not $failed -and $active.Count -lt $jobs) {
            $db = $queue.Dequeue()
            Write-Log "Starting backup Database: $db "
            $tempFile = Join-Path $Settings['tempdir'] "$db.cus"
            $errFile = "$tempFile.err"
            $psArgs = @('-h', 'localhost', '-p', "$($Instance.Port)", '-c', '-F', $Settings['format'], '-f', $tempFile, $db)
            $proc = Start-Process -FilePath $PgDumpExe -ArgumentList $psArgs -PassThru -WindowStyle Hidden -RedirectStandardError $errFile
            $active[$proc.Id] = [PSCustomObject]@{ Process = $proc; Db = $db; TempFile = $tempFile; ErrFile = $errFile }
        }

        if ($active.Count -gt 0) {
            Start-Sleep -Milliseconds 150
            foreach ($procId in @($active.Keys)) {
                $info = $active[$procId]
                if ($info.Process.HasExited) {
                    $active.Remove($procId)
                    if ($info.Process.ExitCode -ne 0) {
                        $errText = if (Test-Path -LiteralPath $info.ErrFile) { Get-Content -LiteralPath $info.ErrFile -Raw } else { '' }
                        $failed = "Error dumping database $($info.Db): $errText"
                    }
                    else {
                        Move-BackupFile $info.TempFile (Join-Path $Path "$($info.Db).cus")
                    }
                    Remove-Item -LiteralPath $info.ErrFile -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($failed) { Stop-WithError $failed }
}

function Remove-OldBackups {
    $backups = Get-ChildItem -LiteralPath $Settings['backupdir'] -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' } |
        Sort-Object Name -Descending
    $toDelete = $backups | Select-Object -Skip ([int]$Settings['maxkeep'])
    foreach ($dir in $toDelete) {
        Write-Log "removing $($dir.FullName)" $DEBUG_TERSE
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
    }
}

function Invoke-BackupAll {
    Enter-Lock
    $date = Get-Date -Format 'yyyyMMdd'
    New-BackupDir (Join-Path $Settings['backupdir'] $date)
    Set-Location $Settings['tempdir']

    foreach ($inst in (Get-PgInstances)) {
        if ([int]$inst.Running -eq 1) {
            Backup-Cluster -Instance $inst -Date $date
        }
        else {
            Write-Log "Cluster: $($inst.Cluster) not running!" $DEBUG_LOG
        }
    }

    Remove-OldBackups
    Exit-Lock
    Send-BackupMail
}

# ---------- config / usage ----------

function Show-Usage {
    @"
pg_clusterbackup $Version (PowerShell)
----------------------------------------------------------------------------------------------
Backup all PostgreSQL databases from all running instances.

Author: Frank Glück (https://www.dozent.net)
Create pg_clusterbackup.ini with settings to override defaults
You can combine -IniWrite with other options to generate an ini file with those values

-Help          shows this page
-IniWrite      write ini file with current settings [$IniFile]
-IniShow       shows ini file with current settings
-Email         recipient for log

-i / -IniFile      path and filename for ini file
-h / -Hostname     hostname (default is system hostname)
-DebugLevel (-dl)  debug level 0=off, 1=log (default), 2=terse, 3=verbose

Folders
-D / -BackupDir    backup dir
-T / -TempDir      temp dir     [$($Settings['tempdir'])]
-L / -LogDir       log dir      [$($Settings['logdir'])] (default: backup dir)

Backup settings
-F / -Format       dump format (c|t|p)
-n / -MaxKeep      max number of backup generations to keep
-j / -Jobs         max concurrent pg_dump processes per cluster (default 1)

Windows notes:
- There's no sudo-to-postgres equivalent: configure pg_hba.conf (or a password/.pgpass) so this
  user can connect as the postgres role via localhost.
- Mail requires an 'smtp_server' setting in the ini file (Windows has no local MTA).
- -D and -d can't both exist as PowerShell aliases (case-insensitive), so debug level is
  -DebugLevel / -dl here instead of PHP/Bash's -d. See SPEC.md.
"@
    exit 0
}

if (-not $Bound.ContainsKey('IniFile')) {
    $IniFile = Join-Path $PSScriptRoot 'pg_clusterbackup.ini'
}
Import-Ini -Path $IniFile

$Settings['hostname']    = if ($Bound.ContainsKey('Hostname'))   { $Hostname }   elseif ($Settings['hostname'])  { $Settings['hostname'] }  else { $env:COMPUTERNAME }
$Settings['backupdir']   = if ($Bound.ContainsKey('BackupDir'))  { $BackupDir }  elseif ($Settings['backupdir']) { $Settings['backupdir'] } else { 'C:\Backup\PostgreSQL' }
$Settings['tempdir']     = if ($Bound.ContainsKey('TempDir'))    { $TempDir }    elseif ($Settings['tempdir'])   { $Settings['tempdir'] }   else { $env:TEMP }
$Settings['email']       = if ($Bound.ContainsKey('Email'))      { $Email }      elseif ($Settings['email'])     { $Settings['email'] }     else { 'monitor@ibou.net' }
$Settings['maxkeep']     = if ($Bound.ContainsKey('MaxKeep'))    { $MaxKeep }    elseif ($Settings['maxkeep'])   { $Settings['maxkeep'] }   else { '7' }
$Settings['format']      = if ($Bound.ContainsKey('Format'))     { $Format }     elseif ($Settings['format'])    { $Settings['format'] }    else { 'c' }
$Settings['logdir']      = if ($Bound.ContainsKey('LogDir'))     { $LogDir }     elseif ($Settings['logdir'])    { $Settings['logdir'] }    else { $Settings['backupdir'] }
$Settings['debug_level'] = if ($Bound.ContainsKey('DebugLevel')) { $DebugLevel } elseif ($null -ne $Settings['debug_level']) { $Settings['debug_level'] } else { '1' }
$Settings['parallel_jobs'] = if ($Bound.ContainsKey('Jobs')) { $Jobs } elseif ($Settings['parallel_jobs']) { $Settings['parallel_jobs'] } else { '1' }
$Settings['smtp_server'] = if ($Settings.Contains('smtp_server')) { $Settings['smtp_server'] } else { '' }

if ($script:PgDataGlobs.Count -eq 0) {
    $script:PgDataGlobs = @('C:\Program Files\PostgreSQL\*\data')
}

# ---------- entry point ----------

if ($Help) { Show-Usage }

if ($IniShow) {
    Write-Output (Format-Ini)
    exit 0
}

if ($IniWrite) {
    Set-Content -LiteralPath $IniFile -Value (Format-Ini) -NoNewline
    Write-Output "ini file written to $IniFile"
    exit 0
}

New-BackupDir $Settings['logdir']
$script:LogFile = Join-Path $Settings['logdir'] 'pg_backupcluster.log'

try {
    Invoke-BackupAll
}
catch {
    Stop-WithError $_.Exception.Message
}
