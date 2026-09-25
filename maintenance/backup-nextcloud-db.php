<?php
/** Stream the ticket 41404 database backup without exposing credentials. */
declare(strict_types=1);

if (PHP_SAPI !== 'cli' || PHP_VERSION_ID < 80200 || PHP_VERSION_ID >= 80500) {
    fwrite(STDERR, "Run with PHP CLI 8.2-8.4.\n");
    exit(1);
}

require '/home/appbox/public_html/config/config.php';
if (!isset($CONFIG) || !is_array($CONFIG)
    || ($CONFIG['dbname'] ?? '') !== 'nextcloud'
    || ($CONFIG['dbtableprefix'] ?? '') !== 'nc_'
    || ($CONFIG['dbhost'] ?? '') !== 'localhost:3306') {
    fwrite(STDERR, "Unexpected Nextcloud database configuration.\n");
    exit(1);
}

$command = [
    '/usr/bin/mysqldump',
    '--single-transaction',
    '--quick',
    '--skip-lock-tables',
    '--no-tablespaces',
    '--host=localhost',
    '--port=3306',
    '--user=' . $CONFIG['dbuser'],
    '--',
    'nextcloud',
];
$descriptors = [
    0 => ['file', '/dev/null', 'r'],
    1 => STDOUT,
    2 => STDERR,
];
$process = proc_open($command, $descriptors, $pipes, null, [
    'MYSQL_PWD' => $CONFIG['dbpassword'],
    'PATH' => '/usr/bin:/bin',
]);
if (!is_resource($process)) {
    fwrite(STDERR, "Could not start mysqldump.\n");
    exit(1);
}
exit(proc_close($process));
