#!/usr/bin/php
<?php
/**
 * pg_clusterbackup 1.6.0
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
  public const VERSION = '1.7.0';

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
#    $this->debug = true;
    $this->conf($conf);
    $this->settings['logdir'] ??= '';
    $this->checkdir($this->settings['logdir']);
    $this->logfile              = "{$this->settings['logdir']}/pg_backupcluster.log";
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
        $out[] = sprintf("%-20s = \"%s\"", $key, $value);
      }
    }
    return implode("\n", $out)."\n";
  }
  public function ini_write() {
    file_put_contents($this->ini_file, $this->ini_get_settings());
  }
  public function mail($status='🟢 OK') {
    if(!empty($this->settings['email']) and !empty($this->log)) {
      mail($this->settings['email'], '=?utf-8?B?'.base64_encode("{$status} {$this->settings['hostname']} PG Backup Log").'?=', implode("\r\n", $this->log), ['From'=> "root@{$this->settings['hostname']}"]);
    }
  }
  public function checkdir(string $dir) {
    if(!is_dir($dir)) {
      mkdir($dir, 0700, true);
    }
  }
  /**
   * Acquire an exclusive lock so overlapping cron runs can't collide on shared temp files
   */
  private function lock() {
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
  /**
   * Logs text to logfile and for daily mail
   * @param $txt Text to log
   */
  /**
   * Logs text to logfile and for daily mail, optionally prefixed with cluster name
   * @param $txt Text to log
   */
  public function log(string $txt, $debug_level=0, ?string $cluster=null) {
    if($this->debug_level >= $debug_level or $this->debug) {
      $prefix = $cluster !== null ? "[{$cluster}] " : '';
      $line = sprintf('%s %s%s', date('Y-m-d H:i:s'), $prefix, $txt);
      $this->log[] = $line;
      file_put_contents($this->logfile, $line.PHP_EOL , FILE_APPEND | LOCK_EX);
    }
  }
  /**
   * Deletes overaged backup dirs for a specific cluster immediately after completion
   */
  public function delete_cluster(string $version, string $cluster) {
    $matches = glob("{$this->settings['backupdir']}/[0-9]*/{$version}/{$cluster}", GLOB_ONLYDIR);
    if(!$matches) return;
    rsort($matches);
    $delete = array_slice($matches, $this->settings['maxkeep']);
    foreach($delete as $d) {
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
  /**
   * Clean up any remaining completely empty date directories
   */
  public function delete_empty_dates() {
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
  /**
   * Fallback discovery for distros without pg_lsclusters (RHEL/CentOS/Rocky/Alma and others):
   * scans configured data-directory globs and reads postmaster.pid directly. Its format (port
   * on line 4, socket dir on line 5) is a PostgreSQL server guarantee, not a distro convention,
   * so this works the same way pg_ctl/pg_isready determine a running instance's port.
   */
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
  /**
   * Moves a file, falling back to copy+unlink when source and destination
   * are on different filesystems (rename() can't cross filesystem boundaries)
   */
  private function move_file(string $from, string $to) {
    if(!rename($from, $to)) {
      if(!copy($from, $to)) throw new Exception("Failed to move {$from} to {$to}");
      unlink($from);
    }
  }
  /**
   * Backup a PG cluster
   */
  public function backup($cluster, $date) {
    $cName = $cluster['cluster'];
    $path = "{$this->settings['backupdir']}/{$date}/{$cluster['version']}/{$cName}";
    $this->log("Starting backup Cluster: {$cName}", 0, $cName);
    $this->checkdir($path);
    $clustertemp = "{$this->settings['tempdir']}/{$cluster['version']}_{$cName}";
    $this->checkdir($clustertemp);

    try {
      $socketdir = escapeshellarg($cluster['socketdir']);
      $port      = escapeshellarg($cluster['port']);
      $sql="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'";
      $databases = $this->exec("sudo -u postgres psql -h {$socketdir} -p {$port} -U postgres --tuples-only -P format=unaligned -c ".escapeshellarg($sql), $cName);
      if(count($databases)==0) $this->log('No databases for backup!', 0, $cName);
      $this->backup_databases($databases, $path, $socketdir, $port, $cName, $clustertemp);
      $this->log('Starting backup globals', self::DEBUG_LOG, $cName);
      $globalsfile = "{$clustertemp}/globals.sql";
      $this->exec("sudo -u postgres pg_dumpall -g -h {$socketdir} -p {$port} -f ".escapeshellarg($globalsfile), $cName);
      $this->move_file($globalsfile, "{$path}/globals.sql");
      $this->delete_cluster((string)$cluster['version'], $cName);
    }
    finally {
      if(is_dir($clustertemp)) {
        @rmdir($clustertemp);
      }
    }
  }
  /**
   * Dumps up to `parallel_jobs` databases concurrently (default 1 = today's sequential
   * behavior). Not pg_dump's own -j/--jobs: that requires the directory format and would break
   * the single-file-per-database restore story. See SPEC.md "Parallel database dumps".
   */
  private function backup_databases(array $databases, string $path, string $socketdir, string $port, string $cName, string $clustertemp) {
    $jobs    = max(1, (int)$this->settings['parallel_jobs']);
    $queue   = $databases;
    $running = [];
    $failed  = null;

    while(($queue && !$failed) || $running) {
      while($queue && !$failed && count($running) < $jobs) {
        $db = array_shift($queue);
        $this->log("Starting backup Database: {$db} ", 0, $cName);
        $tempfile = "{$clustertemp}/{$db}.cus";
        $cmd = "sudo -u postgres pg_dump -c -h {$socketdir} -p {$port} -F{$this->settings['format']} -f "
             . escapeshellarg($tempfile)." ".escapeshellarg($db);
        $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if($proc === false) { $failed = "Failed to start pg_dump for {$db}"; break; }
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $running[] = ['db' => $db, 'proc' => $proc, 'pipes' => $pipes, 'tempfile' => $tempfile, 'out' => ''];
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
            $this->move_file($job['tempfile'], "{$path}/{$job['db']}.cus");
          }
          unset($running[$idx]);
        }
      }
      unset($job);
      $running = array_values($running);
      if($running) usleep(50000);
    }

    if($failed) throw new Exception($failed);
  }
  public function backupall() {
    $this->lock();
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
    if($cJobs <= 1 || count($clustersToRun) <= 1) {
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
          $pg->mail('🟥 failed');
        }
        else {
          fwrite(STDERR, "FATAL: {$e->getMessage()}".PHP_EOL);
        }
      }
    }
  }
  static private function args() {
    $args = getopt('i::h:D:T:L:F:d:n:j:C:', ['help', 'ini-write', 'ini-show', 'email:', 'internal-backup-cluster:', 'internal-date:']);
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
        --email        recipiant for log

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

        TXT;
      die();
    }
  }
}

pg_clusterbackup::run();
