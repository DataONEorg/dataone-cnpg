#!/bin/bash

# NOTE: Needed only one time, for installations that started doing backups before chart 1.3.0 was
# released. Since then, this annotation is added automatically by the chart
#
# Patches all existing VolumeSnapshots in the provided namespace that were created by CNPG
# "scheduled-backup", so their owner is explicitly set as the corresponding CNPG Backup object.
# Then, when the new cnpg chart cleans up and deletes stale Backup objects, the VolumeSnapshots
# and VolumeSnapshotContents will be deleted as well.
#
SNAPSHOT_FILTER="scheduled-backup"    # dataone-cnpg chart backups
#SNAPSHOT_FILTER="keycloakx-backup-"    # keycloakx-specific backups
NS=$1
CLUSTER=$2

ADMIN_CTXT="dev-k8s"

if [ -z $NS ]; then
  echo "Must provide namespace"
  exit 1
fi

if [[ "$CLUSTER" == "prod" ]]; then
  echo "Running on PROD cluster"
  ADMIN_CTXT="prod-k8s"
else
  echo "No cluster provided - defaulting to DEV"
  echo "(to use prod, specify: \"$0 <namespace> prod\")"
fi

echo "RETURN to continue, or ctrl-C to exit"
read

SNAPSHOTS=$(kubectl get volumesnapshots --context "${ADMIN_CTXT}" -n "${NS}" -o name \
  | grep "${SNAPSHOT_FILTER}" || true)

echo "SNAPSHOTS IN $NS NAMESPACE:"
printf '%s\n' "${SNAPSHOTS}"

echo "RETURN to continue, or ctrl-C to exit"
read

echo
echo "-----------------------------------"
for SNAP in  ${SNAPSHOTS}; do
  OWNER_NAME="${SNAP#*/}"
  echo "SNAP: $SNAP"
  echo "OWNER_NAME: $OWNER_NAME"
  OWNER_UID=$(kubectl get backup $OWNER_NAME --context ${ADMIN_CTXT} -n $NS -o jsonpath='{.metadata.uid}')
  echo "OWNER_UID: $OWNER_UID"
  if [ -z "$OWNER_UID" ]; then
    echo "No owner Backup object found - skipping patch"
    continue
  fi

  /Users/brooke/.rd/bin/kubectl patch $SNAP --context ${ADMIN_CTXT} -n $NS --type='merge' -p="$(cat <<EOF
    {
      "metadata": {
        "ownerReferences": [
          {
            "apiVersion": "postgresql.cnpg.io/v1",
            "controller": true,
            "kind": "Backup",
            "name": "$OWNER_NAME",
            "uid": "$OWNER_UID"
          }
        ]
      }
    }
EOF
  )"

  kc get --context ${ADMIN_CTXT} -n $NS -oyaml $SNAP | yq '.metadata.ownerReferences'
  echo "-----------------------------------"
done
