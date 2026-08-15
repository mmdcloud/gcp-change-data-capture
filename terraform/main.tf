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
# module "mysql" {
#   source = "./modules/cloudsql-sql"

#   project_id    = var.project_id
#   region        = var.region
#   instance_name = "encodedmadmaxcloudsql"

#   tier              = "db-f1-micro"
#   edition           = "ENTERPRISE"
#   availability_type = "ZONAL"
#   disk_size         = 10

#   # Public IP + Datastream authorized networks, same as the original.
#   ipv4_enabled = true
#   authorized_networks = [
#     { name = "datastream-1", value = "34.71.242.81" },
#     { name = "datastream-2", value = "34.72.28.29" },
#     { name = "datastream-3", value = "34.67.6.157" },
#     { name = "datastream-4", value = "34.67.234.134" },
#     { name = "datastream-5", value = "34.72.239.218" },
#   ]

#   backup_enabled                 = true
#   binary_log_enabled             = true
#   backup_start_time              = "02:00"
#   transaction_log_retention_days = 7

#   # Original had this off; module defaults it on since query insights are
#   # essentially free and valuable for prod debugging. Uncomment to match
#   # the original behavior exactly:
#   # query_insights_enabled = false

#   databases = ["db"]

#   users = {
#     mohit = {
#       host = "%"
#       # password omitted -> randomly generated, returned in outputs
#     }
#   }

#   # Prod default is true; the original set this false, so we override
#   # explicitly here to preserve the same behavior.
#   deletion_protection = false

#   store_passwords_in_secret_manager = true
# }

resource "google_compute_global_address" "private_ip_alloc" {
  name          = "sql-private-ip-alloc"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = module.vpc.vpc_id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = module.vpc.vpc_id
  service                 = "servicenetworking.googleapis.com"
  update_on_creation_fail = true
  deletion_policy         = "ABANDON"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}

resource "google_sql_database_instance" "mysql" {
  name             = "mysql-${random_id.sql_suffix.hex}"
  root_password    = module.sql_password_secret.secret_data
  database_version = "MYSQL_8_0"
  region           = var.region

  settings {
    tier              = "db-f1-micro"
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"

    data_cache_config {
      data_cache_enabled = false
    }

    disk_size       = 10
    disk_type       = "PD_SSD"
    disk_autoresize = true

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = false
    }

    backup_configuration {
      enabled                        = true
      binary_log_enabled             = true
      start_time                     = "02:00"
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 3
      update_track = "stable"
    }

    database_flags {
      name  = "binlog_row_image"
      value = "full"
    }

    database_flags {
      name  = "binlog_expire_logs_seconds"
      value = "86400" # keep binlogs >= 1 day so backfill/CDC never stalls on purge
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = module.vpc.vpc_id

      # authorized_networks {
      #   value = "34.71.242.81"
      # }
      # authorized_networks {
      #   value = "34.72.28.29"
      # }
      # authorized_networks {
      #   value = "34.67.6.157"
      # }
      # authorized_networks {
      #   value = "34.67.234.134"
      # }
      # authorized_networks {
      #   value = "34.72.239.218"
      # }
    }
  }

  deletion_protection = false

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

resource "google_sql_database" "db" {
  instance = google_sql_database_instance.mysql.name
  name     = "db"
}

resource "google_sql_user" "user" {
  name     = "mohit"
  instance = google_sql_database_instance.mysql.name
  host     = "%"
  password = module.sql_password_secret.secret_data
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
    socat TCP-LISTEN:3306,fork,reuseaddr TCP:${google_sql_database_instance.mysql.private_ip_address}:3306 &
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
  peering              = google_service_networking_connection.private_vpc_connection.peering
  network              = "vpc"
  export_custom_routes = true
  import_custom_routes = false

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

resource "google_datastream_connection_profile" "source_connection_profile" {
  display_name          = "Source connection profile"
  location              = var.region
  connection_profile_id = "source-profile"

  mysql_profile {
    hostname = module.sql_proxy.network_ip
    port     = 3306
    username = google_sql_user.user.name
    password = google_sql_user.user.password
  }

  private_connectivity {
    private_connection = google_datastream_private_connection.private_connection.id
  }

  depends_on = [google_sql_database_instance.mysql]
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
          database = google_sql_database.db.name
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
    google_sql_database_instance.mysql
  ]
}