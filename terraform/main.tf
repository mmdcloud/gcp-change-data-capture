# --------------------------------------------------------------------------
# Data resource blocks
# --------------------------------------------------------------------------
data "google_project" "project" {}

data "google_compute_image" "ubuntu_2404" {
  family  = var.image_family
  project = var.image_project
}

resource "random_id" "sql_suffix" {
  byte_length = 3
}

locals {
  db_instance_name = "${var.db_instance_name_prefix}-${random_id.sql_suffix.hex}"
  sql_proxy_zone   = "${var.region}-${var.sql_proxy_zone_suffix}"
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
      role                     = "ACTIVE"
      private_ip_google_access = true
      ip_cidr_range            = var.vpc_subnet_cidr
    },
    {
      name                     = var.psc_subnet_name
      region                   = var.region
      purpose                  = "PRIVATE"
      role                     = "ACTIVE"
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
  db_name                     = local.db_instance_name
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
      enabled                        = true
      binary_log_enabled             = true
      start_time                     = var.db_backup_start_time
      location                       = var.region
      point_in_time_recovery_enabled = var.db_point_in_time_recovery_enabled
      backup_retention_settings = [
        {
          retained_backups = var.db_backup_retained_count
          retention_unit   = "COUNT"
        }
      ]
    }
  ]
  database_flags = var.db_database_flags
  vpc_self_link  = module.vpc.self_link
  vpc_id         = module.vpc.vpc_id
  password       = module.sql_password_secret.secret_data
  depends_on     = [module.sql_password_secret]
}

resource "google_sql_user" "datastream_reader" {
  name     = "datastream_reader"
  instance = module.mysql.db_name
  password = module.datastream_reader_secret.secret_data
  host     = "%"
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
          database = local.db_instance_name

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
    module.mysql
  ]
}

#   GRANT REPLICATION SLAVE, REPLICATION CLIENT, SELECT ON *.* TO 'datastream_reader'@'%';
#   FLUSH PRIVILEGES;

# --------------------------------------------------------------------------
# Observability Configuration
# --------------------------------------------------------------------------
# module "cloudsql_cpu_utilization" {
#   source = "./modules/observability/metrics"

#   name   = "cloudsql_cpu_utilization"
#   filter = <<-EOT
#     resource.type="cloudsql_database"
#     metric.type="cloudsql.googleapis.com/database/cpu/utilization"
#   EOT

#   metric_kind  = "GAUGE"
#   value_type   = "DOUBLE"
#   display_name = "Cloud SQL CPU Utilization"

#   label_extractors = {}
# }
