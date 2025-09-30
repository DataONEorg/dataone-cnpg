#!/usr/bin/env bash

# Prepare a source PostrgeSQL instance (e.g. Bitnami) for migration to CNPG

set -euo pipefail

# Function to print usage
usage() {
    echo "Prepare a source PostgreSQL instance for migration to CNPG. Note this script assumes the "
    echo "postgres user has access to psql from a shell inside the pod (see pg_hba.conf)"
    echo
    echo "Usage: $0 -p <pod_name> [ -u <postgres_user> ]"
    echo
    echo "  -p <pod_name>         (required) name of postgres pod"
    echo "  -u <postgres_user>    (required) name of postgres user that cnpg will use to connect"
    exit 1
}

# Parse command-line arguments
while getopts "p:u:" opt; do
    case ${opt} in
    p) POD_NAME=$OPTARG ;;
    u) PG_USER=$OPTARG ;;
    *) usage ;;
    esac
done

# Check for required arguments
if [ -z "${POD_NAME:-}" ] || [ -z "${PG_USER:-}" ]; then
    usage
fi

echo "Add the following to pg_hba.conf in pod $POD_NAME if not already present:"
echo "    host  replication  ${PG_USER}  0.0.0.0/0  md5"
read -p "[Enter] to continue or Ctrl-C to exit..."
echo
kubectl exec -i "$POD_NAME" -- env PG_USER="$PG_USER" bash <<'EOF'
  REPLICA_HBA_ENTRY="host  replication  ${PG_USER}  0.0.0.0/0  md5"
  PG_HBA='/opt/bitnami/postgresql/conf/pg_hba.conf'
  grep -qxF "$REPLICA_HBA_ENTRY" $PG_HBA || echo "$REPLICA_HBA_ENTRY" >> $PG_HBA
EOF
if [ $? -eq 0 ]; then
    echo "✅ Updated pg_hba.conf in pod $POD_NAME"
else
    echo "❌ Failed to update pg_hba.conf in pod $POD_NAME"
fi

echo
echo "Grant REPLICATION privilege to user ${PG_USER}"
read -p "[Enter] to continue or Ctrl-C to exit..."
echo
kubectl exec -i "$POD_NAME" -- psql -U postgres -v ON_ERROR_STOP=1 \
    -c "ALTER USER ${PG_USER} WITH REPLICATION;"
if [ $? -eq 0 ]; then
    echo "✅ Ensured replication user exists with REPLICATION privilege in pod $POD_NAME"
else
    echo "❌ Failed to create or alter replication user in pod $POD_NAME"
fi

echo
echo "Creating a new physical replication slot named cnpg_slot"
read -p "[Enter] to continue or Ctrl-C to exit..."
echo
kubectl exec -i "$POD_NAME" -- psql -U postgres -v ON_ERROR_STOP=1 <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_replication_slots WHERE slot_name = 'cnpg_slot'
    ) THEN
        PERFORM pg_create_physical_replication_slot('cnpg_slot');
    END IF;
END
\$\$;
EOF
if [ $? -eq 0 ]; then
    echo "✅ Physical replication slot 'cnpg_slot' created in pod $POD_NAME"
else
    echo "❌ Failed to create physical replication slot 'cnpg_slot' in pod $POD_NAME (it may already exist)"
fi
echo
echo "set wal_keep_size to 1024MB (1GB)"
read -p "[Enter] to continue or Ctrl-C to exit..."
echo
kubectl exec -i "$POD_NAME" -- psql -U postgres -v ON_ERROR_STOP=1 <<EOF
  ALTER SYSTEM SET wal_keep_size = '1024MB';
  SELECT pg_reload_conf();
EOF
if [ $? -eq 0 ]; then
    echo "✅ wal_keep_size successfully set to 1024MB in pod $POD_NAME"
else
    echo "❌ Failed to set wal_keep_size in pod $POD_NAME"
fi

echo
echo "Check current settings for wal_keep_size and max_wal_senders:"
read -p "[Enter] to continue..."
echo
kubectl exec -i "$POD_NAME" -- psql -U postgres <<EOF
  show wal_keep_size;
  show max_wal_senders;
EOF
echo
echo "⚠️ IMPORTANT: Ensure CNPG has EXACTLY the same number of max_wal_senders!"
echo
