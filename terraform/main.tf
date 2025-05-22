# resource "google_sql_database_instance" "mysql" {
#   name             = "mysql"
#   root_password    = "12345678"
#   database_version = "MYSQL_8_0"
#   region           = var.region
#   settings {
#     tier              = "db-f1-micro"
#     edition           = "ENTERPRISE"
#     availability_type = "ZONAL"
#     data_cache_config {
#       data_cache_enabled = false
#     }
#     disk_size = 10
#     insights_config {
#       query_insights_enabled = false
#     }
#     deletion_protection_enabled = false
#     backup_configuration {
#       enabled            = true
#       binary_log_enabled = true
#     }

#     ip_configuration {

#       authorized_networks {
#         value = "34.71.242.81"
#       }

#       authorized_networks {
#         value = "34.72.28.29"
#       }

#       authorized_networks {
#         value = "34.67.6.157"
#       }

#       authorized_networks {
#         value = "34.67.234.134"
#       }

#       authorized_networks {
#         value = "34.72.239.218"
#       }
#     }
#   }

#   deletion_protection = false
# }

# resource "google_sql_database" "db" {
#   instance = google_sql_database_instance.mysql.name
#   name     = "demo"
# }

# resource "google_sql_user" "user" {
#   name     = "mohit"
#   instance = google_sql_database_instance.mysql.name
#   host     = "%"
#   password = "12345678"
# }

# resource "google_datastream_connection_profile" "source_connection_profile" {
#   display_name              = "Source connection profile"
#   create_without_validation = true
#   location                  = var.region
#   connection_profile_id     = "source-profile"
#   mysql_profile {
#     hostname = google_sql_database_instance.mysql.public_ip_address
#     username = google_sql_user.user.name
#     password = google_sql_user.user.password
#   }
# }

# data "google_bigquery_default_service_account" "bq_sa" {
# }

# # resource "google_kms_crypto_key_iam_member" "bigquery_key_user" {
# #   crypto_key_id = "bigquery-kms-name"
# #   role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
# #   member        = "serviceAccount:${data.google_bigquery_default_service_account.bq_sa.email}"
# # }

# resource "google_datastream_connection_profile" "destination_connection_profile" {
#   display_name              = "Destination connection profile"
#   location                  = var.region
#   connection_profile_id     = "destination-profile"
#   create_without_validation = true
#   bigquery_profile {

#   }
# }

# resource "google_datastream_stream" "default" {
#   stream_id     = "demo-stream"
#   desired_state = "RUNNING"
#   location      = var.region
#   backfill_none {

#   }
#   create_without_validation = true
#   display_name              = "demo-stream"

#   source_config {
#     source_connection_profile = google_datastream_connection_profile.source_connection_profile.id
#     mysql_source_config {
#       include_objects {
#         mysql_databases {
#           database = "demo"
#           mysql_tables {
#             table = "users"
#             mysql_columns {
#               column      = "id"
#               data_type   = "VARCHAR"
#               nullable    = false
#               primary_key = true
#             }
#             mysql_columns {
#               column      = "name"
#               data_type   = "VARCHAR"
#               nullable    = false
#               primary_key = false
#             }
#             mysql_columns {
#               column      = "email"
#               data_type   = "VARCHAR"
#               nullable    = false
#               primary_key = false
#             }
#             mysql_columns {
#               column      = "contact"
#               data_type   = "VARCHAR"
#               nullable    = false
#               primary_key = false
#             }
#           }
#         }
#       }
#     }
#   }
#   destination_config {
#     destination_connection_profile = google_datastream_connection_profile.destination_connection_profile.id
#     bigquery_destination_config {
#       source_hierarchy_datasets {
#         dataset_template {
#           location          = var.region
#           dataset_id_prefix = "dp"
#         }
#       }
#       data_freshness = "0s" 
#     }
#   }
#    backfill_all {}
# }

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

resource "google_sql_database" "db" {
  instance = google_sql_database_instance.mysql.name
  name     = "demo"
}

resource "google_sql_user" "user" {
  name     = "mohit"
  instance = google_sql_database_instance.mysql.name
  host     = "%"
  password = "12345678"
}

# Wait for the database instance to be ready
resource "time_sleep" "wait_for_db" {
  depends_on      = [google_sql_database_instance.mysql]
  create_duration = "60s"
}

resource "google_datastream_connection_profile" "source_connection_profile" {
  depends_on = [time_sleep.wait_for_db]

  display_name          = "Source connection profile"
  location              = var.region
  connection_profile_id = "source-profile"

  mysql_profile {
    hostname = google_sql_database_instance.mysql.public_ip_address
    port     = 3306
    username = google_sql_user.user.name
    password = google_sql_user.user.password
  }
}

data "google_bigquery_default_service_account" "bq_sa" {}

resource "google_datastream_connection_profile" "destination_connection_profile" {
  display_name          = "Destination connection profile"
  location              = var.region
  connection_profile_id = "destination-profile"

  bigquery_profile {}
}

# Create the target dataset first
resource "google_bigquery_dataset" "target_dataset" {
  dataset_id  = "dp_demo"
  location    = var.region
  description = "Dataset for Datastream replication"

  labels = {
    source = "datastream"
  }
}

resource "google_datastream_stream" "default" {
  depends_on = [
    google_datastream_connection_profile.source_connection_profile,
    google_datastream_connection_profile.destination_connection_profile,
    google_bigquery_dataset.target_dataset
  ]

  stream_id    = "demo-stream"
  location     = var.region
  display_name = "demo-stream"

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
}