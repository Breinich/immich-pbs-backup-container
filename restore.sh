#!/bin/bash

set -e

# Variables from environment
PG_HOST="${DB_HOST:-database}"
PG_PORT="${DB_PORT:-5432}"
PG_USER="${DB_USERNAME:-immich}"
PG_PASSWORD="${DB_PASSWORD}"
PG_DATABASE="${DB_DATABASE_NAME:-immich}"
UPLOAD_DIR="${UPLOAD_LOCATION:-/data}"
RESTORE_DIR="/tmp/immich_restore"
BACKUP_TIMESTAMP="${1:-latest}"
DATABASE_ONLY="${DATABASE_ONLY:-true}"

echo "==============================================="
echo "Starting Immich restore at $(date)"
if [ "${DATABASE_ONLY}" = "true" ]; then
  echo "MODE: Database-only restore (files will NOT be restored)"
else
  echo "MODE: Full restore (database + files)"
fi
echo "==============================================="

export PBS_PASSWORD
export PBS_FINGERPRINT

# Get the latest snapshot if not specified
if [ "${BACKUP_TIMESTAMP}" = "latest" ]; then
  echo "Finding latest backup snapshot..."
  
  # Get the backup-time epoch from PBS
  BACKUP_TIME_EPOCH=$(proxmox-backup-client snapshot list \
    "host/${BACKUP_NAME}" \
    --repository "${PBS_REPOSITORY}" \
    --output-format json | \
    jq -r 'sort_by(.["backup-time"]) | reverse | .[0]["backup-time"]')
  
  if [ -z "${BACKUP_TIME_EPOCH}" ] || [ "${BACKUP_TIME_EPOCH}" = "null" ]; then
    echo "Error: No backups found in repository"
    exit 1
  fi
  
  # Convert epoch to ISO 8601 format that PBS uses in snapshot paths
  BACKUP_TIMESTAMP=$(date -u -d @${BACKUP_TIME_EPOCH} +"%Y-%m-%dT%H:%M:%SZ")
  
  echo "Latest backup: ${BACKUP_TIMESTAMP}"
fi

# Create restore directory
mkdir -p "${RESTORE_DIR}"

echo ""
echo "==============================================="
echo "Step 1: Restoring from Proxmox Backup Server"
echo "==============================================="
echo "Repository: ${PBS_REPOSITORY}"
echo "Snapshot: host/${BACKUP_NAME}/${BACKUP_TIMESTAMP}"

# First, list available archives in the snapshot
echo ""
echo "Listing available archives in snapshot..."
proxmox-backup-client snapshot files \
  "host/${BACKUP_NAME}/${BACKUP_TIMESTAMP}" \
  --repository "${PBS_REPOSITORY}" 2>&1 || echo "(Could not list archives)"

# Restore database dump
echo ""
echo "Restoring database dump..."
DUMP_FILE=""
DUMP_IS_GZ=false

set +e
# Try various database archive names
for db_archive in "immich-db.pxar" "database.pxar"; do
  echo "Trying ${db_archive}..."
  
  # Determine target file and extraction method based on format
  if [[ "${db_archive}" == "immich-db.pxar" ]]; then
    # pxar archive - could contain gzipped or plain SQL
    TARGET_DIR="${RESTORE_DIR}/db_archive"
    mkdir -p "${TARGET_DIR}"
 
    proxmox-backup-client restore \
      "host/${BACKUP_NAME}/${BACKUP_TIMESTAMP}" \
      "${db_archive}" \
      "${TARGET_DIR}" \
      --repository "${PBS_REPOSITORY}" 2>&1
    RESTORE_RC=$?
    if [ ${RESTORE_RC} -eq 0 ]; then
      # Find SQL file - check for gzipped first, then plain
      DUMP_FILE=$(find "${TARGET_DIR}" -name "*.sql.gz" -type f | head -n 1)
      if [ -n "${DUMP_FILE}" ]; then
        DUMP_IS_GZ=true
        echo "✓ Successfully restored gzipped dump from ${db_archive}"
        break
      fi
      DUMP_FILE=$(find "${TARGET_DIR}" -name "*.sql" -type f | head -n 1)
      if [ -n "${DUMP_FILE}" ]; then
        DUMP_IS_GZ=false
        echo "✓ Successfully restored plain SQL dump from ${db_archive}"
        break
      fi
      echo "  Warning: No SQL file found in ${db_archive}"
      DUMP_FILE=""
    fi
  elif [[ "${db_archive}" == "immich-db.img" ]]; then
    # Legacy img format: plain SQL file
    TARGET_FILE="${RESTORE_DIR}/dump.sql"
    
    proxmox-backup-client restore \
      "host/${BACKUP_NAME}/${BACKUP_TIMESTAMP}" \
      "${db_archive}" \
      "${TARGET_FILE}" \
      --repository "${PBS_REPOSITORY}" 2>&1
    RESTORE_RC=$?
    if [ ${RESTORE_RC} -eq 0 ]; then
      DUMP_FILE="${TARGET_FILE}"
      DUMP_IS_GZ=false
      echo "✓ Successfully restored from ${db_archive}"
      break
    fi
  else
    # Standard format: gzipped SQL dump
    TARGET_FILE="${RESTORE_DIR}/dump.sql.gz"
    
    proxmox-backup-client restore \
      "host/${BACKUP_NAME}/${BACKUP_TIMESTAMP}" \
      "${db_archive}" \
      "${TARGET_FILE}" \
      --repository "${PBS_REPOSITORY}" 2>&1
    RESTORE_RC=$?
    if [ ${RESTORE_RC} -eq 0 ]; then
      DUMP_FILE="${TARGET_FILE}"
      DUMP_IS_GZ=true
      echo "✓ Successfully restored from ${db_archive}"
      break
    fi
  fi
done
set -e

if [ -z "${DUMP_FILE}" ]; then
  echo "Error: Could not restore database dump from any known archive format"
  exit 1
fi

echo "✓ Database dump restored: ${DUMP_FILE}"

# Restore all upload directories
if [ "${DATABASE_ONLY}" = "true" ]; then
  echo ""
  echo "Skipping file restore (DATABASE_ONLY mode)"
else
  echo ""
  echo "Restoring Immich data files..."
  if [ "${AUTO_RESTORE}" != "true" ]; then
    echo "Warning: This will overwrite existing files in ${UPLOAD_DIR}"
    read -p "Continue? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
      echo "Restore cancelled by user"
      rm -rf "${RESTORE_DIR}"
      exit 0
    fi
  else
    echo "Auto-restore mode: Proceeding without confirmation"
  fi

  RESTORED_FILES=false
  for archive in library upload profile thumbs encoded-video; do
    echo "  Restoring ${archive}..."
    if proxmox-backup-client restore \
      "host/${BACKUP_NAME}/${BACKUP_TIMESTAMP}" \
      "${archive}.pxar" \
      "${UPLOAD_DIR}/${archive}" \
      --repository "${PBS_REPOSITORY}" 2>/dev/null; then
      RESTORED_FILES=true
    else
      echo "    (${archive} not found in backup, skipping)"
    fi
  done

  if [ "${RESTORED_FILES}" = "false" ]; then
    echo "No standard archives found, trying legacy formats..."
    set +e
    echo "  Trying immich-files.pxar..."
    proxmox-backup-client restore \
      "host/${BACKUP_NAME}/${BACKUP_TIMESTAMP}" \
      "immich-files.pxar" \
      "${UPLOAD_DIR}/library" \
      --repository "${PBS_REPOSITORY}" 2>&1
    RESTORE_RC=$?
    if [ ${RESTORE_RC} -eq 0 ]; then
      RESTORED_FILES=true
      echo "✓ Legacy files restored from immich-files.pxar to ${UPLOAD_DIR}/library"
    fi
    set -e
    if [ "${RESTORED_FILES}" = "false" ]; then
      echo "Warning: No file archives found in backup"
    fi
  fi

  echo "✓ Immich data files restored"
fi

echo ""
echo "==============================================="
echo "Step 2: Restoring database"
echo "==============================================="

# Wait for database to be ready
echo "Waiting for PostgreSQL to be ready..."
until PGPASSWORD="${PG_PASSWORD}" pg_isready -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres; do
  echo "PostgreSQL is unavailable - sleeping"
  sleep 2
done
echo "✓ PostgreSQL is ready"

echo ""
if [ "${AUTO_RESTORE}" != "true" ]; then
  echo "Warning: This will restore the database and overwrite all existing data in '${PG_DATABASE}'"
  read -p "Continue? (yes/no): " -r
  if [[ ! $REPLY =~ ^[Yy][Ee][Es]$ ]]; then
    echo "Database restore cancelled by user"
    rm -rf "${RESTORE_DIR}"
    exit 0
  fi
else
  echo "Auto-restore mode: Restoring database without confirmation"
fi

echo "Restoring database from dump..."
echo "Using Immich's recommended restore procedure..."

# Follow Immich's official restore procedure when using Immich dumps.
# For legacy plain SQL dumps, restore directly with psql.
if [ "${DUMP_IS_GZ}" = "true" ]; then
  gunzip --stdout "${DUMP_FILE}" | \
    sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" | \
    PGPASSWORD="${PG_PASSWORD}" psql \
      -h "${PG_HOST}" \
      -p "${PG_PORT}" \
      -U "${PG_USER}" \
      -d "${PG_DATABASE}" \
      --single-transaction \
      --set ON_ERROR_STOP=on
else
  PGPASSWORD="${PG_PASSWORD}" psql \
    -h "${PG_HOST}" \
    -p "${PG_PORT}" \
    -U "${PG_USER}" \
    -d "${PG_DATABASE}" \
    --single-transaction \
    --set ON_ERROR_STOP=on \
    -f "${DUMP_FILE}"
fi

echo "✓ Database restored successfully"

# Cleanup
echo ""
echo "==============================================="
echo "Step 3: Cleanup"
echo "==============================================="
rm -rf "${RESTORE_DIR}"
echo "✓ Cleanup completed"

echo ""
echo "==============================================="
echo "Immich restore finished successfully at $(date)"
echo "==============================================="
echo ""
echo "Please restart your Immich services to apply changes."
