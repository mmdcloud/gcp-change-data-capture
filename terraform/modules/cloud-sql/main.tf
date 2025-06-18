resource "google_sql_database_instance" "mysql" {
  name             = "mysql"
  root_password    = "12345678"
  database_version = "MYSQL_8_0"
  region           = var.region

  settings {
    tier              = "db-f1-micro"
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"

    data_cache_config {
      data_cache_enabled = false
    }

    disk_size = 10

    insights_config {
      query_insights_enabled = false
    }

    deletion_protection_enabled = false

    backup_configuration {
      enabled                        = true
      binary_log_enabled             = true
      start_time                     = "02:00"
      transaction_log_retention_days = 7
    }

    ip_configuration {
      ipv4_enabled = true
      # Add Datastream service IPs for your region
      authorized_networks {
        value = "34.71.242.81"
      }
      authorized_networks {
        value = "34.72.28.29"
      }
      authorized_networks {
        value = "34.67.6.157"
      }
      authorized_networks {
        value = "34.67.234.134"
      }
      authorized_networks {
        value = "34.72.239.218"
      }
    }
  }

  deletion_protection = false
}