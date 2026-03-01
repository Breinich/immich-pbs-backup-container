#!/bin/bash

# This script checks if the Immich database needs restoration
# 
# Restore triggers:
# - Database has fewer than 5 tables (empty or incomplete schema)
# - Database has no users (empty database)
# - Database has only 1 user and no assets (fresh installation)
#
# If triggered and PBS backups exist, automatically restores the latest backup

set -e

echo "==============================================="
echo "Checking Immich database state..."
echo "==============================================="

# Wait for database to be ready
echo "Waiting for PostgreSQL to be ready..."
sleep 5
until PGPASSWORD="${DB_PASSWORD}" pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER:-${DB_USERNAME}}" -d postgres > /dev/null 2>&1; do
  echo "PostgreSQL is unavailable - waiting..."
  sleep 2
done
echo "✓ PostgreSQL is ready"

# Check if database exists
DB_EXISTS=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USERNAME}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_DATABASE_NAME}'")

if [ -z "$DB_EXISTS" ]; then
  echo "Database '${DB_DATABASE_NAME}' doesn't exist yet - waiting for Immich to create it..."
  sleep 10
fi

# Check if database has any tables (specifically looking for Immich tables)
TABLE_COUNT=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USERNAME}" -d "${DB_DATABASE_NAME}" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" 2>/dev/null || echo "0")

echo "Database '${DB_DATABASE_NAME}' has ${TABLE_COUNT} tables"

# Additional checks for data population
SHOULD_RESTORE=false
RESTORE_REASON=""

if [ "$TABLE_COUNT" -eq "0" ] || [ "$TABLE_COUNT" -lt "5" ]; then
  SHOULD_RESTORE=true
  RESTORE_REASON="Database has insufficient tables (${TABLE_COUNT} found, need at least 5)"
else
  # Database has tables, but check if they contain data
  
  # Check users table
  USER_COUNT=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USERNAME}" -d "${DB_DATABASE_NAME}" -tAc "SELECT COUNT(*) FROM users" 2>/dev/null || echo "0")
  echo "Found ${USER_COUNT} user(s) in database"
  
  # Check assets table
  ASSET_COUNT=$(PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USERNAME}" -d "${DB_DATABASE_NAME}" -tAc "SELECT COUNT(*) FROM assets" 2>/dev/null || echo "0")
  echo "Found ${ASSET_COUNT} asset(s) in database"
  
  if [ "$USER_COUNT" -eq "0" ]; then
    SHOULD_RESTORE=true
    RESTORE_REASON="No users found in database"
  elif [ "$USER_COUNT" -lt "2" ] && [ "$ASSET_COUNT" -eq "0" ]; then
    SHOULD_RESTORE=true
    RESTORE_REASON="Only ${USER_COUNT} user(s) and no assets (likely fresh installation)"
  fi
fi

if [ "$SHOULD_RESTORE" = "true" ]; then
  echo ""
  echo "⚠ ${RESTORE_REASON}"
  echo ""
  
  # Check if PBS is configured
  if [ -z "${PBS_REPOSITORY}" ]; then
    echo "PBS_REPOSITORY not configured - skipping auto-restore"
    echo "Starting normal backup schedule..."
    exit 0
  fi
  
  # Check if backups exist in PBS
  echo "Checking for existing backups in PBS..."
  echo "Repository: ${PBS_REPOSITORY}"
  echo "Backup ID: ${BACKUP_NAME}"
  echo "DEBUG: Starting credential checks..."
  
  # Safely check password length
  if [ -z "${PBS_PASSWORD}" ]; then
    echo "ERROR: PBS_PASSWORD is empty"
    echo "Skipping auto-restore"
    exit 0
  else
    echo "DEBUG: PBS_PASSWORD is set (length: ${#PBS_PASSWORD})"
  fi
  
  # Safely check fingerprint
  if [ -z "${PBS_FINGERPRINT}" ]; then
    echo "WARNING: PBS_FINGERPRINT is empty"
  else
    echo "DEBUG: PBS_FINGERPRINT is set (length: ${#PBS_FINGERPRINT})"
  fi
  
  echo "DEBUG: Exporting credentials..."
  export PBS_PASSWORD
  export PBS_FINGERPRINT

  echo "DEBUG: About to run proxmox-backup-client..."
  echo "DEBUG: Full command: proxmox-backup-client snapshot list 'host/${BACKUP_NAME}' --repository '${PBS_REPOSITORY}' --output-format json"
  
  set +e
  SNAPSHOT_JSON=$(timeout 30 proxmox-backup-client snapshot list \
    "host/${BACKUP_NAME}" \
    --repository "${PBS_REPOSITORY}" \
    --output-format json 2>&1)
  SNAPSHOT_RC=$?
  set -e

  echo "DEBUG: Command completed with exit code: ${SNAPSHOT_RC}"
  echo "DEBUG: Output length: ${#SNAPSHOT_JSON} characters"
  echo "DEBUG: First 500 chars of output: ${SNAPSHOT_JSON:0:500}"
  
  BACKUP_EXISTS=$(echo "${SNAPSHOT_JSON}" | jq -r 'length' 2>/dev/null || echo "0")
  # Ensure it's a valid number, default to 0 if empty or invalid
  if [ -z "${BACKUP_EXISTS}" ] || ! [[ "${BACKUP_EXISTS}" =~ ^[0-9]+$ ]]; then
    echo "DEBUG: jq parse failed or returned invalid value, setting count to 0"
    BACKUP_EXISTS=0
  fi
  
  if [ "${BACKUP_EXISTS}" -gt "0" ]; then
    echo "✓ Found ${BACKUP_EXISTS} backup(s) in PBS"
    echo ""
    echo "========================================="
    echo "AUTO-RESTORING FROM LATEST BACKUP"
    echo "========================================="
    echo ""
    
    # Set non-interactive mode for restore script
    export AUTO_RESTORE=true
    
    # Run restore script
    /backup/scripts/restore.sh
    
    echo ""
    echo "✓ Auto-restore completed successfully"
    echo "  Starting normal backup schedule..."
    echo ""
  else
    echo "No backups found in PBS repository"
    echo "Starting normal backup schedule..."
  fi
else
  echo "✓ Database is populated"
  echo "  Tables: ${TABLE_COUNT}, Users: ${USER_COUNT:-N/A}, Assets: ${ASSET_COUNT:-N/A}"
  echo "  Starting normal backup schedule..."
fi

# Signal that the initial check and restore (if needed) has completed
touch /tmp/immich_backup_ready
echo ""
echo "✓ Check and restore phase completed. Immich server can now start."
