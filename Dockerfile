FROM debian:trixie-slim

# Install dependencies
RUN apt-get update && apt-get install -y \
    postgresql-client \
    curl \
    wget \
    nano \
    jq \
    cron \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Proxmox Backup Client
RUN wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -O /usr/share/keyrings/proxmox-archive-keyring.gpg && \
    echo "Types: deb\nURIs: http://download.proxmox.com/debian/pbs-client\nSuites: trixie\nComponents: main\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg" > /etc/apt/sources.list.d/pbs-client.sources && \
    apt-get update && apt-get install -y proxmox-backup-client proxmox-archive-keyring && \
    rm -rf /var/lib/apt/lists/*

# Create backup and restore scripts
RUN mkdir -p /backup/scripts
COPY backup.sh /backup/scripts/backup.sh
COPY restore.sh /backup/scripts/restore.sh
COPY check_and_restore.sh /backup/scripts/check_and_restore.sh
RUN chmod +x /backup/scripts/backup.sh /backup/scripts/restore.sh /backup/scripts/check_and_restore.sh

# Environment variables
ENV BACKUP_SCHEDULE="0 2 * * *"
ENV PBS_REPOSITORY=""
ENV PBS_PASSWORD=""
ENV PBS_FINGERPRINT=""
ENV DB_HOST="database"
ENV DB_PORT="5432"
ENV DB_USERNAME="immich"
ENV DB_PASSWORD=""
ENV DB_DATABASE_NAME="immich"
ENV UPLOAD_LOCATION="/data"
ENV BACKUP_NAME="immich-backup"

# Setup entrypoint with optional restore command
RUN echo "#!/bin/bash" > /entrypoint.sh && \
    echo "if [ \"\$1\" = \"restore\" ]; then" >> /entrypoint.sh && \
    echo "  shift" >> /entrypoint.sh && \
    echo "  exec /backup/scripts/restore.sh \"\$@\"" >> /entrypoint.sh && \
    echo "else" >> /entrypoint.sh && \
    echo "  # Check if database is empty and auto-restore if needed" >> /entrypoint.sh && \
    echo "  /backup/scripts/check_and_restore.sh" >> /entrypoint.sh && \
    echo "  # Start normal backup schedule" >> /entrypoint.sh && \
    echo "  # Configure cron to send output to stdout/stderr (visible in docker logs)" >> /entrypoint.sh && \
    echo "  echo \"$BACKUP_SCHEDULE /backup/scripts/backup.sh >> /proc/1/fd/1 2>&1\" | crontab -" >> /entrypoint.sh && \
    echo "  cron -f" >> /entrypoint.sh && \
    echo "fi" >> /entrypoint.sh && \
    chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]