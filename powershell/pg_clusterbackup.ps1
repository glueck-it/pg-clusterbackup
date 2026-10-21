<#
.SYNOPSIS
    pg_clusterbackup 1.8.0 (PowerShell port)

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
    [Alias('C', 'cj')][string]$ParallelClusters,
    [Alias('Z')][string]$Compression,
    [Alias('WhatIf')][switch]$DryRun,
    [string]$ExcludeDatabases,
    [string]$IncludeDatabases,
    [string]$PingUrl,
    [string]$InternalBackupCluster,
    [string]$InternalDate,
    [string]$Email,
    [switch]$Help,
    [switch]$IniWrite,
    [switch]$IniShow
)

Set-StrictMode -Version Latest

$Version = '1.8.0'
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
        if ($key -eq 'dry_run') { continue }
        $lines += ('{0,-20} = "{1}"' -f $key, $Settings[$key])
    }
    foreach ($g in $script:PgDataGlobs) {
        $lines += ('{0,-20} = "{1}"' -f 'pgdata_globs[]', $g)
    }
    return ($lines -join "`n") + "`n"
}

# ---------- logging / lock / helpers ----------

function Write-Log {
    param([string]$Text, [int]$Level = 0, [string]$Cluster = '')
    $debugLevel = [int]($Settings['debug_level'])
    if ($debugLevel -ge $Level) {
        $prefix = ''
        if ($Settings['dry_run'] -eq '1') { $prefix = '[DRY-RUN] ' }
        if (-not [string]::IsNullOrEmpty($Cluster)) { $prefix += "[$Cluster] " }
        $line = "{0} {1}{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $prefix, $Text
        $script:LogLines.Add($line)
        Write-Output $line
        if ($Settings['dry_run'] -ne '1' -and $script:LogFile) {
            Add-Content -LiteralPath $script:LogFile -Value $line
        }
    }
}

function New-BackupDir {
    param([string]$Path)
    if ($Settings['dry_run'] -eq '1') { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Send-PingWebhook {
    param([string]$Endpoint = '', [string]$Msg = '')
    $url = $Settings['ping_url']
    if ([string]::IsNullOrEmpty($url)) { return }
    $url = $url.TrimEnd('/')
    if ($Endpoint) { $url += '/' + $Endpoint.TrimStart('/') }

    try {
        if ($Msg) {
            Invoke-RestMethod -Uri $url -Method Post -Body $Msg -ContentType 'text/plain' -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
        }
        else {
            Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {
        # ignore network errors for pings
    }
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -lt 1024) { return "$Bytes B" }
    elseif ($Bytes -lt 1MB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    elseif ($Bytes -lt 1GB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    else { return "{0:N2} GB" -f ($Bytes / 1GB) }
}

function Test-DiskSpace {
    $minGb = 0
    if ($Settings.Contains('min_free_space_gb') -and -not [string]::IsNullOrEmpty($Settings['min_free_space_gb'])) {
        $minGb = [int]($Settings['min_free_space_gb'])
    }
    if ($minGb -le 0) { return }

    $minBytes = [int64]$minGb * 1024 * 1024 * 1024
    foreach ($dirKey in @('backupdir', 'tempdir')) {
        $path = $Settings[$dirKey]
        $root = [System.IO.Path]::GetPathRoot($path)
        if ($root) {
            $drive = Get-PSDrive ($root.TrimEnd(':\')) -ErrorAction SilentlyContinue
            if ($drive -and $drive.Free) {
                Write-Log "Checking free disk space on $dirKey ($root): $(Format-Bytes $drive.Free)" $DEBUG_VERBOSE
                if ($drive.Free -lt $minBytes) {
                    Stop-WithError "Insufficient disk space on $dirKey ($root): $(Format-Bytes $drive.Free) free, required: $minGb GB"
                }
            }
        }
    }
}

function Stop-WithError {
    param([string]$Message)
    Write-Log "FATAL: $Message"
    Send-PingWebhook -Endpoint 'fail' -Msg $Message
    Send-BackupMail '🟥 failed'
    Exit-Lock
    exit 1
}

function Send-BackupMail {
    param([string]$Status = '🟢 OK')
    if ($Settings['dry_run'] -eq '1') {
        $Status = '🟡 DRY-RUN'
    }
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
    if ($Settings['dry_run'] -eq '1') { return }
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
    if ($Settings['dry_run'] -eq '1') { return }
    try {
        Move-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
    }
    catch {
        try {
            Copy-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
            Remove-Item -LiteralPath $From -Force -ErrorAction Stop
        }
        catch {
            Stop-WithError "Failed to move $From to ${To}: $($_.Exception.Message)"
        }
    }
}

# ---------- cluster / instance discovery ----------

function Get-BinDir {
    param([string]$DataDir)
    $parent = Split-Path -Parent $DataDir
    $candidate = Join-Path $parent 'bin'
    if (Test-Path -LiteralPath (Join-Path $candidate 'pg_dump.exe')) { return $candidate }
    $versionFile = Join-Path $DataDir 'PG_VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        $ver = (Get-Content -LiteralPath $versionFile -Raw).Trim()
        $candidate = "C:\Program Files\PostgreSQL\$ver\bin"
        if (Test-Path -LiteralPath (Join-Path $candidate 'pg_dump.exe')) { return $candidate }
    }
    return $null
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
        if ($lines.Length -ge 4) { $port = $lines[3].Trim() }
    }

    return [PSCustomObject]@{
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

function Remove-ClusterOldBackups {
    param([string]$Version, [string]$Cluster)
    $backups = Get-ChildItem -Path (Join-Path $Settings['backupdir'] "*") -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $target = Join-Path $_.FullName (Join-Path $Version $Cluster)
            if (Test-Path -LiteralPath $target) { Get-Item -LiteralPath $target }
        } |
        Sort-Object { $_.Parent.Parent.Name } -Descending

    $toDelete = $backups | Select-Object -Skip ([int]$Settings['maxkeep'])
    foreach ($dir in $toDelete) {
        if ($Settings['dry_run'] -eq '1') {
            Write-Log "would remove old backup directory $($dir.FullName)" $DEBUG_TERSE $Cluster
        }
        else {
            Write-Log "removing $($dir.FullName)" $DEBUG_TERSE $Cluster
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force
            $parent = $dir.Parent
            if ($parent -and (Get-ChildItem -LiteralPath $parent.FullName -Force).Count -eq 0) {
                Remove-Item -LiteralPath $parent.FullName -Force -ErrorAction SilentlyContinue
            }
            $grandparent = $parent.Parent
            if ($grandparent -and (Get-ChildItem -LiteralPath $grandparent.FullName -Force).Count -eq 0) {
                Remove-Item -LiteralPath $grandparent.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Remove-EmptyDateDirs {
    if ($Settings['dry_run'] -eq '1') { return }
    $dateDirs = Get-ChildItem -LiteralPath $Settings['backupdir'] -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' }
    foreach ($d in $dateDirs) {
        if ((Get-ChildItem -LiteralPath $d.FullName -Force).Count -eq 0) {
            Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Filter-Databases {
    param([string[]]$DatabasesRaw, [string]$Cluster)
    $filtered = @()
    $incList = @()
    if ($Settings['include_databases']) {
        $incList = @($Settings['include_databases'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $excList = @()
    if ($Settings['exclude_databases']) {
        $excList = @($Settings['exclude_databases'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    foreach ($entry in $DatabasesRaw) {
        $parts = $entry -split '\|'
        $db = $parts[0].Trim()
        $rawSize = if ($parts.Length -gt 1) { [int64]($parts[1].Trim()) } else { 0 }
        if (-not $db) { continue }

        if ($incList.Count -gt 0) {
            $matchedInc = $false
            foreach ($pat in $incList) {
                if ($db -like $pat) { $matchedInc = $true; break }
            }
            if (-not $matchedInc) {
                Write-Log "Skipping database $db (not matching include_databases)" $DEBUG_VERBOSE $Cluster
                continue
            }
        }

        if ($excList.Count -gt 0) {
            $matchedExc = $false
            foreach ($pat in $excList) {
                if ($db -like $pat) { $matchedExc = $true; break }
            }
            if ($matchedExc) {
                Write-Log "Skipping database $db (matching exclude_databases)" $DEBUG_LOG $Cluster
                continue
            }
        }

        $filtered += [PSCustomObject]@{ Name = $db; RawSize = $rawSize }
    }
    return $filtered
}

function Backup-Cluster {
    param($Instance, [string]$Date)
    $cName = $Instance.Cluster
    $path = Join-Path $Settings['backupdir'] (Join-Path $Date (Join-Path $Instance.Version $cName))
    $startTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $startEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    Write-Log "Starting backup Cluster: $cName" 0 $cName
    New-BackupDir $path
    $clusterTemp = Join-Path $Settings['tempdir'] "$($Instance.Version)_$cName"
    New-BackupDir $clusterTemp

    $manifestDatabases = @{}

    try {
        $psqlExe       = Join-Path $Instance.BinDir 'psql.exe'
        $pgDumpExe     = Join-Path $Instance.BinDir 'pg_dump.exe'
        $pgDumpallExe  = Join-Path $Instance.BinDir 'pg_dumpall.exe'
        if (-not (Test-Path -LiteralPath $psqlExe)) { $psqlExe = 'psql' }
        if (-not (Test-Path -LiteralPath $pgDumpExe)) { $pgDumpExe = 'pg_dump' }
        if (-not (Test-Path -LiteralPath $pgDumpallExe)) { $pgDumpallExe = 'pg_dumpall' }

        $sql = "SELECT datname || '|' || pg_database_size(datname) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"
        $databases = & $psqlExe -h localhost -p $Instance.Port -U postgres -w --tuples-only -P format=unaligned -c $sql 2>&1
        if ($LASTEXITCODE -ne 0) { Stop-WithError "Error listing databases for cluster ${cName}: $databases" }

        $rawList = @($databases -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        $filteredList = @(Filter-Databases -DatabasesRaw $rawList -Cluster $cName)

        if ($filteredList.Count -eq 0) {
            Write-Log 'No databases for backup!' 0 $cName
        }
        else {
            $manifestDatabases = Backup-Databases -Databases $filteredList -Path $path -PgDumpExe $pgDumpExe -Instance $Instance -ClusterTemp $clusterTemp
        }

        Write-Log 'Starting backup globals' $DEBUG_LOG $cName
        $globalsFile = Join-Path $clusterTemp 'globals.sql'
        $globalsSize = 0

        if ($Settings['dry_run'] -eq '1') {
            Write-Log "would dump globals to $(Join-Path $path 'globals.sql')" $DEBUG_LOG $cName
        }
        else {
            $out = & $pgDumpallExe -h localhost -p $Instance.Port -U postgres -w -g -f $globalsFile 2>&1
            if ($LASTEXITCODE -ne 0) { Stop-WithError "Error dumping globals for cluster ${cName}: $out" }
            Move-BackupFile $globalsFile (Join-Path $path 'globals.sql')
            $finalGlobals = Join-Path $path 'globals.sql'
            if (Test-Path -LiteralPath $finalGlobals) {
                $globalsSize = (Get-Item -LiteralPath $finalGlobals).Length
            }
        }

        $endEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $manifestObj = [ordered]@{
            version          = $Version
            cluster          = $cName
            pg_version       = [string]$Instance.Version
            date             = $Date
            hostname         = $Settings['hostname']
            start_time       = $startTime
            end_time         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            duration_seconds = ($endEpoch - $startEpoch)
            status           = 'ok'
            databases        = $manifestDatabases
            globals          = [ordered]@{
                file       = 'globals.sql'
                size_bytes = $globalsSize
            }
        }

        if ($Settings['dry_run'] -eq '1') {
            Write-Log "would write $(Join-Path $path 'manifest.json')" $DEBUG_LOG $cName
        }
        else {
            $manifestJson = $manifestObj | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath (Join-Path $path 'manifest.json') -Value $manifestJson
        }

        Remove-ClusterOldBackups -Version $Instance.Version -Cluster $cName
    }
    finally {
        if ($Settings['dry_run'] -ne '1' -and (Test-Path -LiteralPath $clusterTemp)) {
            Remove-Item -LiteralPath $clusterTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Backup-Databases {
    param([object[]]$Databases, [string]$Path, [string]$PgDumpExe, $Instance, [string]$ClusterTemp)
    $cName = $Instance.Cluster
    $manifestMap = [ordered]@{}

    if ($Settings['dry_run'] -eq '1') {
        foreach ($item in $Databases) {
            $db = $item.Name
            $raw = $item.RawSize
            Write-Log "would backup Database: $db (raw size: $(Format-Bytes $raw)) to $(Join-Path $Path "$db.cus")" 0 $cName
            $manifestMap[$db] = [ordered]@{
                raw_size_bytes    = $raw
                backup_file       = "$db.cus"
                backup_size_bytes = 0
                status            = 'dry-run'
            }
        }
        return $manifestMap
    }

    $jobs = [int]$Settings['parallel_jobs']
    if ($jobs -lt 1) { $jobs = 1 }

    $queue = [System.Collections.Generic.Queue[object]]::new([object[]]$Databases)
    $active = @{}
    $failed = $null

    $compressArgs = @()
    if ($Settings['compression']) {
        $cVal = $Settings['compression']
        if ($cVal -match '^\d+$') {
            $compressArgs = @('-Z', $cVal)
        }
        else {
            $compressArgs = @("--compress=$cVal")
        }
    }

    while (($queue.Count -gt 0 -and -not $failed) -or $active.Count -gt 0) {
        while ($queue.Count -gt 0 -and -not $failed -and $active.Count -lt $jobs) {
            $item = $queue.Dequeue()
            $db = $item.Name
            $raw = $item.RawSize
            Write-Log "Starting backup Database: $db (raw size: $(Format-Bytes $raw))" 0 $cName
            $tempFile = Join-Path $ClusterTemp "$db.cus"
            $errFile = "$tempFile.err"
            $psArgs = @('-h', 'localhost', '-p', "$($Instance.Port)", '-U', 'postgres', '-w') + $compressArgs + @('-c', '-F', $Settings['format'], '-f', $tempFile, $db)
            $proc = Start-Process -FilePath $PgDumpExe -ArgumentList $psArgs -PassThru -WindowStyle Hidden -RedirectStandardError $errFile
            $active[$proc.Id] = [PSCustomObject]@{ Process = $proc; Db = $db; RawSize = $raw; TempFile = $tempFile; ErrFile = $errFile }
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
                        $finalPath = Join-Path $Path "$($info.Db).cus"
                        Move-BackupFile $info.TempFile $finalPath
                        $bakSize = 0
                        if (Test-Path -LiteralPath $finalPath) {
                            $bakSize = (Get-Item -LiteralPath $finalPath).Length
                        }
                        $manifestMap[$info.Db] = [ordered]@{
                            raw_size_bytes    = $info.RawSize
                            backup_file       = "$($info.Db).cus"
                            backup_size_bytes = $bakSize
                            status            = 'ok'
                        }
                    }
                    Remove-Item -LiteralPath $info.ErrFile -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($failed) { Stop-WithError $failed }
    return $manifestMap
}

function Invoke-BackupAll {
    New-BackupDir $Settings['tempdir']
    Enter-Lock
    Send-PingWebhook -Endpoint 'start'

    if ($Settings['dry_run'] -eq '1') {
        Write-Log 'Running in DRY-RUN mode — no actual dumps or deletions will be performed.'
    }

    Test-DiskSpace

    $date = Get-Date -Format 'yyyyMMdd'
    New-BackupDir (Join-Path $Settings['backupdir'] $date)
    if (Test-Path -LiteralPath $Settings['tempdir']) {
        if (Test-Path -LiteralPath $Settings['tempdir']) {
        Set-Location $Settings['tempdir']
    }
    }

    $clustersToRun = @()
    foreach ($inst in (Get-PgInstances)) {
        if ([int]$inst.Running -eq 1) {
            $clustersToRun += $inst
        }
        else {
            Write-Log "Cluster: $($inst.Cluster) not running!" $DEBUG_LOG
        }
    }

    $cJobs = [int]$Settings['parallel_clusters']
    if ($cJobs -lt 1) { $cJobs = 1 }

    if ($cJobs -le 1 -or $clustersToRun.Count -le 1 -or $Settings['dry_run'] -eq '1') {
        foreach ($inst in $clustersToRun) {
            Backup-Cluster -Instance $inst -Date $date
        }
    }
    else {
        $cQueue = [System.Collections.Generic.Queue[object]]::new([object[]]$clustersToRun)
        $cActive = @{}
        $cFailed = $null
        $psScript = $PSCommandPath
        if (-not $psScript) { $psScript = $MyInvocation.MyCommand.Path }

        while (($cQueue.Count -gt 0 -and -not $cFailed) -or $cActive.Count -gt 0) {
            while ($cQueue.Count -gt 0 -and -not $cFailed -and $cActive.Count -lt $cJobs) {
                $inst = $cQueue.Dequeue()
                $instJson = $inst | ConvertTo-Json -Compress
                $errFile = Join-Path $Settings['tempdir'] "cluster_$($inst.Cluster)_$($inst.Version).err"
                $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $psScript, '-InternalBackupCluster', $instJson, '-InternalDate', $date)
                if ($IniFile) { $argsList += @('-IniFile', $IniFile) }
                $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -PassThru -WindowStyle Hidden -RedirectStandardError $errFile
                $cActive[$proc.Id] = [PSCustomObject]@{ Process = $proc; Instance = $inst; ErrFile = $errFile }
            }

            if ($cActive.Count -gt 0) {
                Start-Sleep -Milliseconds 200
                foreach ($procId in @($cActive.Keys)) {
                    $info = $cActive[$procId]
                    if ($info.Process.HasExited) {
                        $cActive.Remove($procId)
                        if ($info.Process.ExitCode -ne 0) {
                            $errText = if (Test-Path -LiteralPath $info.ErrFile) { Get-Content -LiteralPath $info.ErrFile -Raw } else { '' }
                            $cFailed = "Error backing up cluster $($info.Instance.Cluster): $errText"
                        }
                        Remove-Item -LiteralPath $info.ErrFile -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        if ($cFailed) { Stop-WithError $cFailed }
    }

    Remove-EmptyDateDirs
    Exit-Lock
    Send-PingWebhook
    Send-BackupMail
}

# ---------- config / usage ----------

function Show-Usage {
    @"
pg_clusterbackup $Version (PowerShell)
----------------------------------------------------------------------------------------------
Backup all PostgreSQL databases from all running instances.

Author: Frank Glück (https://dozent.net)
Create pg_clusterbackup.ini with settings to override defaults
You can combine -IniWrite with other options to generate an ini file with those values

-Help                       shows this page
-IniWrite                   write ini file with current settings [$IniFile]
-IniShow                    shows ini file with current settings
-Email                      recipient for log
-ExcludeDatabases           comma-separated glob patterns of databases to exclude
-IncludeDatabases           comma-separated glob patterns of databases to include
-PingUrl                    healthcheck ping URL (start/fail/ok)
-Compression (-Z)           compression spec/level for pg_dump (e.g. 6 or zstd:3)
-DryRun (-WhatIf)           simulate run without dumping or deleting files

-i / -IniFile               path and filename for ini file
-h / -Hostname              hostname (default is system hostname)
-DebugLevel (-dl)           debug level 0=off, 1=log (default), 2=terse, 3=verbose

Folders
-D / -BackupDir             backup dir
-T / -TempDir               temp dir     [$($Settings['tempdir'])]
-L / -LogDir                log dir      [$($Settings['logdir'])] (default: backup dir)

Backup settings
-F / -Format                dump format (c|t|p)
-n / -MaxKeep               max number of backup generations to keep
-j / -Jobs                  max concurrent pg_dump processes per cluster (default 1)
-C / -ParallelClusters (-cj) max concurrent cluster backups (default 1)

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

$Settings['hostname']          = if ($Bound.ContainsKey('Hostname'))          { $Hostname }          elseif ($Settings['hostname'])          { $Settings['hostname'] }          else { $env:COMPUTERNAME }
$Settings['backupdir']         = if ($Bound.ContainsKey('BackupDir'))         { $BackupDir }         elseif ($Settings['backupdir'])         { $Settings['backupdir'] }         else { 'C:\Backup\PostgreSQL' }
$Settings['tempdir']           = if ($Bound.ContainsKey('TempDir'))           { $TempDir }           elseif ($Settings['tempdir'])           { $Settings['tempdir'] }           else { $env:TEMP }
$Settings['email']             = if ($Bound.ContainsKey('Email'))             { $Email }             elseif ($Settings['email'])             { $Settings['email'] }             else { 'monitor@ibou.net' }
$Settings['maxkeep']           = if ($Bound.ContainsKey('MaxKeep'))           { $MaxKeep }           elseif ($Settings['maxkeep'])           { $Settings['maxkeep'] }           else { '7' }
$Settings['format']            = if ($Bound.ContainsKey('Format'))            { $Format }            elseif ($Settings['format'])            { $Settings['format'] }            else { 'c' }
$Settings['logdir']            = if ($Bound.ContainsKey('LogDir'))            { $LogDir }            elseif ($Settings['logdir'])            { $Settings['logdir'] }            else { $Settings['backupdir'] }
$Settings['debug_level']       = if ($Bound.ContainsKey('DebugLevel'))        { $DebugLevel }        elseif ($null -ne $Settings['debug_level']) { $Settings['debug_level'] } else { '1' }
$Settings['parallel_jobs']     = if ($Bound.ContainsKey('Jobs'))              { $Jobs }              elseif ($Settings['parallel_jobs'])     { $Settings['parallel_jobs'] }     else { '1' }
$Settings['parallel_clusters'] = if ($Bound.ContainsKey('ParallelClusters'))  { $ParallelClusters }  elseif ($Settings['parallel_clusters']) { $Settings['parallel_clusters'] } else { '1' }
$Settings['compression']       = if ($Bound.ContainsKey('Compression'))       { $Compression }       elseif ($Settings['compression'])       { $Settings['compression'] }       else { '' }
$Settings['exclude_databases'] = if ($Bound.ContainsKey('ExcludeDatabases'))  { $ExcludeDatabases }  elseif ($Settings['exclude_databases']) { $Settings['exclude_databases'] } else { '' }
$Settings['include_databases'] = if ($Bound.ContainsKey('IncludeDatabases'))  { $IncludeDatabases }  elseif ($Settings['include_databases']) { $Settings['include_databases'] } else { '' }
$Settings['ping_url']          = if ($Bound.ContainsKey('PingUrl'))           { $PingUrl }           elseif ($Settings['ping_url'])          { $Settings['ping_url'] }          else { '' }
$Settings['min_free_space_gb'] = if ($Settings.Contains('min_free_space_gb')) { $Settings['min_free_space_gb'] } else { '0' }
$Settings['dry_run']           = if ($DryRun.IsPresent) { '1' } elseif ($Settings.Contains('dry_run')) { $Settings['dry_run'] } else { '0' }
$Settings['smtp_server']       = if ($Settings.Contains('smtp_server'))       { $Settings['smtp_server'] } else { '' }

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

if ($InternalBackupCluster -and $InternalDate) {
    $inst = $InternalBackupCluster | ConvertFrom-Json
    if (Test-Path -LiteralPath $Settings['tempdir']) {
        Set-Location $Settings['tempdir']
    }
    Backup-Cluster -Instance $inst -Date $InternalDate
    exit 0
}

try {
    Invoke-BackupAll
}
catch {
    Stop-WithError $_.Exception.Message
}
