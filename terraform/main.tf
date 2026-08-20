# --------------------------------------------------------------------------
# Data resource blocks
# --------------------------------------------------------------------------
data "google_project" "project" {}

# resource "random_password" "app_user" {
#   length           = 32
#   special          = true
#   override_special = "!#$%^&*()-_=+[]{}<>:?"
# }

resource "random_id" "sql_suffix" {
  byte_length = 3
}

# --------------------------------------------------------------------------
# Registering Vault Provider
# --------------------------------------------------------------------------
data "vault_generic_secret" "sql" {
  path = "secret/sql"
}

# --------------------------------------------------------------------------
# Secret Manager
# --------------------------------------------------------------------------
module "sql_password_secret" {
  source      = "./modules/secret-manager"
  secret_data = tostring(data.vault_generic_secret.sql.data["password"])
  secret_id   = "db_password_secret"
}

# module "app_password_secret" {
#   source      = "./modules/secret-manager"
#   secret_data = random_password.app_user.result
#   secret_id   = "db_app_user_password_secret"
# }

# --------------------------------------------------------------------------
# VPC Configuration
# --------------------------------------------------------------------------
module "vpc" {
  source                          = "./modules/vpc"
  vpc_name                        = "vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  subnets = [
    {
      name                     = "vpc-subnet"
      region                   = var.region
      purpose                  = "PRIVATE"
      role                     = "ACTIVE"
      private_ip_google_access = true
      ip_cidr_range            = "10.0.0.0/16"
    },
    {
      name                     = "proxy-vm-subnet"
      region                   = var.region
      purpose                  = "PRIVATE"
      role                     = "ACTIVE"
      private_ip_google_access = true
      ip_cidr_range            = "10.1.0.0/16"
    }
  ]
  firewall_data = [
    {
      name          = "datastream-cloudsql-firewall"
      source_ranges = ["10.99.0.0/29"]
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
  name                        = "mysql-${random_id.sql_suffix.hex}"
  db_name                     = "mysql-${random_id.sql_suffix.hex}"
  db_user                     = "mohit"
  db_version                  = "MYSQL_8_0"
  location                    = var.region
  tier                        = "db-f1-micro"
  availability_type           = "ZONAL"
  disk_size                   = 100 # GB
  disk_type                   = "PD_SSD"
  disk_autoresize             = true
  disk_autoresize_limit       = 500 # GB
  ipv4_enabled                = false
  deletion_protection_enabled = false
  backup_configuration = [
    {
      enabled                        = true
      binary_log_enabled             = true
      start_time                     = "03:00"
      location                       = var.region
      point_in_time_recovery_enabled = false
      backup_retention_settings = [
        {
          retained_backups = 30
          retention_unit   = "COUNT"
        }
      ]
    }
  ]
  database_flags = [
    {
      name  = "general_log"
      value = "on"
    },
    {
      name  = "log_queries_not_using_indexes"
      value = "on"
    },
    {
      name  = "max_connections"
      value = "1000"
    },
    {
      name  = "skip_show_database"
      value = "on"
    },
    {
      name  = "slow_query_log"
      value = "on"
    },
    {
      name  = "long_query_time"
      value = "2"
    },
    {
      name  = "log_output"
      value = "FILE"
    },
    {
      name  = "binlog_expire_logs_seconds"
      value = "86400"
    },
    {
      name  = "binlog_row_image"
      value = "full"
    }
  ]
  vpc_self_link = module.vpc.self_link
  vpc_id        = module.vpc.vpc_id
  password      = module.sql_password_secret.secret_data
  depends_on    = [module.sql_password_secret]
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

module "sql_proxy" {
  source                    = "./modules/compute"
  name                      = "datastream-sql-proxy"
  machine_type              = "e2-micro"
  zone                      = "${var.region}-a"
  metadata_startup_script   = <<-EOT
    #!/bin/bash
    apt-get update && apt-get install -y socat
    socat TCP-LISTEN:3306,fork,reuseaddr TCP:${module.mysql.db_ip_address}:3306 &
  EOT
  deletion_protection       = false
  allow_stopping_for_update = true
  image                     = "debian-cloud/debian-12"
  network_interfaces = [
    {
      network        = "${module.vpc.vpc_id}"
      subnetwork     = "${module.vpc.subnets[1].id}"
      access_configs = []
    }
  ]
  tags = ["datastream-sql-proxy"]
}

# --------------------------------------------------------------------------
# Datastream configuration (CDC)
# --------------------------------------------------------------------------
resource "google_datastream_private_connection" "private_connection" {
  display_name          = "datastream-private-connection"
  location              = var.region
  private_connection_id = "datastream-private-connection"

  vpc_peering_config {
    vpc    = module.vpc.vpc_id
    subnet = "10.99.0.0/29"
  }
}

resource "google_compute_network_peering_routes_config" "sql_peering_routes" {
  peering              = module.mysql.private_vpc_connection_peering
  network              = "vpc"
  export_custom_routes = true
  import_custom_routes = false

  depends_on = [module.mysql]
}

resource "google_datastream_connection_profile" "source_connection_profile" {
  display_name          = "Source connection profile"
  location              = var.region
  connection_profile_id = "source-profile"

  mysql_profile {
    hostname = module.sql_proxy.network_ip
    port     = 3306
    username = "mohit"
    password = module.sql_password_secret.secret_data
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
  stream_id    = "db-stream"
  location     = var.region
  display_name = "db-stream"

  # Start with PAUSED state for initial validation
  desired_state = "RUNNING"

  source_config {
    source_connection_profile = google_datastream_connection_profile.source_connection_profile.id

    mysql_source_config {
      # Allow Datastream to discover schema automatically
      include_objects {
        mysql_databases {
          database = "mysql-${random_id.sql_suffix.hex}"
          mysql_tables {
            table = "users"
            # Remove explicit column definitions - let Datastream discover them
          }
        }
      }

      # Configure binary log settings
      max_concurrent_cdc_tasks      = 1
      max_concurrent_backfill_tasks = 1
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.destination_connection_profile.id

    bigquery_destination_config {
      source_hierarchy_datasets {
        dataset_template {
          location          = var.region
          dataset_id_prefix = "dp"
        }
      }

      # Add data freshness configuration
      data_freshness = "900s" # 15 minutes
    }
  }

  # Use backfill_all for initial data load
  backfill_all {}
  depends_on = [
    google_datastream_connection_profile.source_connection_profile,
    google_datastream_connection_profile.destination_connection_profile,
    module.mysql
  ]
}