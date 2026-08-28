#!/usr/bin/php
<?php
/**
 * pg_clusterbackup 1.4.0
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
  public const VERSION = '1.4.0';

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
  public function log(string $txt, $debug_level=0) {
    if($this->debug_level >= $debug_level or $this->debug) {
      $txt = sprintf('%s %s', date('Y-m-d H:i:s'), $txt);
      $this->log[] = $txt;
      file_put_contents($this->logfile, $txt.PHP_EOL , FILE_APPEND | LOCK_EX);
    }
  }
  /**
   * Deletes overaged backup dirs
   */
  public function delete() {
    $backups = glob($this->settings['backupdir'].'/[0-9]*',GLOB_ONLYDIR);
    rsort($backups);
    $delete = array_slice($backups, $this->settings['maxkeep']);
    foreach($delete as $d) {
      $this->log("removing {$d}", self::DEBUG_TERSE);
      $this->exec('rm -rf '.escapeshellarg($d));
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
  public function exec(string $cmd) {
    $out = $ret = null;
    exec($cmd, $out, $ret);
    $this->log($cmd, $ret ? 0 : self::DEBUG_VERBOSE);
    $this->log(implode(PHP_EOL, $out), $ret ? self::DEBUG_LOG : self::DEBUG_VERBOSE);
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
    $path = "{$this->settings['backupdir']}/{$date}/{$cluster['version']}/{$cluster['cluster']}";
    $this->log("Starting backup Cluster: {$cluster['cluster']}");
    $this->checkdir($path);
    $socketdir = escapeshellarg($cluster['socketdir']);
    $port      = escapeshellarg($cluster['port']);
    $sql="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'";
    $databases = $this->exec("sudo -u postgres psql -h {$socketdir} -p {$port} -U postgres --tuples-only -P format=unaligned -c ".escapeshellarg($sql));
    foreach($databases as $db) {
      $this->log("Starting backup Database: {$db} ");
      $db_esc   = escapeshellarg($db);
      $tempfile = "{$this->settings['tempdir']}/{$db}.cus";
      $this->exec("sudo -u postgres pg_dump -c -h {$socketdir} -p {$port} -F{$this->settings['format']} -f ".escapeshellarg($tempfile)." {$db_esc}");
      $this->move_file($tempfile, "{$path}/{$db}.cus");
    }
    if(count($databases)==0) $this->log('No databases for backup!');
    $this->log('Starting backup globals', self::DEBUG_LOG);
    $globalsfile = "{$this->settings['tempdir']}/globals.sql";
    $this->exec("sudo -u postgres pg_dumpall -g -h {$socketdir} -p {$port} -f ".escapeshellarg($globalsfile));
    $this->move_file($globalsfile, "{$path}/globals.sql");
  }
  public function backupall() {
    $this->lock();
    $date = date('Ymd');
    $this->checkdir("{$this->settings['backupdir']}/{$date}");
    chdir($this->settings['tempdir']);
    foreach($this->clusters() as $c) {
      if($c['running']==1) {
        $this->backup($c, $date);
      }
      else {
        $this->log("Cluster: {$c['cluster']} not running!", self::DEBUG_LOG);
      }
    }
    $this->delete();
    $this->unlock();
    $this->mail();
  }
  static public function run() {
    $conf = static::args();
    if(isset($conf['ini-show'])) {
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
    $args = getopt('i::h:D:T:L:F:d:n:', ['help', 'ini-write', 'ini-show', 'email:']);
    return $args;
  }
  public function help($is_help) {
    if($is_help) {
      $version = self::VERSION;
      echo <<<TXT
        pg_clusterbackup {$version}
        ----------------------------------------------------------------------------------------------
        Backup all PostgreSQL Databases from all running Clusters.

        Author: Frank Glück (https://www.dozent.net)
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

        TXT;
      die();
    }
  }
}

pg_clusterbackup::run();
