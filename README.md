# Immich Backup Container

Automated backup solution for Immich that backs up to Proxmox Backup Server (PBS).

> [!NOTE]
> this is a Copilot assisted project. The code and documentation were generated with the help of AI based on the requirements and feedback provided by the user. Please review the code and documentation carefully before using or deploying.

## Features

- **Automated Backups**: Runs on a configurable cron schedule (default: daily at 2 AM)
- **Complete Backup**: Backs up database and all Immich data directories
- **PBS Integration**: Uses Proxmox Backup Server for reliable, deduplicated storage
- **Auto-Restore on Empty DB**: Automatically restores from latest backup if database is empty
- **Easy Restore**: Includes restore script following Immich's official procedures

## Setup

### 1. Environment Variables

Add these variables to your `stack.env` file or docker-compose environment:

```bash
# Proxmox Backup Server Configuration
PBS_REPOSITORY=username@pbs@host:datastore
PBS_PASSWORD=your-pbs-password
PBS_FINGERPRINT=your-pbs-fingerprint

# Optional: Customize backup schedule (cron format)
BACKUP_SCHEDULE=0 2 * * *

# Optional: Custom backup name
BACKUP_NAME=immich-backup
```

### 2. Start the Backup Container

The backup service is included in the main `docker-compose.yml`:

```bash
docker compose up -d immich-backup
```

## Backup Process

The backup automatically:
1. Creates a PostgreSQL database dump (`.sql.gz` format following Immich's standard)
2. Backs up all Immich data directories that exist:
   - `library/` - External library assets (if storage template enabled)
   - `upload/` - Original uploaded assets
   - `profile/` - User avatars
   - `thumbs/` - Thumbnails and previews
   - `encoded-video/` - Re-encoded videos
3. Uploads everything to PBS in a single snapshot
4. Cleans up temporary files

## Restore

### From Latest Backup (Full Restore)

Restores both database and all files:

```bash
docker run --rm -it \
  --env-file stack.env \
  --network immich_default \
  -v /path/to/immich/library:/data \
  immich-backup restore
```

### Database Only (For Testing or Space-Constrained Restores)

To restore only the database and skip files:

```bash
docker run --rm -it \
  --env-file stack.env \
  --network immich_default \
  -e DATABASE_ONLY=true \
  -v /path/to/immich/library:/data \
  immich-backup restore
```

### From Specific Timestamp

```bash
docker run --rm -it \
  --env-file stack.env \
  --network immich_default \
  -v /path/to/immich/library:/data \
  immich-backup restore 2026-02-28T03:00:33Z
```

> **Note:** Use the ISO 8601 timestamp format shown in PBS snapshot list. List available backups:
> ```bash
> proxmox-backup-client snapshot list "host/${BACKUP_NAME}" --repository "${PBS_REPOSITORY}"
> ```

The restore process:
1. Lists available backups and selects the latest (or specified timestamp)
2. Restores all files from PBS to your upload location
3. Prompts for confirmation before overwriting files
4. Restores the database using Immich's official procedure
5. Prompts for confirmation before overwriting the database

**Important**: After restore, restart all Immich services:
```bash
docker compose restart
```

## How It Works

- **Backup mode** (default): 
  1. On startup, checks if the Immich database is empty
  2. If empty and PBS backups exist, automatically restores the latest backup
  3. Then runs cron daemon with scheduled backups
- **Restore mode**: Execute with `restore` argument for manual restoration
- **Read-only mount**: Upload location is mounted read-only for backup to prevent accidental modifications

### Auto-Restore Feature

When the backup container starts, it automatically:
1. Waits for PostgreSQL to be ready
2. Checks if the Immich database needs restoration by verifying:
   - Table count (needs at least 5 tables)
   - User count (needs at least 1 user with data, or 2+ users)
   - Asset count (checks if database has any photos/videos)
3. If database appears empty or incomplete:
   - Checks PBS for existing backups
   - If found, automatically restores the latest backup (no prompts)
   - Then continues with normal backup schedule
4. If database is properly populated, proceeds directly to backup schedule

**Restore triggers:**
- Database has fewer than 5 tables
- Database has no users
- Database has only 1 user and no assets (fresh installation detected)

This is perfect for:
- **Disaster recovery**: Quickly restore after complete data loss
- **New installations**: Migrate an existing Immich instance by restoring from PBS
- **Testing environments**: Spin up fresh instances with production data

**Note**: Auto-restore is smart - it won't trigger on a properly initialized Immich instance with actual data.

## Monitoring

Check backup logs:
```bash
docker logs -f immich_backup
```

View backups in PBS:
```bash
proxmox-backup-client snapshot list \
  --repository "${PBS_REPOSITORY}"
```

## Troubleshooting

### Missing directories warning
If you see "Skipping library/ (not found)", this is normal. The `library` directory only exists if you've enabled Immich's storage template feature.

### Database connection issues
Ensure the backup container is on the same network as your Immich database and that `DB_HOST=database` matches your database service name.

### PBS authentication
Verify your PBS credentials:
```bash
docker exec -it immich_backup proxmox-backup-client snapshot list \
  --repository "${PBS_REPOSITORY}"
```
