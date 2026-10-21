#!/usr/bin/php
<?php
/**
 * pg_clusterbackup 1.8.0
 * A class which backups all PostgreSQL clusters with all databases in separate files
 * Don't edit the source, create a ini-file
 *
 * usage sample:
 * ./pg_clusterbackup.php --ini-write
 * ./pg_clusterbackup.php -D /backup/folder --email mail@to.me
 * additional parameters will also saved in ini-file
 * edit/modify the file pg_clusterbackup.ini for your behaviour or set values with -xy=123 and --ini-write to persist it
 * add to cron with or without any parameters (if you edit the .ini)
 *
 * Changelog:
 * 1.8.0
 * - added database include/exclude filters (exclude_databases, include_databases, --exclude, --include)
 * - added pg_database_size querying and pre-flight disk space check (min_free_space_gb)
 * - added dry-run simulation mode (-N / --dry-run)
 * - added compression level tuning (-Z / --compress / compression)
 * - added backup manifest (manifest.json) per cluster
 * - added healthcheck / monitoring webhook (ping_url / --ping-url)
 * 1.7.0
 * - added -C/parallel_clusters: dump up to N clusters concurrently (default 1 = unchanged sequential behavior).
 * - added per-cluster tempdir isolation (<tempdir>/<version>_<cluster>/) to prevent file collisions.
 * - added per-cluster rotation immediately after each cluster backup completes.
 * - added cluster prefix [<cluster>] to cluster-specific log lines for clean interleaved logging.
 * 1.6.0
 * - added -j/parallel_jobs: dump up to N databases per cluster concurrently via proc_open()
 *   worker pool (default 1 = unchanged sequential behavior). See SPEC.md "Parallel database
 *   dumps" -- deliberately not pg_dump's own -j, which requires the directory format.
 * 1.5.0
 * - no functional changes; version bumped to match the 1.5.0 project release (PowerShell port added)
 * 1.4.0
 * - no functional changes; version bumped to match the 1.4.0 project release (bash port added)
 * 1.3.0
 * - added RHEL/CentOS/Rocky/Alma support: falls back to scanning pgdata_globs + postmaster.pid
 *   when pg_lsclusters isn't installed (see SPEC.md "Cluster / instance discovery")
 * - fixed ini_get_settings() writing array settings under a [section] header, which caused every
 *   setting written after it to be silently nested inside that array on the next --ini-write/read
 * 1.2.0
 * - fixed load_ini() referencing an undefined $conf variable (fatal TypeError after first --ini-write)
 * - fixed getopt() to actually parse -D/-T/-L/-F/-h/-d/-n/--email (previously silently ignored)
 * - fixed mkdir() using decimal 700 instead of octal 0700 permissions
 * - old backups are now only deleted after a successful backup run, not before
 * - shell arguments are now escaped (escapeshellarg) to avoid breakage/injection on special characters
 * - rename() between tempdir/backupdir now falls back to copy+unlink for cross-filesystem moves, and errors are checked
 * - fixed fatal error in the catch-block when construction itself fails (undefined $pg)
 * - added a lock file so overlapping cron runs can't corrupt each other's temp files
 * - restrict umask so temp dump files aren't world-readable
 *
 **/
class pg_clusterbackup {
  public const VERSION = '1.8.0';

  public const DEBUG_NONE    = 0;
  public const DEBUG_LOG     = 1;
  public const DEBUG_TERSE   = 2;
  public const DEBUG_VERBOSE = 3;

  public  array  $settings = [];
  public  bool   $debug    = false;
  public  int    $debug_level = self::DEBUG_TERSE;
  public  array  $log      = [];
  private string $logfile  = '';

  private ?string $ini_file = null;
  private $lock_fp  = null;

  public function __construct($conf=[]) {
    umask(0077);
    if(empty($conf)) $conf = $this->args();
    $this->conf($conf);
    $this->settings['logdir'] ??= '';
    $this->checkdir($this->settings['logdir']);
    $this->logfile = "{$this->settings['logdir']}/pg_backupcluster.log";
    $this->log(print_r($this->settings, true), self::DEBUG_VERBOSE);
  }

  public function conf($conf) {
    $this->ini_file                = $conf['i']        ?? dirname(__FILE__).'/pg_clusterbackup.ini';
    $this->settings = $this->load_ini($this->ini_file);
    $this->settings['hostname']    = $conf['h']        ?? $this->settings['hostname']    ?? gethostname();
    $this->settings['backupdir']   = $conf['D']        ?? $this->settings['backupdir']   ?? '/data/backup/postgresql';
    $this->settings['tempdir']     = $conf['T']        ?? $this->settings['tempdir']     ?? '/tmp';
    $this->settings['email']       = $conf['email']    ?? $this->settings['email']       ?? 'monitor@ibou.net';
    $this->settings['maxkeep']     = intval($conf['n'] ?? $this->settings['maxkeep']     ?? 7);
    $this->settings['format']      = $conf['F']        ?? $this->settings['format']      ?? 'c'; # Custom Format
    $this->settings['logdir']      = $conf['L']        ?? $this->settings['logdir']      ?? $this->settings['backupdir'];
    $this->settings['debug_level'] = $conf['d']        ?? $this->settings['debug_level'] ?? self::DEBUG_LOG;
    $this->settings['pgdata_globs'] ??= ['/var/lib/pgsql/data', '/var/lib/pgsql/*/data'];
    $this->settings['parallel_jobs'] = intval($conf['j'] ?? $this->settings['parallel_jobs'] ?? 1);
    $this->settings['parallel_clusters'] = intval($conf['C'] ?? $this->settings['parallel_clusters'] ?? 1);

    // v1.8.0 new options
    $this->settings['exclude_databases'] = $conf['exclude'] ?? $this->settings['exclude_databases'] ?? '';
    $this->settings['include_databases'] = $conf['include'] ?? $this->settings['include_databases'] ?? '';
    $this->settings['min_free_space_gb'] = intval($conf['min_free_space_gb'] ?? $this->settings['min_free_space_gb'] ?? 0);
    $this->settings['compression']       = $conf['Z'] ?? $conf['compress'] ?? $this->settings['compression'] ?? '';
    $this->settings['ping_url']          = $conf['ping-url'] ?? $this->settings['ping_url'] ?? '';
    $this->settings['dry_run']           = isset($conf['N']) || isset($conf['dry-run']) || !empty($this->settings['dry_run']);

    $this->help(isset($conf['help']));
  }

  private function load_ini($ini) {
    if(file_exists($ini)) {
      $parsed = parse_ini_file($ini, true, INI_SCANNER_TYPED);
      return $parsed === false ? [] : $parsed;
    }
    return [];
  }

  public function ini_get_settings() : string {
    $out = [];
    foreach($this->settings as $key => $value) {
      if(is_array($value)) {
        foreach($value as $v) $out[] = sprintf("%-20s = \"%s\"", "{$key}[]", $v);
      }
      else {
        // don't serialize runtime flags
        if(in_array($key, ['dry_run'])) continue;
        $out[] = sprintf("%-20s = \"%s\"", $key, $value);
      }
    }
    return implode("\n", $out)."\n";
  }

  public function ini_write() {
    file_put_contents($this->ini_file, $this->ini_get_settings());
  }

  public function ping(string $endpoint='', string $msg='') {
    if(empty($this->settings['ping_url'])) return;
    $url = rtrim($this->settings['ping_url'], '/');
    if(!empty($endpoint)) {
      $url .= '/' . ltrim($endpoint, '/');
    }
    $ctx = stream_context_create([
      'http' => [
        'method'  => empty($msg) ? 'GET' : 'POST',
        'header'  => "Content-type: text/plain\r\n",
        'content' => $msg,
        'timeout' => 10,
        'ignore_errors' => true
      ]
    ]);
    @file_get_contents($url, false, $ctx);
  }

  public function mail($status='🟢 OK') {
    if($this->settings['dry_run']) {
      $status = '🟡 DRY-RUN';
    }
    if(!empty($this->settings['email']) and !empty($this->log)) {
      @mail($this->settings['email'], '=?utf-8?B?'.base64_encode("{$status} {$this->settings['hostname']} PG Backup Log").'?=', implode("\r\n", $this->log), ['From'=> "root@{$this->settings['hostname']}"]);
    }
  }

  public function checkdir(string $dir) {
    if(!is_dir($dir)) {
      if(!$this->settings['dry_run']) {
        mkdir($dir, 0700, true);
      }
    }
  }

  public function format_bytes(int|float $bytes) : string {
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    for ($i = 0; $bytes >= 1024 && $i < 4; $i++) $bytes /= 1024;
    return sprintf('%.2f %s', $bytes, $units[$i]);
  }

  public function check_disk_space() {
    $minGb = (int)$this->settings['min_free_space_gb'];
    if($minGb <= 0) return;
    $minBytes = $minGb * 1024 * 1024 * 1024;

    foreach (['backupdir', 'tempdir'] as $dirKey) {
      $path = $this->settings[$dirKey];
      if(!file_exists($path)) {
        $checkPath = dirname($path);
      } else {
        $checkPath = $path;
      }
      $free = @disk_free_space($checkPath);
      if($free !== false) {
        $this->log("Checking free disk space on {$dirKey} ({$checkPath}): " . $this->format_bytes($free), self::DEBUG_VERBOSE);
        if($free < $minBytes) {
          throw new Exception("Insufficient disk space on {$dirKey} ({$checkPath}): " . $this->format_bytes($free) . " free, required: {$minGb} GB");
        }
      }
    }
  }

  private function lock() {
    if($this->settings['dry_run']) return;
    $lockfile = "{$this->settings['tempdir']}/pg_clusterbackup.lock";
    $this->lock_fp = fopen($lockfile, 'c');
    if(!$this->lock_fp || !flock($this->lock_fp, LOCK_EX | LOCK_NB)) {
      throw new Exception("Another backup run seems to be in progress (lock: {$lockfile})");
    }
  }

  private function unlock() {
    if($this->lock_fp) {
      flock($this->lock_fp, LOCK_UN);
      fclose($this->lock_fp);
      $this->lock_fp = null;
    }
  }

  public function log(string $txt, $debug_level=0, ?string $cluster=null) {
    if($this->debug_level >= $debug_level or $this->debug) {
      $prefix = '';
      if($this->settings['dry_run']) $prefix .= '[DRY-RUN] ';
      if($cluster !== null) $prefix .= "[{$cluster}] ";
      $line = sprintf('%s %s%s', date('Y-m-d H:i:s'), $prefix, $txt);
      $this->log[] = $line;
      if(!$this->settings['dry_run'] && !empty($this->logfile)) {
        file_put_contents($this->logfile, $line.PHP_EOL , FILE_APPEND | LOCK_EX);
      }
    }
  }

  public function delete_cluster(string $version, string $cluster) {
    $matches = glob("{$this->settings['backupdir']}/[0-9]*/{$version}/{$cluster}", GLOB_ONLYDIR);
    if(!$matches) return;
    rsort($matches);
    $delete = array_slice($matches, $this->settings['maxkeep']);
    foreach($delete as $d) {
      if($this->settings['dry_run']) {
        $this->log("would remove old backup directory {$d}", self::DEBUG_TERSE, $cluster);
      } else {
        $this->log("removing {$d}", self::DEBUG_TERSE, $cluster);
        $this->exec('rm -rf '.escapeshellarg($d), $cluster);
        $parent = dirname($d); // version dir
        if(is_dir($parent) && count(scandir($parent)) <= 2) {
          @rmdir($parent);
        }
        $grandparent = dirname($parent); // date dir
        if(is_dir($grandparent) && count(scandir($grandparent)) <= 2) {
          @rmdir($grandparent);
        }
      }
    }
  }

  public function delete_empty_dates() {
    if($this->settings['dry_run']) return;
    $dateDirs = glob("{$this->settings['backupdir']}/[0-9]*", GLOB_ONLYDIR);
    if(!$dateDirs) return;
    foreach($dateDirs as $d) {
      if(is_dir($d) && count(scandir($d)) <= 2) {
        @rmdir($d);
      }
    }
  }

  public function clusters() {
    if(trim((string)shell_exec('command -v pg_lsclusters 2>/dev/null'))) {
      return json_decode(shell_exec('pg_lsclusters -h -j'), true);
    }
    return $this->scan_instances();
  }

  private function scan_instances() {
    $instances = [];
    foreach($this->settings['pgdata_globs'] as $glob_pattern) {
      foreach(glob($glob_pattern) as $datadir) {
        $version_file = "{$datadir}/PG_VERSION";
        if(!is_file($version_file)) continue;
        $pidfile = "{$datadir}/postmaster.pid";
        $running = is_file($pidfile);
        $port = $socketdir = null;
        if($running) {
          $lines     = file($pidfile, FILE_IGNORE_NEW_LINES);
          $port      = $lines[3] ?? null;
          $socketdir = explode(',', $lines[4] ?? '')[0] ?: null;
        }
        $instances[] = [
          'version'   => trim(file_get_contents($version_file)),
          'cluster'   => 'main',
          'running'   => $running ? 1 : 0,
          'port'      => $port,
          'socketdir' => $socketdir,
        ];
      }
    }
    return $instances;
  }

  public function exec(string $cmd, ?string $cluster=null) {
    $out = $ret = null;
    exec($cmd, $out, $ret);
    $this->log($cmd, $ret ? 0 : self::DEBUG_VERBOSE, $cluster);
    $this->log(implode(PHP_EOL, $out), $ret ? self::DEBUG_LOG : self::DEBUG_VERBOSE, $cluster);
    if($ret!=0) throw new Exception("Error on executing {$cmd}");
    return $out;
  }

  private function move_file(string $from, string $to) {
    if($this->settings['dry_run']) return;
    if(!rename($from, $to)) {
      if(!copy($from, $to)) throw new Exception("Failed to move {$from} to {$to}");
      unlink($from);
    }
  }

  private function filter_databases(array $rawDatabases, string $cName): array {
    $result = [];
    $includes = array_filter(array_map('trim', explode(',', $this->settings['include_databases'] ?? '')));
    $excludes = array_filter(array_map('trim', explode(',', $this->settings['exclude_databases'] ?? '')));

    foreach ($rawDatabases as $entry) {
      $parts = explode('|', trim($entry));
      $db = $parts[0];
      $size = isset($parts[1]) ? (int)$parts[1] : 0;
      if(empty($db)) continue;

      if(!empty($includes)) {
        $matchedInclude = false;
        foreach ($includes as $pattern) {
          if(fnmatch($pattern, $db, FNM_CASEFOLD)) {
            $matchedInclude = true;
            break;
          }
        }
        if(!$matchedInclude) {
          $this->log("Skipping database {$db} (not matching include_databases)", self::DEBUG_VERBOSE, $cName);
          continue;
        }
      }

      if(!empty($excludes)) {
        $matchedExclude = false;
        foreach ($excludes as $pattern) {
          if(fnmatch($pattern, $db, FNM_CASEFOLD)) {
            $matchedExclude = true;
            break;
          }
        }
        if($matchedExclude) {
          $this->log("Skipping database {$db} (matching exclude_databases)", self::DEBUG_LOG, $cName);
          continue;
        }
      }

      $result[] = ['name' => $db, 'raw_size' => $size];
    }
    return $result;
  }

  public function backup($cluster, $date) {
    $cName = $cluster['cluster'];
    $path = "{$this->settings['backupdir']}/{$date}/{$cluster['version']}/{$cName}";
    $startTime = date('c');
    $startEpoch = time();

    $this->log("Starting backup Cluster: {$cName}", 0, $cName);
    $this->checkdir($path);
    $clustertemp = "{$this->settings['tempdir']}/{$cluster['version']}_{$cName}";
    $this->checkdir($clustertemp);

    $manifest = [
      'version'          => self::VERSION,
      'cluster'          => $cName,
      'pg_version'       => (string)$cluster['version'],
      'date'             => $date,
      'hostname'         => $this->settings['hostname'],
      'start_time'       => $startTime,
      'end_time'         => null,
      'duration_seconds' => null,
      'status'           => 'ok',
      'databases'        => [],
      'globals'          => null,
    ];

    try {
      $socketdir = escapeshellarg($cluster['socketdir']);
      $port      = escapeshellarg($cluster['port']);
      $sql = "SELECT datname || '|' || pg_database_size(datname) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'";
      $rawDatabases = $this->exec("sudo -u postgres psql -h {$socketdir} -p {$port} -U postgres --tuples-only -P format=unaligned -c ".escapeshellarg($sql), $cName);
      
      $databases = $this->filter_databases($rawDatabases, $cName);
      if(count($databases) == 0) $this->log('No databases for backup!', 0, $cName);

      $manifestDatabases = $this->backup_databases($databases, $path, $socketdir, $port, $cName, $clustertemp);
      $manifest['databases'] = $manifestDatabases;

      $this->log('Starting backup globals', self::DEBUG_LOG, $cName);
      $globalsfile = "{$clustertemp}/globals.sql";
      if($this->settings['dry_run']) {
        $this->log("would dump globals to {$path}/globals.sql", self::DEBUG_LOG, $cName);
        $manifest['globals'] = ['file' => 'globals.sql', 'size_bytes' => 0];
      } else {
        $this->exec("sudo -u postgres pg_dumpall -g -h {$socketdir} -p {$port} -f ".escapeshellarg($globalsfile), $cName);
        $this->move_file($globalsfile, "{$path}/globals.sql");
        $globalsSize = file_exists("{$path}/globals.sql") ? filesize("{$path}/globals.sql") : 0;
        $manifest['globals'] = ['file' => 'globals.sql', 'size_bytes' => $globalsSize];
      }

      $endEpoch = time();
      $manifest['end_time'] = date('c');
      $manifest['duration_seconds'] = $endEpoch - $startEpoch;

      if(!$this->settings['dry_run']) {
        file_put_contents("{$path}/manifest.json", json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
      } else {
        $this->log("would write {$path}/manifest.json", self::DEBUG_LOG, $cName);
      }

      $this->delete_cluster((string)$cluster['version'], $cName);
    }
    finally {
      if(!$this->settings['dry_run'] && is_dir($clustertemp)) {
        @rmdir($clustertemp);
      }
    }
  }

  private function backup_databases(array $databases, string $path, string $socketdir, string $port, string $cName, string $clustertemp): array {
    $manifestData = [];
    if($this->settings['dry_run']) {
      foreach ($databases as $dbInfo) {
        $db = $dbInfo['name'];
        $rawSize = $dbInfo['raw_size'];
        $this->log("would backup Database: {$db} (raw size: " . $this->format_bytes($rawSize) . ") to {$path}/{$db}.cus", 0, $cName);
        $manifestData[$db] = [
          'raw_size_bytes'    => $rawSize,
          'backup_file'       => "{$db}.cus",
          'backup_size_bytes' => 0,
          'status'            => 'dry-run'
        ];
      }
      return $manifestData;
    }

    $jobs    = max(1, (int)$this->settings['parallel_jobs']);
    $queue   = $databases;
    $running = [];
    $failed  = null;

    $compressFlag = '';
    if(!empty($this->settings['compression'])) {
      $comp = $this->settings['compression'];
      if(is_numeric($comp)) {
        $compressFlag = "-Z " . escapeshellarg($comp);
      } else {
        $compressFlag = "--compress=" . escapeshellarg($comp);
      }
    }

    while(($queue && !$failed) || $running) {
      while($queue && !$failed && count($running) < $jobs) {
        $dbInfo = array_shift($queue);
        $db = $dbInfo['name'];
        $rawSize = $dbInfo['raw_size'];
        $this->log("Starting backup Database: {$db} (raw size: " . $this->format_bytes($rawSize) . ")", 0, $cName);
        $tempfile = "{$clustertemp}/{$db}.cus";
        $cmd = "sudo -u postgres pg_dump -c -h {$socketdir} -p {$port} {$compressFlag} -F{$this->settings['format']} -f "
             . escapeshellarg($tempfile)." ".escapeshellarg($db);
        $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if($proc === false) { $failed = "Failed to start pg_dump for {$db}"; break; }
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $running[] = ['db' => $db, 'raw_size' => $rawSize, 'proc' => $proc, 'pipes' => $pipes, 'tempfile' => $tempfile, 'out' => ''];
      }

      foreach($running as $idx => &$job) {
        $job['out'] .= stream_get_contents($job['pipes'][1]);
        $job['out'] .= stream_get_contents($job['pipes'][2]);
        if(!proc_get_status($job['proc'])['running']) {
          fclose($job['pipes'][1]);
          fclose($job['pipes'][2]);
          $ret = proc_close($job['proc']);
          if($ret !== 0) {
            $failed = "Error dumping database {$job['db']}: {$job['out']}";
          }
          else {
            $finalPath = "{$path}/{$job['db']}.cus";
            $this->move_file($job['tempfile'], $finalPath);
            $backupSize = file_exists($finalPath) ? filesize($finalPath) : 0;
            $manifestData[$job['db']] = [
              'raw_size_bytes'    => $job['raw_size'],
              'backup_file'       => "{$job['db']}.cus",
              'backup_size_bytes' => $backupSize,
              'status'            => 'ok'
            ];
          }
          unset($running[$idx]);
        }
      }
      unset($job);
      $running = array_values($running);
      if($running) usleep(50000);
    }

    if($failed) throw new Exception($failed);
    return $manifestData;
  }

  public function backupall() {
    $this->lock();
    $this->ping('start');

    if($this->settings['dry_run']) {
      $this->log('Running in DRY-RUN mode — no actual dumps or deletions will be performed.');
    }

    $this->check_disk_space();

    $date = date('Ymd');
    $this->checkdir("{$this->settings['backupdir']}/{$date}");
    chdir($this->settings['tempdir']);

    $clustersToRun = [];
    foreach($this->clusters() as $c) {
      if($c['running']==1) {
        $clustersToRun[] = $c;
      }
      else {
        $this->log("Cluster: {$c['cluster']} not running!", self::DEBUG_LOG);
      }
    }

    $cJobs = max(1, (int)$this->settings['parallel_clusters']);
    if($cJobs <= 1 || count($clustersToRun) <= 1 || $this->settings['dry_run']) {
      foreach($clustersToRun as $c) {
        $this->backup($c, $date);
      }
    }
    else {
      $queue = $clustersToRun;
      $active = [];
      $failed = null;
      $scriptPath = realpath(__FILE__);

      while(($queue && !$failed) || $active) {
        while($queue && !$failed && count($active) < $cJobs) {
          $c = array_shift($queue);
          $clusterJson = escapeshellarg(json_encode($c));
          $cmd = escapeshellarg(PHP_BINARY) . " " . escapeshellarg($scriptPath) . " --internal-backup-cluster={$clusterJson} --internal-date={$date}";
          if(!empty($this->ini_file)) {
            $cmd .= " -i " . escapeshellarg($this->ini_file);
          }
          $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
          if($proc === false) { $failed = "Failed to launch worker for cluster {$c['cluster']}"; break; }
          stream_set_blocking($pipes[1], false);
          stream_set_blocking($pipes[2], false);
          $active[] = ['cluster' => $c, 'proc' => $proc, 'pipes' => $pipes, 'out' => ''];
        }

        foreach($active as $idx => &$job) {
          $job['out'] .= stream_get_contents($job['pipes'][1]);
          $job['out'] .= stream_get_contents($job['pipes'][2]);
          if(!proc_get_status($job['proc'])['running']) {
            fclose($job['pipes'][1]);
            fclose($job['pipes'][2]);
            $ret = proc_close($job['proc']);
            if($ret !== 0) {
              $failed = "Error backing up cluster {$job['cluster']['cluster']}: {$job['out']}";
            }
            unset($active[$idx]);
          }
        }
        unset($job);
        $active = array_values($active);
        if($active) usleep(50000);
      }

      if($failed) throw new Exception($failed);
    }

    $this->delete_empty_dates();
    $this->unlock();
    $this->ping();
    $this->mail();
  }

  static public function run() {
    $conf = static::args();
    if(isset($conf['internal-backup-cluster']) && isset($conf['internal-date'])) {
      $c = json_decode($conf['internal-backup-cluster'], true);
      $date = (string)$conf['internal-date'];
      $pg = new static($conf);
      chdir($pg->settings['tempdir']);
      $pg->backup($c, $date);
      exit(0);
    }
    else if(isset($conf['ini-show'])) {
      echo (new static($conf))->ini_get_settings();
    }
    else if(isset($conf['ini-write'])) {
      (new static($conf))->ini_write();
      echo "ini file written to location of this script";
    }
    else {
      $pg = null;
      try {
        $pg = new static($conf);
        $pg->backupall();
      }
      catch (Exception $e){
        if($pg) {
          $pg->log("FATAL: {$e->getMessage()}");
          $pg->ping('fail', $e->getMessage());
          $pg->mail('🟥 failed');
        }
        else {
          fwrite(STDERR, "FATAL: {$e->getMessage()}".PHP_EOL);
        }
      }
    }
  }

  static private function args() {
    $args = getopt('i::h:D:T:L:F:d:n:j:C:Z:N', [
      'help',
      'ini-write',
      'ini-show',
      'email:',
      'compress:',
      'exclude:',
      'include:',
      'ping-url:',
      'dry-run',
      'internal-backup-cluster:',
      'internal-date:'
    ]);
    return $args;
  }

  public function help($is_help) {
    if($is_help) {
      $version = self::VERSION;
      echo <<<TXT
        pg_clusterbackup {$version}
        ----------------------------------------------------------------------------------------------
        Backup all PostgreSQL Databases from all running Clusters.

        Author: Frank Glück (https://dozent.net)
        Create pg_clusterbackup.ini with settings for override defaults
        You can combine --ini-write with some other parameters to generate ini-file with given values

        --help         shows this page
        --ini-write    write ini-file with current settings [{$this->ini_file}]
        --ini-show     shows ini-file with current settings
        --email        recipient for log
        --exclude      comma-separated glob patterns of databases to exclude
        --include      comma-separated glob patterns of databases to include
        --ping-url     healthcheck ping URL (start/fail/ok)
        --compress     compression spec/level for pg_dump (e.g. 6 or zstd:3)
        --dry-run, -N  simulate run without dumping or deleting files

        -i      path and filename for ini-file
        -h      hostname (default is system hostname())
        -d      debug level 0=off, 1=log (default), 2=terse, 3=verbose

        Folders
        -D     backup dir
        -T     temp dir     [{$this->settings['tempdir']}]
        -L     log_dir      [{$this->settings['logdir']}] (default: backup dir)

        Backup-Settings
        -F     Dump-Format (c|t|p)
        -n     max number of backup generations to keep
        -j     max concurrent pg_dump processes per cluster (default 1)
        -C     max concurrent cluster backups (default 1)
        -Z     compression level/spec for pg_dump
        -N     dry-run simulation mode

        TXT;
      die();
    }
  }
}

pg_clusterbackup::run();
