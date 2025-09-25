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

1. Streaming Replication (same major versions)
   - Involves replication from an existing, binary-compatible PostgreSQL instance in the same cluster
   - major versions must be EQUAL for the source cluster and the destination cluster
2. Automated `pg_dump` and `pg_restore` import (works with mis-matched major versions) 
   - import a database from an existing PostgreSQL cluster, even if located outside Kubernetes
   - PostgreSQL major version for the source cluster must be LESS THAN OR EQUAL TO that of the destination cluster

Each of these is discussed in more detail below:

### 1. PostgreSQL major versions are EQUAL for the source cluster and the destination cluster

This approach uses `pg_basebackup` to create a PostgreSQL cluster by cloning an existing (and binary-compatible) one of the same major version, through the streaming replication protocol. See the [CloudNative PG documentation](https://cloudnative-pg.io/documentation/current/bootstrap/#bootstrap-from-a-live-cluster-pg_basebackup), and particularly note the warnings and the Requirements section!

Steps:

1. Ensure that the source PostgreSQL cluster is configured to allow replication connections from the destination cluster. This typically requires:
   1. modifying the `pg_hba.conf` file to include an entry that permits replication connections from the IP address or hostname of the new CNPG cluster; e.g.:

      ```shell
      # TYPE     DATABASE       USER        ADDRESS             METHOD
      host       replication    metacat     192.168.0.0/32      md5
      ```

   2. In the Bitnami PostgreSQL pod, log into `psql` as the `postgres` admin user:
       ```shell
       $ psql -U postgres
       psql (17.5)
       Type "help" for help.
       ```
   
       ...and do the following:

       ```sql
       -- grant `REPLICATION` privileges to the user defined in 'dbUser'
       -- (e.g. for "metacat"):
       ALTER ROLE metacat WITH REPLICATION;
      
       SELECT * FROM pg_create_physical_replication_slot('cnpg_slot');
       ```

### 2. PostgreSQL major version for the source cluster is LESS THAN OR EQUAL TO that of the destination cluster

This approach uses `pg_restore` as part of the initial cluster creation, or it can be applied to an existing, empty cluster, using `pg_dump` and `pg_restore`. See the [CloudNative PG documentation](https://cloudnative-pg.io/documentation/current/database_import/) for more information.
(Not yet implemented in this helm chart.)

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
| `persistence.storageClass` | PV StorageClass for postgres volumes                                     | `csi-cephfs-sc` |
| `persistence.size`         | PVC Storage size request for postgres volumes                            | `1Gi`           |

### Optional PostgreSQL Configuration Parameters

| Name                                    | Description                                 | Value             |
| --------------------------------------- | ------------------------------------------- | ----------------- |
| `postgresql.pg_hba`                     | Client authentication pg_hba.conf           | `[]`              |
| `postgresql.pg_ident`                   | Override username mappings: pg_ident.conf   | `see values.yaml` |
| `postgresql.parameters.max_connections` | override PG default 200 max DB connections. | `250`             |
| `postgresql.parameters.shared_buffers`  | memory for caching data (PG default: 128MB) | `128MB`           |


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
