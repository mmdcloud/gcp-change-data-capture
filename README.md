# GCP Change Data Capture (CDC) Enterprise Pipeline

[![Terraform](https://img.shields.io/badge/Terraform-%235835CC.svg?style=flat-square&logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Google Cloud](https://img.shields.io/badge/Google_Cloud-%234285F4.svg?style=flat-square&logo=google-cloud&logoColor=white)](https://cloud.google.com/)
[![MySQL](https://img.shields.io/badge/MySQL_8.0-%234479A1.svg?style=flat-square&logo=mysql&logoColor=white)](https://www.mysql.com/)
[![BigQuery](https://img.shields.io/badge/BigQuery-%23669DF6.svg?style=flat-square&logo=google-bigquery&logoColor=white)](https://cloud.google.com/bigquery)
[![Cloud Run](https://img.shields.io/badge/Cloud_Run_Functions-%234285F4.svg?style=flat-square&logo=google-cloud&logoColor=white)](https://cloud.google.com/run)
[![HashiCorp Vault](https://img.shields.io/badge/Vault-%23000000.svg?style=flat-square&logo=vault&logoColor=white)](https://www.vaultproject.io/)

Production-grade, enterprise-ready Change Data Capture (CDC) replication pipeline on Google Cloud Platform. Streams changes from **Cloud SQL MySQL 8.0** to **Google BigQuery** in near real-time via **Google Cloud Datastream**, secured over **Private Service Connect (PSC)** with an automated **Dead-Letter Queue (DLQ)** error-archival and observability engine.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Key Features](#key-features)
- [Repository Structure](#repository-structure)
- [Visual Verification Gallery](#visual-verification-gallery)
- [Core Components](#core-components)
  - [1. Cloud SQL MySQL (Source Database)](#1-cloud-sql-mysql-source-database)
  - [2. Networking & Private Service Connect (PSC)](#2-networking--private-service-connect-psc)
  - [3. Datastream CDC Engine](#3-datastream-cdc-engine)
  - [4. BigQuery Data Warehouse (Target)](#4-bigquery-data-warehouse-target)
  - [5. Resilient DLQ & Error Archiving Pipeline](#5-resilient-dlq--error-archiving-pipeline)
  - [6. Observability, Alerting & Metrics](#6-observability-alerting--metrics)
- [Prerequisites](#prerequisites)
- [Quickstart & Deployment Guide](#quickstart--deployment-guide)
  - [Step 1: Authenticate with GCP & Vault](#step-1-authenticate-with-gcp--vault)
  - [Step 2: Configure Environment Variables (`terraform.tfvars`)](#step-2-configure-environment-variables-terraformtfvars)
  - [Step 3: Terraform Initialization & Apply](#step-3-terraform-initialization--apply)
  - [Step 4: Grant Datastream Replication Privileges](#step-4-grant-datastream-replication-privileges)
  - [Step 5: Verify Stream Activation](#step-5-verify-stream-activation)
- [Configuration Reference](#configuration-reference)
- [Day-2 Operations & Runbooks](#day-2-operations--runbooks)
  - [Adding New Tables to Replication](#adding-new-tables-to-replication)
  - [Inspecting the Dead Letter Queue](#inspecting-the-dead-letter-queue)
  - [Handling Alert Failures & Propagation Delays](#handling-alert-failures--propagation-delays)
- [Security & Compliance](#security--compliance)
- [Teardown & Cleanup](#teardown--cleanup)

---

## Architecture Overview

```
                                  +-------------------------------------------------------------+
                                  |                      Google Cloud Platform                  |
                                  |                                                             |
+----------------------+          |  +-------------------+               +-------------------+  |
|   HashiCorp Vault    |          |  | GCP Secret Manager|               |   Cloud Logging   |  |
| (Enterprise Secrets) |          |  |  (Mirrored Creds) |               |     Log Sink      |  |
+----------+-----------+          |  +---------+---------+               +---------+---------+  |
           |                      |            |                                   |            |
           +---- Sync Credentials ----------->+                                   | (Errors)   |
                                  |            |                                   v            |
                                  |  +---------v-----------------+       +---------+---------+  |
                                  |  |   Cloud SQL (MySQL 8.0)   |       |    Pub/Sub DLQ    |  |
                                  |  | - Regional HA, No Public IP|       |  "datastream-     |  |
                                  |  | - Binary Logging (ROW)    |       |   cdc-dlq"        |  |
                                  |  +---------+-----------------+       +----+--------------+  |
                                  |            | (PSC Attachment)             | (Push Sub)      |
                                  |            v                              v                 |
                                  |  +---------+-----------------+       +----+--------------+  |
                                  |  | Forwarding Rule & Endpoint|       | Cloud Run Function|  |
                                  |  | (10.0.0.0/16 Private VPC) |       | (dlq-handler, v2) |  |
                                  |  +---------+-----------------+       +----+--------------+  |
                                  |            | (PSC Interface)              | (Batch Ingest)  |
                                  |            v                              v                 |
                                  |  +---------+-----------------+       +----+--------------+  |
                                  |  |      GCP Datastream       |       |  BigQuery DLQ     |  |
                                  |  |  (Real-Time CDC Stream)   |       |  failed_events    |  |
                                  |  +---------+-----------------+       +-------------------+  |
                                  |            | (Continuous Streaming)                         |
                                  |            v                                                |
                                  |  +---------+-----------------+                              |
                                  |  |     BigQuery Analytics    |                              |
                                  |  |    (cdc_${environment})   |                              |
                                  |  +---------------------------+                              |
                                  +-------------------------------------------------------------+
```

### Data Plane & Control Plane Lifecycle
1. **Source Mutations**: Client applications execute `INSERT`, `UPDATE`, and `DELETE` operations against Cloud SQL MySQL. Transactions are committed to MySQL row-based binary logs (`binlog_row_image = full`).
2. **Private Network Routing**: Datastream communicates with MySQL across an internal **Private Service Connect (PSC)** network interface without entering public IP space. Traffic is encrypted end-to-end using TLS/SSL with Cloud SQL's internal Server CA certificate.
3. **Change Data Capture**: Datastream reads the binary log stream with a dedicated, least-privilege `datastream_reader` account and replicates change events with sub-second to minute-level freshness directly into BigQuery.
4. **Error Handling & DLQ**: Engine warnings and processing failures are captured by a Cloud Logging sink, routed into a Pub/Sub topic, and ingested into a partitioned BigQuery dead-letter table via a resilient Cloud Run function.

---

## Key Features

- **Zero-Public Exposure**: Cloud SQL runs without a public IPv4 address (`ipv4_enabled = false`). All source ingress is mediated via PSC Service Attachments and Forwarding Rules.
- **Mutual Exclusivity Enforcement**: Eliminates Private Services Access (PSA) VPC peering limitations, IP exhaustion, and transitivity issues by utilizing Private Service Connect (PSC).
- **Vault-Integrated Secret Management**: Credentials for `app_admin` and `datastream_reader` originate in HashiCorp Vault and are automatically registered in GCP Secret Manager.
- **Failover & High Availability**: Cloud SQL is provisioned with `REGIONAL` multi-zone availability, automatic SSD storage expansion up to 500 GB, and 7-day binary log retention.
- **Enterprise Error Handling (DLQ)**:
  - Pub/Sub push subscription with exponential backoff (`10s` to `300s`) and OIDC authentication.
  - Secondary dead-letter topic for poison messages after 5 delivery attempts.
  - Gen2 Cloud Run Function running Python 3.12 with idempotency / deduplication against BigQuery streaming inserts.
- **Full-Spectrum Observability**:
  - 9 automated Cloud SQL operational alerts (CPU, Memory, Disk, Connections, Down, Failover, Error Logs, Slow Queries, Backup Failures).
  - 3 Datastream alerts (Freshness SLA breach, Stream errors, Unsupported events).
  - 2 DLQ pipeline health alerts (unacked messages, dead-letter messages).
  - Built-in `time_sleep` barrier to prevent GCP asynchronous metric descriptor propagation race conditions.

---

## Repository Structure

```
.
├── README.md                                  # Production documentation
├── screenshots/                               # Deployment & verification console screenshots
│   ├── Screenshot from 2026-11-18 08-14-45.png # Datastream stream active overview
│   ├── Screenshot from 2026-11-18 08-15-04.png # Datastream connection profiles
│   ├── Screenshot from 2026-11-18 08-15-26.png # Private connectivity (PSC interface)
│   ├── Screenshot from 2026-11-18 08-16-34.png # Cloud SQL PSC instance details
│   ├── Screenshot from 2026-11-18 08-17-17.png # BigQuery datasets (target & DLQ)
│   ├── Screenshot from 2026-11-18 08-25-00.png # Live replicated data preview in BigQuery
│   └── Screenshot from 2026-11-18 08-25-11.png # Terraform apply successful execution
├── src/
│   └── dlq-function/                          # Cloud Run function source (Gen2)
│       ├── main.py                            # Idempotent error-ingestion handler
│       └── requirements.txt                   # Production dependencies
└── terraform/
    ├── main.tf                                # Root pipeline definition
    ├── variables.tf                           # Input variables & validations
    ├── outputs.tf                             # Exported resource identifiers
    ├── provider.tf                            # Provider configurations (Google, Google-Beta, Vault, Time)
    ├── terraform.tfvars                       # Environment-specific parameters
    ├── files/
    │   └── dlq_handler_function_code.zip      # Packaged Cloud Run deployment artifact
    ├── scripts/
    │   └── grant_datastream_reader.sh         # Helper script for MySQL replication grants
    └── modules/
        ├── bigquery/                          # BigQuery dataset & table module
        ├── cloud-run-function/                # Cloud Run / Functions Gen2 module
        ├── cloud-sql/                         # Hardened Cloud SQL MySQL module
        ├── datastream/                        # Datastream stream & connection profile module
        ├── gcs/                               # GCS bucket module with retention & encryption
        ├── observability/                     # Monitoring metrics, alert policies & dashboards
        ├── pubsub/                            # Pub/Sub topic & subscription module
        ├── secret-manager/                    # GCP Secret Manager module
        ├── service-account/                   # Least-privilege IAM service account module
        └── vpc/                               # VPC, subnets, and firewall rules module
```

---

## Visual Verification Gallery

| Component | Console View | Description |
| :--- | :--- | :--- |
| **Terraform Apply** | [Terminal Execution](#step-3-terraform-initialization--apply) | All 80 resources deployed cleanly without drift. |
| **Cloud SQL MySQL** | [Instance Overview](#1-cloud-sql-mysql-source-database) | Enterprise edition with Private Service Connect (PSC) & disabled public IP. |
| **PSC Interface** | [Private Connectivity](#2-networking--private-service-connect-psc) | Datastream network attachment interface for secure intra-VPC routing. |
| **Profiles** | [Connection Profiles](#3-datastream-cdc-engine) | Source MySQL pointing to internal IP `10.0.0.2:3306` & BigQuery destination. |
| **Datastream** | [Stream Health](#3-datastream-cdc-engine) | Active CDC stream replicating transactions into BigQuery `cdc_prod`. |
| **BigQuery** | [Target & DLQ Datasets](#4-bigquery-data-warehouse-target) | Replicated target dataset (`cdc_prod`) and dead-letter dataset (`dp_dlq`). |
| **CDC Verification** | [Live Replicated Data](#step-5-verify-stream-activation) | Replicated `db_users` records streaming with Datastream metadata. |

---

## Core Components

### 1. Cloud SQL MySQL (Source Database)
- **Engine**: MySQL 8.0 (`MYSQL_8_0`) on `db-custom-2-8192` (2 vCPU, 8 GB RAM).
- **Storage**: 100 GB `PD_SSD` with automated expansion up to 500 GB.
- **Binary Logging**: Enabled with 7-day retention (`binlog_expire_logs_seconds = 604800`) and `binlog_row_image = full` to provide full before-and-after values for Datastream CDC.
- **SSL Enforcement**: Configured with `ssl_mode = ENCRYPTED_ONLY`. The database CA certificate is exported via Terraform and directly loaded into Datastream.
- **Performance & Diagnostics**: Query Insights enabled with query plan sampling and application tag tracking.

<p align="center">
  <img src="screenshots/Screenshot%20from%202026-11-18%2008-16-34.png" alt="Cloud SQL Instance Overview with Private Service Connect" width="100%" />
  <br>
  <em>Figure 1: Cloud SQL MySQL instance showing Enterprise Edition, Regional HA, Private Service Connect (PSC) enabled with Service Attachment, and Public IP disabled.</em>
</p>

---

### 2. Networking & Private Service Connect (PSC)
- **Primary VPC Subnet (`vpc-subnet`)**: `10.0.0.0/16` for application workloads and the internal PSC Forwarding Rule endpoint.
- **Datastream PSC Subnet (`datastream-psc-subnet`)**: `10.10.0.0/24` dedicated to Datastream's network attachment interface.
  > [!IMPORTANT]
  > Subnet CIDRs avoid `10.1.0.0/16` and `10.2.2.0/24`, which are reserved internally by Google Cloud Datastream.
- **Private Forwarding Rule (`sql-psc-endpoint`)**: Directs traffic arriving on internal IP port `3306` to the Cloud SQL PSC Service Attachment.

<p align="center">
  <img src="screenshots/Screenshot%20from%202026-11-18%2008-15-26.png" alt="Datastream Private Connectivity Configuration" width="100%" />
  <br>
  <em>Figure 2: Datastream Private Connectivity configuration using PSC Interfaces linked to the network attachment.</em>
</p>

---

### 3. Datastream CDC Engine
- **Private Connection**: Connects Datastream to the VPC Network Attachment.
- **Source Profile**: Authenticates as `datastream_reader` against the internal PSC IP endpoint (`10.0.0.2:3306`) with TLS verification.
- **Destination Profile**: Directs output into BigQuery.
- **Data Freshness SLA**: Set to `900s` (15 minutes). If replication lag exceeds 2x the SLA (`1800s`), an alert triggers.
- **Safe Bootstrapping**: Uses dynamic evaluation (`desired_state = local.grants_ready ? var.datastream_desired_state : "NOT_STARTED"`) to prevent Datastream from crashing during initial provisioning before replication privileges are granted.

<p align="center">
  <img src="screenshots/Screenshot%20from%202026-11-18%2008-15-04.png" alt="Datastream Connection Profiles" width="100%" />
  <br>
  <em>Figure 3: Connection Profiles configured for MySQL source (internal IP 10.0.0.2:3306) and BigQuery destination.</em>
</p>

<p align="center">
  <img src="screenshots/Screenshot%20from%202026-11-18%2008-14-45.png" alt="Datastream Stream Active Details" width="100%" />
  <br>
  <em>Figure 4: Active Datastream CDC stream (`db-stream`) running in `asia-south1`, continuously replicating binary logs to BigQuery `cdc_prod`.</em>
</p>

---

### 4. BigQuery Data Warehouse (Target)
- **Dataset**: `cdc_${var.environment}` provisioned regionally for analytics consumption.
- **Dead-Letter Storage**: Dedicated `dp_dlq` dataset housing the partitioned `datastream_failed_events` table.
- **Access Control**: Datastream Google-managed Service Account (`service-${PROJECT_NUMBER}@gcp-sa-datastream.iam.gserviceaccount.com`) is granted `roles/bigquery.dataEditor` and `roles/bigquery.jobUser`.

<p align="center">
  <img src="screenshots/Screenshot%20from%202026-11-18%2008-17-17.png" alt="BigQuery Datasets Overview" width="100%" />
  <br>
  <em>Figure 5: BigQuery console showing the primary CDC target dataset (`cdc_prod`) and Dead-Letter Queue dataset (`dp_dlq`).</em>
</p>

---

### 5. Resilient DLQ & Error Archiving Pipeline
- **Log Sink**: `google_logging_project_sink.datastream_error_sink` filters operational errors from `datastream.googleapis.com/Stream`.
- **Pub/Sub Transport**: Messages publish to `datastream-cdc-dlq` and are delivered via push subscription to `dlq-handler-function`.
- **Cloud Run Function (Gen2)**:
  - Python 3.12 HTTP push handler decorated with `@functions_framework.http`.
  - Parses log envelopes, extracts timestamps, error messages, and raw payloads.
  - Implements best-effort deduplication using `insertId`/`messageId` into `datastream_failed_events`.
  - Returns `204` on success, `500` on transient failures to invoke Pub/Sub backoff.
- **Poison Message Dead-Letter**: After 5 failed attempts, messages are diverted to `datastream-cdc-error-dead-letter` to prevent head-of-line blocking.

---

### 6. Observability, Alerting & Metrics
- **Metric Propagation Guard**: `time_sleep.wait_for_log_metrics` pauses for 120 seconds after creating custom log-based metrics, guaranteeing metric descriptors exist in Cloud Monitoring before alerting policies attach to them.
- **Alert Policies**:
  | Category | Alert Policy | Condition / Threshold |
  | :--- | :--- | :--- |
  | **Cloud SQL** | High CPU Utilization | CPU > 80% for 10m (`ALIGN_MEAN`) |
  | **Cloud SQL** | High Memory Utilization | Memory > 90% for 10m (`ALIGN_MEAN`) |
  | **Cloud SQL** | High Connection Count | Connections > 80% of limit for 5m |
  | **Cloud SQL** | Storage Utilization | Disk > 80% for 10m |
  | **Cloud SQL** | Database Down | Instance down for 2m |
  | **Cloud SQL** | Failover Degraded | Available for failover < 1 for 5m |
  | **Cloud SQL** | Engine Error Logs | `mysql.err` entries with severity >= ERROR |
  | **Cloud SQL** | Slow Query Surge | > 20 slow queries in 5m |
  | **Cloud SQL** | Backup Failures | Backup operation failures > 0 |
  | **Datastream** | Freshness Lag | Freshness > 2x SLA (1800s for 900s SLA) |
  | **Datastream** | Stream Errors | Stream errors > 0 |
  | **Datastream** | Unsupported Events | Unsupported event occurrences > 0 |
  | **DLQ System** | Oldest Unacked Message | Oldest unacked message > 10m |
  | **DLQ System** | Dead-Letter Overflow | Messages present in dead-letter topic > 0 |

---

## Prerequisites

1. **Google Cloud SDK (`gcloud`)**: Version >= 450.0.0
2. **Terraform CLI**: Version >= 1.5.0
3. **HashiCorp Vault**: Accessible cluster containing MySQL secrets:
   - Path `secret/sql` with key `password` (Admin password).
   - Path `secret/datastream_reader` with key `password` (Datastream user password).
4. **IAM Permissions**: User or CI/CD runner must possess:
   - `roles/owner` or combination of:
     - `roles/resourcemanager.projectIamAdmin`
     - `roles/compute.networkAdmin`
     - `roles/cloudsql.admin`
     - `roles/datastream.admin`
     - `roles/bigquery.admin`
     - `roles/pubsub.admin`
     - `roles/run.admin`
     - `roles/monitoring.admin`

---

## Quickstart & Deployment Guide

### Step 1: Authenticate with GCP & Vault

```bash
# GCP Application Default Credentials
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID

# Authenticate to Vault
export VAULT_ADDR="https://vault.yourdomain.com"
vault login
```

### Step 2: Configure Environment Variables (`terraform.tfvars`)

Create or update `terraform/terraform.tfvars`:

```hcl
project_id         = "your-production-project-id"
region             = "us-central1"
environment        = "prod"
protect_resources  = true

# Network Configuration
vpc_name           = "cdc-vpc"
vpc_subnet_cidr    = "10.0.0.0/16"
psc_subnet_cidr    = "10.10.0.0/24"

# Database Configuration
db_name            = "production_db"
db_admin_username  = "app_admin"
db_tier            = "db-custom-2-8192"

# Vault Paths
vault_secret_path                   = "secret/sql"
vault_datastream_reader_secret_path = "secret/datastream_reader"

# Datastream Configuration
datastream_tables = ["users", "orders", "payments"]
datastream_desired_state = "RUNNING"
datastream_data_freshness = "900s"

# Alerting
alert_email        = "data-ops-alerts@yourdomain.com"
```

### Step 3: Terraform Initialization & Apply

```bash
cd terraform

# Initialize providers (Google, Google-Beta, Vault, Time, Random)
terraform init

# Review execution plan
terraform plan -out=tfplan.binary

# Apply infrastructure
terraform apply tfplan.binary
```

<p align="center">
  <img src="screenshots/Screenshot%20from%202026-11-18%2008-25-11.png" alt="Terraform Apply Complete" width="100%" />
  <br>
  <em>Figure 6: Terraform Apply output demonstrating clean provisioning of all 80 resources and outputting connection parameters.</em>
</p>

> [!NOTE]
> During initial provisioning, `datastream_desired_state` automatically defaults to `NOT_STARTED` until replication privileges are granted.

### Step 4: Grant Datastream Replication Privileges

Cloud SQL enforces strict access controls. The `datastream_reader` MySQL user must be granted replication privileges from within the private network.

#### Option A: Automated via Provisioner
Set `run_grant_script = true` in `terraform.tfvars` if running Terraform from a bastion or runner hosted directly inside the VPC.

#### Option B: Manual Execution via Bastion / Cloud Shell
From a machine with access to the internal PSC endpoint:

```bash
cd terraform/scripts
chmod +x grant_datastream_reader.sh

export DB_HOST="$(terraform -chdir=.. output -raw sql_instance_private_ip)"
export DB_PORT="3306"
export DB_ADMIN_USER="app_admin"
export DB_ADMIN_PASS="<YOUR_VAULT_ADMIN_PASSWORD>"
export DATASTREAM_USER="datastream_reader"

./grant_datastream_reader.sh
```

Once executed, update `terraform.tfvars`:
```hcl
grants_applied = true
```
And re-run `terraform apply` to transition Datastream into the `RUNNING` state.

### Step 5: Verify Stream Activation

```bash
# Check stream state
gcloud datastream streams describe db-stream \
    --location=us-central1 \
    --format="value(state)"

# Validate target BigQuery tables
bq ls --project_id=YOUR_PROJECT_ID cdc_prod
```

<p align="center">
  <img src="screenshots/Screenshot%20from%202026-11-18%2008-25-00.png" alt="BigQuery Table Preview showing Replicated Records" width="100%" />
  <br>
  <em>Figure 7: BigQuery `db_users` table preview showing continuous CDC replication with `datastream_metadata` columns populated.</em>
</p>

---

## Configuration Reference

| Variable Name | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `project_id` | `string` | **Required** | GCP Project ID where all resources reside. |
| `region` | `string` | **Required** | GCP Region for regional infrastructure. |
| `environment` | `string` | `"prod"` | Deployment environment (`dev`, `staging`, `prod`). |
| `protect_resources` | `bool` | `false` | Enables deletion protection across Cloud SQL, BigQuery, and GCS. Set `true` in production. |
| `vpc_name` | `string` | `"vpc"` | Name of the VPC network. |
| `vpc_subnet_cidr` | `string` | `"10.0.0.0/16"` | CIDR range for primary private subnet. |
| `psc_subnet_cidr` | `string` | `"10.10.0.0/24"` | CIDR range for Datastream PSC attachment subnet. |
| `db_name` | `string` | `"db"` | MySQL database name. |
| `db_tier` | `string` | `"db-custom-2-8192"` | Cloud SQL instance machine tier. |
| `db_availability_type` | `string` | `"REGIONAL"` | High availability tier (`REGIONAL` or `ZONAL`). |
| `db_max_connections` | `number` | `1000` | Cloud SQL max connections database flag. |
| `datastream_tables` | `list(string)` | `["users"]` | List of MySQL tables included in the CDC stream. |
| `datastream_desired_state`| `string` | `"RUNNING"` | Target state of the Datastream stream (`RUNNING`, `PAUSED`, `NOT_STARTED`). |
| `datastream_data_freshness`| `string` | `"900s"` | Target BigQuery sync latency SLA. |
| `grants_applied` | `bool` | `false` | Confirms manual execution of replication grants to allow stream start. |
| `run_grant_script` | `bool` | `false` | Triggers local-exec replication grant script if inside VPC. |
| `alert_email` | `string` | `""` | Optional email recipient for Cloud Monitoring alert notifications. |
| `vault_secret_path` | `string` | `"secret/sql"` | Vault path containing database root credentials. |
| `vault_datastream_reader_secret_path` | `string` | `"secret/datastream_reader"` | Vault path containing Datastream reader credentials. |

---

## Day-2 Operations & Runbooks

### Adding New Tables to Replication

1. Ensure the table exists in MySQL with a defined Primary Key:
   ```sql
   CREATE TABLE production_db.invoices (
       id BIGINT AUTO_INCREMENT PRIMARY KEY,
       amount DECIMAL(10,2),
       created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
   );
   ```
2. Update `datastream_tables` in `terraform.tfvars`:
   ```hcl
   datastream_tables = ["users", "orders", "payments", "invoices"]
   ```
3. Run `terraform apply`. Datastream will backfill the new table without interrupting existing CDC streams.

### Inspecting the Dead Letter Queue

To inspect errors captured by the log sink:

```sql
SELECT
  timestamp,
  stream_id,
  severity,
  error_message,
  raw_payload
FROM
  `YOUR_PROJECT_ID.dp_dlq.datastream_failed_events`
ORDER BY
  timestamp DESC
LIMIT 50;
```

If poison messages accumulate in the secondary dead-letter subscription:
```bash
gcloud pubsub subscriptions pull datastream-cdc-error-dead-letter-sub \
    --auto-ack \
    --limit=10 \
    --format=json
```

### Handling Alert Failures & Propagation Delays

When introducing new log-based metrics and alert policies simultaneously, Google Cloud Monitoring can return an `Error 404: Cannot find metric(s)`.

- **Root Cause**: The Cloud Logging metric descriptor takes 1 to 5 minutes to index in Cloud Monitoring.
- **Built-in Guard**: This repository includes a 120-second `time_sleep.wait_for_log_metrics` barrier between metric generation and alert policy attachments in [`terraform/main.tf`](terraform/main.tf).
- **Remediation**: If encountered during rapid plan/apply iterations, wait 2 minutes and re-run `terraform apply`.

---

## Security & Compliance

- **Network Isolation**: Zero public IP addresses assigned to database or function compute infrastructure.
- **Identity-Aware Access (IAM)**: Service accounts run with minimal privileges:
  - `dlq-handler-function`: Restricted to `roles/run.invoker`, `roles/bigquery.dataEditor`, and `roles/eventarc.eventReceiver`.
  - Datastream Service Identity: Limited strictly to destination BigQuery datasets.
- **Encryption**:
  - In-Transit: Enforced TLS/SSL with Cloud SQL Server CA verification (`ssl_config.ca_certificate`).
  - At-Rest: Google-managed or CMEK encryption across GCS, Cloud SQL, and BigQuery.
- **Credential Governance**: Plaintext passwords never reside in version control. All secrets are retrieved from HashiCorp Vault during plan/apply and securely mirrored into GCP Secret Manager.

---

## Teardown & Cleanup

To decommission the entire pipeline:

1. **Disable Deletion Protection**:
   In `terraform.tfvars`, set:
   ```hcl
   protect_resources = false
   ```
   Run `terraform apply` to unlock protected resources.

2. **Destroy Infrastructure**:
   ```bash
   terraform destroy
   ```

> [!CAUTION]
> Running `terraform destroy` permanently deletes the Cloud SQL database, BigQuery CDC datasets, Pub/Sub message queues, and error archives. Ensure all critical data is backed up prior to destruction.
