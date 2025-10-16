## DataONE CloudNative PG -- PostgreSQL Cluster Deployment

- **Authors**: Brooke, Matthew (https://orcid.org/0000-0002-1472-913X)
- **License**: [Apache 2](http://opensource.org/licenses/Apache-2.0)
- [Package source code on GitHub](https://github.com/DataONEorg/dataone-cnpg)
- [**Submit Bugs and feature requests**](https://github.com/DataONEorg/reponame/issues)
- Contact us: support@dataone.org
- [DataONE discussions](https://github.com/DataONEorg/dataone/discussions)

DataONE is an open source, community project. We [welcome contributions](./CONTRIBUTING.md) in many forms, including code, graphics, documentation, bug reports, testing, etc. Use the [DataONE discussions](https://github.com/DataONEorg/dataone/discussions) to discuss these contributions with us.

This Helm chart provides a simplified way of deploying a CloudNative PG (CNPG) PostgreSQL cluster. It can either deploy a working cluster with the default settings for test purposes (see [values.yaml](values.yaml)), or can make use of existing values overrides from your application chart, thus eliminating the need to maintain duplicate configurations.

> [!CAUTION]
> 1. DO NOT `helm uninstall` or `helm delete` this chart, unless you **_really_** need to! Doing so will result in the following:
>   * **the dynamically provisioned PVCs will be deleted!** (You won't lose the PVs or the data, but re-binding new PVCs to the existing data is non-trivial.)
>   * (if you chose not to provide your own secret) **the secret containing the auto-generated password will be deleted**. Make sure you save the password somewhere safe before you uninstall/delete the chart:
>     ```shell
>     release=<your_release_name>
>     kubectl get secret -o yaml ${release}-cnpg-app > ${release}-cnpg-app-secrets.yaml
>     ```
> 2. Changes to the database name, database owner/username, and/or the password, are non-trivial after the cluster has been created. Doing a `helm upgrade`, will NOT update the PostgreSQL database with new values for these parameters. You will need to manually update the database and/or user credentials in postgres.


## Prerequisites

- Helm 3.x
- Kubernetes 1.26+
- CloudNative PG Operator 1.27.0+ should be installed in the cluster.

## Quick Start

To deploy an empty PostgreSQL cluster with the default settings (see [values.yaml](values.yaml)), and a secure password:

```shell
helm install <releasename> oci://ghcr.io/dataoneorg/charts/cnpg --version <version>
```

To deploy with existing values overrides from your file, add `-f /path/to/your/values-overrides.yaml`

Examples of values overrides can be found in the [examples directory](./examples).

## Secrets & Credentials

Leaving the value `existingSecret` blank will automatically create a K8s Secret containing the username defined in `dbUser`, along with a secure, generated password. You can then point your application to that Secret to retrieve the credentials. The name of the Secret will be `<releasename>-cnpg-app`.

Alternatively, you can set `existingSecret` to the name of a Secret that you created yourself. In that case, please note the following important requirements:
- the secret must be of type [`kubernetes.io/basic-auth`](https://kubernetes.io/docs/concepts/configuration/secret/#basic-authentication-secret) 
- It must contain the exact key names: `username` and `password`
- the username must match the value of `dbUser`

> [!CAUTION]
> Make sure you have provided the correct credentials in the secret, along with `dbUser` and `dbName`, BEFORE you create the cluster. Changing these values, and doing a `helm upgrade` after the cluster has been created, will NOT update those values in the existing Postgres database!

## Importing Data

Data can be imported from other PostgreSQL databases. The scenarios supported by this chart are:

### 1. Automated `pg_dump` and `pg_restore` import (works with mis-matched major versions) 

> Summary:
> - imports a database from an existing PostgreSQL cluster, even if located outside Kubernetes
> - PostgreSQL major version for the source cluster must be LESS THAN OR EQUAL TO that of the destination cluster
> - Some downtime (or read-only time) required
> - See the [DataONE Kubernetes Cluster documentation](https://github.com/DataONEorg/k8s-cluster/blob/main/postgres/postgres.md#migrating-from-an-existing-database) for more details.

### 2. Streaming Replication (same major versions)

> Summary:
> - Replication from an existing, binary-compatible PostgreSQL instance in the same cluster
> - PostgreSQL major versions must be EQUAL for the source cluster and the destination cluster
> - Minimizes downtime/read-only time

This approach uses `pg_basebackup` to create a PostgreSQL cluster by cloning an existing (and binary-compatible) one of the same major version, through the streaming replication protocol. See the [CloudNative PG documentation](https://cloudnative-pg.io/documentation/current/bootstrap/#bootstrap-from-a-live-cluster-pg_basebackup), and particularly **note the warnings and the Requirements section!**

Steps:
1. **Prepare the Source (Bitnami PostrgeSQL)** - Run [`scripts/migration-source-prep.sh`](scripts/migration-source-prep.sh) against the running Bitnami PostgreSQL pod. The script modifies `pg_hba.conf` to allow replication connections; creates a replication user and a physical replication slot; and sets `wal_keep_size` to 1024MB
   - Note: If you do not use the script file directly from cloning this repo, it may not have executable permissions. This happens when you download the script file through GitHub into your local Downloads folder.

   ```
   # Run this through your command line
   $ '/Location/of/dataone-cnpg/migration-source-prep.sh' -p [POD_NAME] -u [USER_NAME] 
   ```

2. Create a Secret, holding the database username & password. IMPORTANT: the secret must be of type 'kubernetes.io/basic-auth', and must contain the exact key names: `username` and `password`.
3. **Prepare the target (CNPG)** - BEFORE INSTALLING CNPG, ensure the following are set correctly in your values overrides (see metacat examples in [examples/values-overrides-metacat-dev.yaml](./examples/values-overrides-metacat-dev.yaml)):
   - `init.method: pg_basebackup`, `init.pg_basebackup`, `init.externalClusters`, and `replica` 
   - Ensure `postgresql.parameters.max_wal_senders` matches `max_wal_senders` on the source (see script output from step 1, above)
4. `helm install` the cnpg chart. E.g:
   ```shell
   $ helm install <releasename> oci://ghcr.io/dataoneorg/charts/cnpg --version <version> \
                              -f ./examples/values-overrides-metacat-dev.yaml
   ```
   This creates a `<rlsname>-cnpg-1-pgbasebackup-<id>` pod to make a copy of the bitnami source, and will then start the first pod of the cluster (`<rlsname>-cnpg-1`)
5. However, the first CNPG pod will now be in `CrashLoopBackOff` status. To resolve this, we need to edit the `postgresql.conf` file, as follows:
   - Type this command below in the terminal, but do not hit `<Enter>` yet...
      ```shell
      while ! kubectl exec <pod> -- sh -c "grep -q custom.conf /var/lib/postgresql/data/pgdata/postgresql.conf \
          || echo \"include 'custom.conf'\" >> /var/lib/postgresql/data/pgdata/postgresql.conf"; do
        sleep 0.2
      done
      ```
   - Delete the cnpg pod so it restarts, and watch carefully. During restart, it goes through `Init`, `PodInitializing`, and then enters `Running` status briefly, before it crashes.
   - Hit `<Enter>` to execute the command in that small window of time when the pod is in `Running` status. This pod should then start up successfully (if not, repeat these steps)

> [!NOTE]
> The remaining pods will NOT start up yet; there will be only one instance in the CNPG cluster at this point. The pod that's trying to start the second instance will show this error in the logs: `FATAL: role "streaming_replica" does not exist (SQLSTATE 28000)`. This is expected, since CNPG won't create the `"streaming_replica"` user until it exits continuous recovery mode and becomes a primary cluster, completely detached from the original source (see step 7).

6. Replication should now be working from your source postgres pod to the primary cnpg cluster instance. You can check the replication status by comparing the WAL LSN positions on source and target: 
   - Source:
     ```shell
     watch 'kubectl exec -i <source-postgres-pod> --  psql -U postgres -c "SELECT pg_current_wal_lsn();"'
     ```
   - Target:
     ```shell
     watch kubectl cnpg status
     ```
> [!IMPORTANT]
> Your application will be in read-only mode during the following steps. To minimize downtime, make sure you have everything prepared, including the values overrides for the new chart that works with CNPG instead of Bitnami!

7. When replication has caught up, unlink source & target, and switch over to the CNPG cluster, as follows:
   - put your application in Read Only mode to stop writes to Bitnami PostgreSQL
      - ⚠️ IMPORTANT! Wait until replication has caught up before proceeding! (see step 6, above)
   - `helm upgrade` the CNPG chart with the command line parameter `--set replica.enabled=false`, so it stops replicating
   - Restart the primary CNPG instance, **using the Kubectl CNPG plugin**, so the remaining CNPG replicas can be created and start replicating. do not simply delete the pod - it will not be recreated!:
     ```shell
     kubectl cnpg restart mcdbgoa-cnpg 1
     ``` 
   - Using `kubectl cnpg status`, determine which is the PRIMARY CNPG pod, wait until the two replica pods have caught up.
   - Fix any collation version mismatch in your application's database, by using:
      ```shell
      kubectl exec -i <cnpg-primary-pod> -- psql -U <your_db_user> <<EOF
        REINDEX DATABASE <your_db_name>;
        ALTER DATABASE <your_db_name> REFRESH COLLATION VERSION;
      EOF
      ```
   - `helm upgrade` your application to the new chart that works with CNPG instead of Bitnami (in Read-Write mode)

## Development

The intent of this helm chart is to provide as lightweight a wrapper as possible, keeping configuration to a minimum. There are many parameters that can be set ([see the CNPG API documentation](https://cloudnative-pg.io/documentation/current/cloudnative-pg.v1/)), but the following should provide sufficient flexibility for most use cases. If you need to add more parameters to the values.yaml file, please limit changes as much as possible, in the interest of simplicity. After adding values and their associated documentation, regenerate the parameters table below, using the [Bitnami Readme Generator for Helm](https://github.com/bitnami/readme-generator-for-helm).

## Parameters

### CloudNative PG Operator Configuration Parameters

| Name                       | Description                                                              | Value           |
| -------------------------- | ------------------------------------------------------------------------ | --------------- |
| `instances`                | Number of PostgreSQL instances required in the PG cluster.               | `3`             |
| `existingSecret`           | Provide a basic auth Secret, or leave blank to auto-create one           | `""`            |
| `dbName`                   | The name of the database to create in the Postgres cluster.              | `test`          |
| `dbUser`                   | DB owner/username. Leave blank to match the DB name (see `dbName`)       | `""`            |
| `resources`                | Memory & CPU resource requests and limits for each PostgreSQL container. | `{}`            |
| `persistence.storageClass` | StorageClass for postgres volumes                                        | `csi-cephfs-sc` |
| `persistence.size`         | PVC Storage size request for postgres volumes                            | `1Gi`           |

### Options available to create a new PostgreSQL cluster

| Name                    | Description                                                             | Value    |
| ----------------------- | ----------------------------------------------------------------------- | -------- |
| `init.method`           | Choose which bootstrapping methods to use when creating the new cluster | `initdb` |
| `init.import`           | Import of data from external databases on startup                       | `{}`     |
| `init.pg_basebackup`    | Uses streaming replication to copy an existing PG instance              | `{}`     |
| `init.externalClusters` | external DB as a data source for import on startup                      | `[]`     |

### Optional PostgreSQL Configuration Parameters

| Name                                    | Description                                                       | Value             |
| --------------------------------------- | ----------------------------------------------------------------- | ----------------- |
| `postgresql.pg_hba`                     | Client authentication pg_hba.conf                                 | `[]`              |
| `postgresql.pg_ident`                   | Override 'pg_ident.conf' user mappings                            | `see values.yaml` |
| `postgresql.parameters.max_connections` | override PG default 200 max DB connections.                       | `250`             |
| `postgresql.parameters.shared_buffers`  | memory for caching data (PG default: 128MB)                       | `128MB`           |
| `replica.enabled`                       | Enable replica mode                                               | `false`           |
| `replica.source`                        | Name of the external cluster to use as the source for replication | `source-db`       |


## License
```
Copyright [2024] [Regents of the University of California]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## Acknowledgements
Work on this package was supported by:

- DataONE Network
- Arctic Data Center: NSF-PLR grant #2042102 to M. B. Jones, A. Budden, M. Schildhauer, and J. Dozier

Additional support was provided for collaboration by the National Center for Ecological Analysis and Synthesis, a Center funded by the University of California, Santa Barbara, and the State of California.

<a href="https://dataone.org">
<img src="https://user-images.githubusercontent.com/6643222/162324180-b5cf0f5f-ae7a-4ca6-87c3-9733a2590634.png"
  alt="DataONE_footer" style="width:44%;padding-right:5%;">
</a>
<a href="https://www.nceas.ucsb.edu">
<img src="https://www.nceas.ucsb.edu/sites/default/files/2020-03/NCEAS-full%20logo-4C.png"
  alt="NCEAS_footer" style="width:44%;padding-top:3%;padding-bottom:3%; background-color: white;">
</a>
