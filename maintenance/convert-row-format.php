<?php
/**
 * Ticket 41404: convert the verified Nextcloud database to InnoDB DYNAMIC.
 * Run inside the app container: php8.2 convert-row-format.php --plan
 * Apply only with the printed table-list hash:
 * php8.2 convert-row-format.php --apply=<sha256>
 * The script reads the installed Nextcloud config without printing credentials.
 */

declare(strict_types=1);

if (PHP_SAPI !== 'cli' || PHP_VERSION_ID < 80200 || PHP_VERSION_ID >= 80500) {
    fwrite(STDERR, "Run with PHP CLI 8.2-8.4.\n");
    exit(1);
}

$argument = $argv[1] ?? '';
if ($argc !== 2 || ($argument !== '--plan' && !preg_match('/^--apply=[a-f0-9]{64}$/D', $argument))) {
    fwrite(STDERR, "Usage: php convert-row-format.php --plan|--apply=<table-list-sha256>\n");
    exit(1);
}

$configPath = '/home/appbox/public_html/config/config.php';
if (!is_file($configPath)) {
    fwrite(STDERR, "Nextcloud configuration is missing.\n");
    exit(1);
}
require $configPath;
if (!isset($CONFIG) || !is_array($CONFIG)) {
    fwrite(STDERR, "Nextcloud configuration is invalid.\n");
    exit(1);
}

if (($CONFIG['dbname'] ?? '') !== 'nextcloud'
    || ($CONFIG['dbtableprefix'] ?? '') !== 'nc_'
    || ($CONFIG['dbhost'] ?? '') !== 'localhost:3306') {
    fwrite(STDERR, "Unexpected database or table prefix.\n");
    exit(1);
}

mysqli_report(MYSQLI_REPORT_OFF);
$db = new mysqli(
    $CONFIG['dbhost'] ?? 'localhost',
    $CONFIG['dbuser'] ?? '',
    $CONFIG['dbpassword'] ?? '',
    $CONFIG['dbname']
);
if ($db->connect_errno) {
    fwrite(STDERR, "Could not connect to the Nextcloud database.\n");
    exit(1);
}

$result = $db->query(
    "SELECT TABLE_NAME, ENGINE, ROW_FORMAT, CREATE_OPTIONS,
            DATA_LENGTH + INDEX_LENGTH AS bytes
     FROM information_schema.TABLES
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
     ORDER BY TABLE_NAME"
);
if ($result === false) {
    fwrite(STDERR, "Could not inspect table formats.\n");
    exit(1);
}

$tables = $result->fetch_all(MYSQLI_ASSOC);
$compressed = [];
$dynamic = 0;
foreach ($tables as $table) {
    if (!preg_match('/^nc_[A-Za-z0-9_]+$/D', $table['TABLE_NAME']) || $table['ENGINE'] !== 'InnoDB') {
        fwrite(STDERR, "Unexpected table name or engine.\n");
        exit(1);
    }
    if (strcasecmp($table['ROW_FORMAT'], 'Compressed') === 0) {
        if ($table['CREATE_OPTIONS'] !== 'row_format=COMPRESSED') {
            fwrite(STDERR, "Unexpected compressed table options.\n");
            exit(1);
        }
        $compressed[] = $table;
    } elseif (strcasecmp($table['ROW_FORMAT'], 'Dynamic') === 0) {
        $dynamic++;
    } else {
        fwrite(STDERR, "Unexpected row format.\n");
        exit(1);
    }
}

if (count($tables) !== 130 || count($compressed) + $dynamic !== 130) {
    fwrite(STDERR, "Table count changed from the reviewed 130-table snapshot.\n");
    exit(1);
}

$names = array_column($compressed, 'TABLE_NAME');
$hash = hash('sha256', implode("\n", $names));
printf("schema=nextcloud tables=%d compressed=%d dynamic=%d table_list_sha256=%s\n",
    count($tables), count($compressed), $dynamic, $hash);

if ($argument === '--plan') {
    foreach ($compressed as $table) {
        printf("%s\t%d bytes\n", $table['TABLE_NAME'], $table['bytes']);
    }
    exit(0);
}

if (substr($argument, 8) !== $hash) {
    fwrite(STDERR, "Table list does not match the reviewed plan.\n");
    exit(1);
}
if (!$db->query('SET SESSION lock_wait_timeout = 5')) {
    fwrite(STDERR, "Could not set a bounded metadata lock wait.\n");
    exit(1);
}

// Convert smaller tables first. A failed online ALTER stops the run; a new
// plan is required before resuming. LOCK=NONE permits concurrent DML.
usort($compressed, static fn ($a, $b) => ((int) $a['bytes'] <=> (int) $b['bytes']) ?: strcmp($a['TABLE_NAME'], $b['TABLE_NAME']));
foreach ($compressed as $index => $table) {
    $name = $table['TABLE_NAME'];
    printf("Converting %d/%d %s\n", $index + 1, count($compressed), $name);
    $sql = sprintf('ALTER TABLE `%s` ROW_FORMAT=DYNAMIC, ALGORITHM=INPLACE, LOCK=NONE', $name);
    if (!$db->query($sql)) {
        fwrite(STDERR, "Online ALTER failed for {$name}: {$db->error}\n");
        exit(1);
    }
}

$remaining = $db->query(
    "SELECT COUNT(*) AS count FROM information_schema.TABLES
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
       AND ROW_FORMAT <> 'Dynamic'"
);
if ($remaining === false || (int) $remaining->fetch_assoc()['count'] !== 0) {
    fwrite(STDERR, "Row-format verification failed.\n");
    exit(1);
}
echo "All 130 Nextcloud tables use ROW_FORMAT=DYNAMIC.\n";
