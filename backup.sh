#!/bin/bash

set -e

# Variables from environment
PG_HOST="${DB_HOST:-database}"
PG_PORT="${DB_PORT:-5432}"
PG_USER="${DB_USERNAME:-immich}"
PG_PASSWORD="${DB_PASSWORD}"
PG_DATABASE="${DB_DATABASE_NAME:-immich}"
UPLOAD_DIR="${UPLOAD_LOCATION:-/data}"
BACKUP_DIR="/tmp/immich"
DB_DUMP_FILE="${BACKUP_DIR}/database.sql.gz"
BACKUP_NAME="${BACKUP_NAME:-immich-backup}"
PBS_NAMESPACE="${PBS_NAMESPACE:-}"

PBS_NAMESPACE_ARGS=()
if [ -n "${PBS_NAMESPACE}" ]; then
  PBS_NAMESPACE_ARGS+=(--ns "${PBS_NAMESPACE}")
fi

# Validate required configuration before doing any work
if [ -z "${PBS_REPOSITORY}" ]; then
  echo "ERROR: PBS_REPOSITORY is empty"
  echo "Set PBS_REPOSITORY in stack.env (example: user@pbs@host:datastore)"
  exit 1
fi

if [ -z "${PBS_PASSWORD}" ]; then
  echo "ERROR: PBS_PASSWORD is empty"
  echo "Set PBS_PASSWORD in stack.env"
  exit 1
fi

if ! echo "${BACKUP_NAME}" | grep -Eq '^[A-Za-z0-9_-]+$'; then
  echo "ERROR: BACKUP_NAME '${BACKUP_NAME}' is invalid"
  echo "BACKUP_NAME must contain only letters, numbers, hyphen, underscore"
  exit 1
fi

echo "==============================================="
echo "Starting Immich backup at $(date)"
echo "==============================================="

# 1. Create a database dump (following Immich best practices)
echo "Creating PostgreSQL database dump..."
mkdir -p "${BACKUP_DIR}"

PGPASSWORD="${PG_PASSWORD}" pg_dump \
  --clean \
  --if-exists \
  -h "${PG_HOST}" \
  -p "${PG_PORT}" \
  -U "${PG_USER}" \
  -d "${PG_DATABASE}" \
  | gzip > "${DB_DUMP_FILE}"

echo "✓ Database dump created: ${DB_DUMP_FILE}"
echo "  Size: $(du -h ${DB_DUMP_FILE} | cut -f1)"

# 2. Backup everything to PBS
echo ""
echo "Backing up to Proxmox Backup Server..."
echo "Repository: ${PBS_REPOSITORY}"
if [ -n "${PBS_NAMESPACE}" ]; then
  echo "Namespace: ${PBS_NAMESPACE}"
fi
echo "Backup ID: ${BACKUP_NAME}"

export PBS_PASSWORD
export PBS_FINGERPRINT

# Backup database directory and files directory
proxmox-backup-client backup \
  immich-db.pxar:"${BACKUP_DIR}" \
  immich-files.pxar:"${UPLOAD_DIR}/library" \
  --repository "${PBS_REPOSITORY}" \
  "${PBS_NAMESPACE_ARGS[@]}" \
  --backup-type host \
  --backup-id "${BACKUP_NAME}"

echo "✓ Backup completed successfully"

# 3. Cleanup
echo ""
echo "Cleaning up temporary files..."
rm -rf "${BACKUP_DIR}"
echo "✓ Cleanup completed"

echo ""
echo "==============================================="
echo "Immich backup finished at $(date)"
echo "==============================================="
