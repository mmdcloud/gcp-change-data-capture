#!/usr/bin/env bash
set -euo pipefail
export MYSQL_PWD="${DB_ADMIN_PASS}"
mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_ADMIN_USER}" --ssl-mode=REQUIRED <<SQL
GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${DATASTREAM_USER}'@'%';
FLUSH PRIVILEGES;
SQL