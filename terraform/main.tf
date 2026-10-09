# --------------------------------------------------------------------------
# Data resource blocks
# --------------------------------------------------------------------------
data "google_project" "project" {}

resource "random_id" "sql_suffix" {
  byte_length = 3
}

locals {
  db_instance_name = "${var.db_instance_name_prefix}-${random_id.sql_suffix.hex}"
  dlq_dataset_id   = "${var.datastream_bq_dataset_id_prefix}_dlq"
}

# --------------------------------------------------------------------------
# Registering Vault Provider
# --------------------------------------------------------------------------
data "vault_generic_secret" "sql" {
  path = var.vault_secret_path
}

# --------------------------------------------------------------------------
# Secret Manager
# --------------------------------------------------------------------------
module "sql_password_secret" {
  source              = "./modules/secret-manager"
  deletion_protection = false
  secret_data         = tostring(data.vault_generic_secret.sql.data["password"])
  secret_id           = var.db_password_secret_id
}

module "datastream_reader_secret" {
  source              = "./modules/secret-manager"
  deletion_protection = false
  secret_data         = tostring(data.vault_generic_secret.sql.data["password"])
  secret_id           = var.datastream_reader_secret_id
}

# --------------------------------------------------------------------------
# VPC Configuration
# --------------------------------------------------------------------------
module "vpc" {
  source                          = "./modules/vpc"
  vpc_name                        = var.vpc_name
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  subnets = [
    {
      name                     = var.vpc_subnet_name
      region                   = var.region
      purpose                  = "PRIVATE"
      private_ip_google_access = true
      ip_cidr_range            = var.vpc_subnet_cidr
    },
    {
      name                     = var.psc_subnet_name
      region                   = var.region
      purpose                  = "PRIVATE"
      private_ip_google_access = true
      ip_cidr_range            = var.psc_subnet_cidr
    }
  ]
  firewall_data = [
    {
      name          = "datastream-psc-to-cloudsql"
      source_ranges = [var.psc_subnet_cidr]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["3306"]
        }
      ]
    }
  ]
}

# --------------------------------------------------------------------------
# Cloud SQL Configuration
# --------------------------------------------------------------------------
module "mysql" {
  source                      = "./modules/cloud-sql"
  name                        = local.db_instance_name
  db_name                     = var.db_name
  db_user                     = var.db_admin_username
  db_version                  = var.db_version
  location                    = var.region
  tier                        = var.db_tier
  availability_type           = var.db_availability_type
  disk_size                   = var.db_disk_size_gb
  disk_type                   = var.db_disk_type
  disk_autoresize             = var.db_disk_autoresize
  disk_autoresize_limit       = var.db_disk_autoresize_limit_gb
  ipv4_enabled                = var.db_ipv4_enabled
  deletion_protection_enabled = var.db_deletion_protection_enabled

  psc_config = [
    {
      psc_enabled               = true
      allowed_consumer_projects = [var.project_id]
    }
  ]

  backup_configuration = [
    {
      enabled            = true
      binary_log_enabled = true
      start_time         = var.db_backup_start_time
      location           = var.region
      backup_retention_settings = [
        {
          retained_backups = var.db_backup_retained_count
          retention_unit   = "COUNT"
        }
      ]
    }
  ]
  database_flags = concat(
    var.db_database_flags,
    [{ name = "max_connections", value = tostring(var.db_max_connections) }]
  )
  password   = module.sql_password_secret.secret_data
  depends_on = [module.sql_password_secret]
}

resource "google_sql_user" "datastream_reader" {
  name       = "datastream_reader"
  instance   = local.db_instance_name
  password   = module.datastream_reader_secret.secret_data
  host       = "%"
  depends_on = [module.mysql]
}

# Automates the replication grants (opt-in; must run from inside the VPC, see scripts/).
resource "terraform_data" "datastream_reader_grants" {
  count = var.run_grant_script ? 1 : 0

  triggers_replace = [google_sql_user.datastream_reader.id]

  provisioner "local-exec" {
    command = "${path.root}/scripts/grant_datastream_reader.sh"
    environment = {
      DB_HOST         = google_compute_address.sql_psc.address
      DB_PORT         = tostring(var.sql_port)
      DB_ADMIN_USER   = var.db_admin_username
      DB_ADMIN_PASS   = module.sql_password_secret.secret_data
      DATASTREAM_USER = google_sql_user.datastream_reader.name
    }
  }

  depends_on = [google_compute_forwarding_rule.sql_psc]
}

resource "google_project_iam_member" "datastream_bq_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-datastream.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "datastream_bq_jobuser" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-datastream.iam.gserviceaccount.com"
}

# --------------------------------------------------------------------------
# Private Service Connect Configuration
# --------------------------------------------------------------------------
resource "google_compute_network_attachment" "datastream" {
  name                  = "datastream-psc-attachment"
  region                = var.region
  connection_preference = "ACCEPT_AUTOMATIC"
  subnetworks           = [module.vpc.subnet_ids[var.psc_subnet_name]]
}

resource "google_compute_address" "sql_psc" {
  name         = "sql-psc-endpoint"
  region       = var.region
  subnetwork   = module.vpc.subnet_ids[var.vpc_subnet_name]
  address_type = "INTERNAL"
}

resource "google_compute_forwarding_rule" "sql_psc" {
  name                  = "sql-psc-endpoint"
  region                = var.region
  network               = module.vpc.vpc_id
  ip_address            = google_compute_address.sql_psc.self_link
  load_balancing_scheme = ""
  target                = module.mysql.psc_service_attachment_link
}

# --------------------------------------------------------------------------
# Datastream Configuration
# --------------------------------------------------------------------------
resource "google_datastream_private_connection" "private_connection" {
  display_name          = "datastream-mysql-private-connection"
  location              = var.region
  private_connection_id = "datastream-mysql-private-connection"

  psc_interface_config {
    network_attachment = google_compute_network_attachment.datastream.id
  }
  depends_on = [google_compute_network_attachment.datastream]
}

resource "google_datastream_connection_profile" "source_connection_profile" {
  display_name          = "Source connection profile"
  location              = var.region
  connection_profile_id = "source-profile"

  mysql_profile {
    hostname = google_compute_address.sql_psc.address
    port     = var.sql_port
    username = google_sql_user.datastream_reader.name
    password = module.datastream_reader_secret.secret_data
  }

  private_connectivity {
    private_connection = google_datastream_private_connection.private_connection.id
  }

  depends_on = [module.mysql]
}

resource "google_datastream_connection_profile" "destination_connection_profile" {
  display_name          = "Destination connection profile"
  location              = var.region
  connection_profile_id = "destination-profile"

  bigquery_profile {}
}

resource "google_datastream_stream" "stream" {
  stream_id    = var.datastream_stream_id
  location     = var.region
  display_name = var.datastream_display_name

  desired_state = var.datastream_desired_state

  source_config {
    source_connection_profile = google_datastream_connection_profile.source_connection_profile.id

    mysql_source_config {
      include_objects {
        mysql_databases {
          database = var.db_name

          dynamic "mysql_tables" {
            for_each = var.datastream_tables
            content {
              table = mysql_tables.value
            }
          }
        }
      }

      max_concurrent_cdc_tasks      = var.datastream_max_concurrent_cdc_tasks
      max_concurrent_backfill_tasks = var.datastream_max_concurrent_backfill_tasks
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.destination_connection_profile.id

    bigquery_destination_config {
      source_hierarchy_datasets {
        dataset_template {
          location          = var.region
          dataset_id_prefix = var.datastream_bq_dataset_id_prefix
        }
      }

      data_freshness = var.datastream_data_freshness
    }
  }

  backfill_all {}

  depends_on = [
    google_datastream_connection_profile.source_connection_profile,
    google_datastream_connection_profile.destination_connection_profile,
    google_project_iam_member.datastream_bq_editor,
    google_project_iam_member.datastream_bq_jobuser,
    terraform_data.datastream_reader_grants,
    module.mysql
  ]
}

# --------------------------------------------------------------------------
# Observability Configuration
# --------------------------------------------------------------------------
module "cloudsql_error_log" {
  source = "./modules/observability/metrics"

  name         = "cloudsql_mysql_error_log"
  display_name = "Cloud SQL MySQL error log entries"
  filter       = <<-EOT
    resource.type="cloudsql_database"
    log_id("cloudsql.googleapis.com/mysql.err")
    severity>=ERROR
  EOT

  metric_kind = "DELTA"
  value_type  = "INT64"
  label_extractors = {
    "database_id" = "EXTRACT(resource.labels.database_id)"
  }
}

module "cloudsql_slow_queries" {
  source = "./modules/observability/metrics"

  name         = "cloudsql_slow_queries"
  display_name = "Cloud SQL slow queries"
  filter       = <<-EOT
    resource.type="cloudsql_database"
    log_id("cloudsql.googleapis.com/mysql-slow.log")
  EOT

  metric_kind      = "DELTA"
  value_type       = "INT64"
  label_extractors = {}
}

module "cloudsql_backup_failures" {
  source = "./modules/observability/metrics"

  name         = "cloudsql_backup_failures"
  display_name = "Cloud SQL backup failures"
  filter       = <<-EOT
    resource.type="cloudsql_database"
    protoPayload.serviceName="cloudsql.googleapis.com"
    protoPayload.methodName=~"(?i)backup"
    severity>=ERROR
  EOT

  metric_kind      = "DELTA"
  value_type       = "INT64"
  label_extractors = {}
}

module "datastream_errors" {
  source = "./modules/observability/metrics"

  name         = "datastream_errors"
  display_name = "Datastream stream errors"
  filter       = <<-EOT
    resource.type="datastream.googleapis.com/Stream"
    severity>=ERROR
  EOT

  metric_kind      = "DELTA"
  value_type       = "INT64"
  label_extractors = {}
}

locals {
  cloudsql_alerts = {
    cpu = {
      display    = "CPU > 80% for 10m"
      metric     = "cloudsql.googleapis.com/database/cpu/utilization"
      comparison = "COMPARISON_GT"
      threshold  = 0.8
      duration   = "600s"
      aligner    = "ALIGN_MEAN"
    }
    memory = {
      display    = "Memory > 90% for 10m"
      metric     = "cloudsql.googleapis.com/database/memory/utilization"
      comparison = "COMPARISON_GT"
      threshold  = 0.9
      duration   = "600s"
      aligner    = "ALIGN_MEAN"
    }
    connections = {
      display    = "Connections > 80% of max_connections (${var.db_max_connections})"
      metric     = "cloudsql.googleapis.com/database/network/connections"
      comparison = "COMPARISON_GT"
      threshold  = floor(var.db_max_connections * 0.8)
      duration   = "300s"
      aligner    = "ALIGN_MEAN"
    }
    disk = {
      display    = "Disk utilization > 80%"
      metric     = "cloudsql.googleapis.com/database/disk/utilization"
      comparison = "COMPARISON_GT"
      threshold  = 0.8
      duration   = "600s"
      aligner    = "ALIGN_MEAN"
    }
    down = {
      display    = "Instance not up"
      metric     = "cloudsql.googleapis.com/database/up"
      comparison = "COMPARISON_LT"
      threshold  = 1
      duration   = "120s"
      aligner    = "ALIGN_MEAN"
    }
    failover = {
      display    = "Not available for failover (HA degraded)"
      metric     = "cloudsql.googleapis.com/database/available_for_failover"
      comparison = "COMPARISON_LT"
      threshold  = 1
      duration   = "300s"
      aligner    = "ALIGN_MEAN"
    }
  }

  datastream_alerts = {
    freshness = {
      display    = "Data freshness > 10 min"
      metric     = "datastream.googleapis.com/stream/freshness"
      comparison = "COMPARISON_GT"
      threshold  = 600
      duration   = "600s"
      aligner    = "ALIGN_MAX"
    }
    unsupported = {
      display    = "Unsupported events > 0"
      metric     = "datastream.googleapis.com/stream/unsupported_event_count"
      comparison = "COMPARISON_GT"
      threshold  = 0
      duration   = "0s"
      aligner    = "ALIGN_SUM"
    }
  }
}

resource "google_monitoring_alert_policy" "cloudsql" {
  for_each     = local.cloudsql_alerts
  display_name = "Cloud SQL: ${each.value.display}"
  combiner     = "OR"

  conditions {
    display_name = each.value.display
    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloudsql_database\"",
        "resource.labels.database_id = \"${var.project_id}:${local.db_instance_name}\"",
        "metric.type = \"${each.value.metric}\"",
      ])
      comparison      = each.value.comparison
      threshold_value = each.value.threshold
      duration        = each.value.duration
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = each.value.aligner
      }
    }
  }

  notification_channels = var.notification_channels
}

# --------------------------------------------------------------------------
# Dead Letter Queue(DLQ) Configuration
# --------------------------------------------------------------------------
module "dlq_dataset" {
  source      = "./modules/bigquery"
  dataset_id  = local.dlq_dataset_id
  location    = var.region
  description = "Dead-letter storage for unhandled Datastream CDC errors"
  tables = [{
    table_id            = "datastream_failed_events"
    deletion_protection = false
    time_partitioning = {
      field = "timestamp"
      type  = "DAY"
    }
    schema = jsonencode([
      { name = "timestamp", type = "TIMESTAMP", mode = "REQUIRED" },
      { name = "stream_id", type = "STRING", mode = "REQUIRED" },
      { name = "log_name", type = "STRING", mode = "NULLABLE" },
      { name = "severity", type = "STRING", mode = "NULLABLE" },
      { name = "error_message", type = "STRING", mode = "NULLABLE" },
      { name = "raw_payload", type = "STRING", mode = "NULLABLE" }
    ])
  }]
}

resource "google_bigquery_dataset_iam_member" "dlq_handler_writer" {
  dataset_id = local.dlq_dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${module.dlq_handler_function_service_account.sa_email}"
  depends_on = [module.dlq_dataset]
}

module "datastream_dlq" {
  source                     = "./modules/pubsub"
  topic_name                 = "datastream-cdc-dlq"
  enable_schema              = false
  message_retention_duration = "604800s"

  subscriptions = {
    "datastream-cdc-dlq-sub" = {
      subscription_name          = "datastream-cdc-dlq-sub"
      message_retention_duration = "604800s"
      retain_acked_messages      = false
      ack_deadline_seconds       = 60
    }
  }
}

# --------------------------------------------------------------------------
# Log Sink: Intercept Datastream Operational & Engine Errors
# --------------------------------------------------------------------------
resource "google_logging_project_sink" "datastream_error_sink" {
  name        = "datastream-cdc-error-sink"
  destination = "pubsub.googleapis.com/${module.datastream_dlq.topic_id}"
  filter      = <<-EOT
  (resource.type="datastream.googleapis.com/Stream" AND severity>=WARNING)
  OR
  (protoPayload.serviceName="datastream.googleapis.com" AND protoPayload.status.code!=0)
EOT

  unique_writer_identity = true
}

# Authorize Log Sink to publish directly to the Pub/Sub DLQ Topic
resource "google_pubsub_topic_iam_member" "sink_publisher" {
  topic  = module.datastream_dlq.topic_id
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.datastream_error_sink.writer_identity
}

# --------------------------------------------------------------------------
# Alert Channel for Pub/Sub (Link Monitoring Alert to DLQ Topic)
# --------------------------------------------------------------------------
module "datastream_alerts" {
  source     = "./modules/pubsub"
  topic_name = "datastream-cdc-alerts"

}

# Monitoring's notification service agent must be able to publish
resource "google_pubsub_topic_iam_member" "monitoring_publisher" {
  topic  = module.datastream_alerts.topic_name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
}

resource "google_monitoring_notification_channel" "dlq_pubsub" {
  display_name = "Datastream DLQ PubSub Channel"
  type         = "pubsub"

  labels = {
    topic = module.datastream_dlq.topic_id
  }
}

# Update notification channels on the existing Datastream alert policy:
# (Replace your existing resource declaration with this updated version)
resource "google_monitoring_alert_policy" "datastream" {
  for_each     = local.datastream_alerts
  display_name = "Datastream: ${each.value.display}"
  combiner     = "OR"

  conditions {
    display_name = each.value.display
    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"datastream.googleapis.com/Stream\"",
        "metric.type = \"${each.value.metric}\"",
      ])
      comparison      = each.value.comparison
      threshold_value = each.value.threshold
      duration        = each.value.duration
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = each.value.aligner
      }
    }
  }

  # Merges your manual notification channels with the automated PubSub channel
  notification_channels = concat(
    var.notification_channels == null ? [] : var.notification_channels,
    [google_monitoring_notification_channel.dlq_pubsub.name]
  )
}

# -----------------------------------------------------------------------------------------
# Cloud Function Configuration
# -----------------------------------------------------------------------------------------
module "dlq_handler_function_bucket_code" {
  source     = "./modules/gcs"
  project_id = var.project_id
  location   = var.region
  name       = "dlq-handler-function-code"
  cors       = []
  contents = [
    {
      name        = "dlq_handler_function_code.zip"
      source_path = "${path.module}/files/dlq_handler_function_code.zip"
      content     = ""
    }
  ]
  force_destroy               = true
  uniform_bucket_level_access = true
}

module "dlq_handler_function_service_account" {
  source        = "./modules/service-account"
  account_id    = "dlq-handler-function"
  display_name  = "DLQ handler function Service Account"
  project_id    = data.google_project.project.project_id
  member_prefix = "serviceAccount"
  permissions = [
    "roles/run.invoker",
    "roles/eventarc.eventReceiver",
    "roles/bigquery.jobUser"
  ]
}

module "dlq_handler_function" {
  source               = "./modules/cloud-run-function"
  function_name        = "dlq-handler-function"
  function_description = "A function to update media details in SQL database after the upload trigger"
  location             = var.region
  project_id           = var.project_id

  build_config = {
    handler = "handle_dlq_event"
    runtime = "python312"
    storage_source = {
      bucket = module.dlq_handler_function_bucket_code.bucket_name
      object = module.dlq_handler_function_bucket_code.bucket_objects["dlq_handler_function_code.zip"].name
    }
    build_environment_variables = {}
  }

  service_config = {
    max_instance_count = 3
    min_instance_count = 0
    available_memory   = "256M"
    timeout_seconds    = 60
    service_environment_variables = {
      BQ_PROJECT = var.project_id
      BQ_DATASET = local.dlq_dataset_id
      BQ_TABLE   = "datastream_failed_events"
    }
    max_instance_request_concurrency = 80
    available_cpu                    = "1" # <-- Changed from "4" to "1"
    ingress_settings                 = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision   = true
    service_account_email            = module.dlq_handler_function_service_account.sa_email
  }

  event_trigger = {
    service_account_email = module.dlq_handler_function_service_account.sa_email
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = module.datastream_dlq.topic_id
    retry_policy          = "RETRY_POLICY_RETRY"
    event_filters         = []
  }
}