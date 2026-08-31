locals {
  labels = merge(
    {
      managed-by = "terraform"
      module     = "datastream-mysql-to-bq"
    },
    var.labels,
  )

  mysql_password = (
    var.mysql_password_secret_id != null
    ? data.google_secret_manager_secret_version.mysql_password[0].secret_data
    : var.mysql_password
  )
}

# Fails the plan with a clear message instead of a confusing provider error
# if neither password source was configured.
check "mysql_password_provided" {
  assert {
    condition     = var.mysql_password != null || var.mysql_password_secret_id != null
    error_message = "Set exactly one of var.mysql_password or var.mysql_password_secret_id."
  }
}

data "google_secret_manager_secret_version" "mysql_password" {
  count   = var.mysql_password_secret_id != null ? 1 : 0
  project = var.project_id
  secret  = var.mysql_password_secret_id
}

############################
# Private connectivity
############################

resource "google_datastream_private_connection" "this" {
  project               = var.project_id
  display_name          = var.private_connection_display_name
  location              = var.region
  private_connection_id = var.private_connection_id
  labels                = local.labels

  vpc_peering_config {
    vpc    = var.vpc_id
    subnet = var.private_connection_subnet
  }
}

resource "google_compute_network_peering_routes_config" "sql_peering_routes" {
  project = var.project_id
  peering = var.private_vpc_connection_peering
  network = var.network_name

  export_custom_routes = var.export_custom_routes
  import_custom_routes = var.import_custom_routes

  # Ordering comes implicitly from private_vpc_connection_peering being
  # derived from the caller's Service Networking connection output, plus
  # this explicit dependency on the private connection that rides on it.
  depends_on = [google_datastream_private_connection.this]
}

############################
# Connection profiles
############################

resource "google_datastream_connection_profile" "source" {
  project                = var.project_id
  display_name           = var.source_profile_display_name
  location                = var.region
  connection_profile_id  = var.source_profile_id
  labels                 = local.labels

  mysql_profile {
    hostname = var.mysql_hostname
    port     = var.mysql_port
    username = var.mysql_username
    password = local.mysql_password

    dynamic "ssl_config" {
      for_each = var.mysql_ssl_config != null ? [var.mysql_ssl_config] : []
      content {
        client_certificate = ssl_config.value.client_certificate
        client_key          = ssl_config.value.client_key
        ca_certificate       = ssl_config.value.ca_certificate
      }
    }
  }

  private_connectivity {
    private_connection = google_datastream_private_connection.this.id
  }

  depends_on = [google_compute_network_peering_routes_config.sql_peering_routes]
}

resource "google_datastream_connection_profile" "destination" {
  project                = var.project_id
  display_name           = var.destination_profile_display_name
  location                = var.region
  connection_profile_id  = var.destination_profile_id
  labels                 = local.labels

  bigquery_profile {}
}

############################
# Stream
############################

resource "google_datastream_stream" "this" {
  project       = var.project_id
  stream_id     = var.stream_id
  location      = var.region
  display_name  = var.stream_display_name
  labels        = local.labels
  desired_state = var.desired_state

  source_config {
    source_connection_profile = google_datastream_connection_profile.source.id

    mysql_source_config {
      max_concurrent_cdc_tasks      = var.mysql_source_config.max_concurrent_cdc_tasks
      max_concurrent_backfill_tasks = var.mysql_source_config.max_concurrent_backfill_tasks

      include_objects {
        dynamic "mysql_databases" {
          for_each = var.mysql_source_config.include_objects
          content {
            database = mysql_databases.value.database

            dynamic "mysql_tables" {
              for_each = mysql_databases.value.tables
              content {
                table = mysql_tables.value.table

                dynamic "mysql_columns" {
                  for_each = coalesce(mysql_tables.value.columns, [])
                  content {
                    column = mysql_columns.value
                  }
                }
              }
            }
          }
        }
      }

      dynamic "exclude_objects" {
        for_each = length(var.mysql_source_config.exclude_objects) > 0 ? [1] : []
        content {
          dynamic "mysql_databases" {
            for_each = var.mysql_source_config.exclude_objects
            content {
              database = mysql_databases.value.database

              dynamic "mysql_tables" {
                for_each = mysql_databases.value.tables
                content {
                  table = mysql_tables.value.table
                }
              }
            }
          }
        }
      }
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.destination.id

    bigquery_destination_config {
      data_freshness = var.bigquery_data_freshness

      dynamic "single_target_dataset" {
        for_each = var.bigquery_dataset_id != null ? [var.bigquery_dataset_id] : []
        content {
          dataset_id = single_target_dataset.value
        }
      }

      dynamic "source_hierarchy_datasets" {
        for_each = var.bigquery_dataset_id == null ? [1] : []
        content {
          dataset_template {
            location          = coalesce(var.bigquery_dataset_location, var.region)
            dataset_id_prefix = var.bigquery_dataset_id_prefix
          }
        }
      }
    }
  }

  dynamic "backfill_all" {
    for_each = var.backfill_strategy == "all" ? [1] : []
    content {}
  }

  dynamic "backfill_none" {
    for_each = var.backfill_strategy == "none" ? [1] : []
    content {}
  }

  lifecycle {
    # See var.ignore_desired_state_changes docs.
    ignore_changes = var.ignore_desired_state_changes ? [desired_state] : []
  }

  depends_on = [
    google_datastream_connection_profile.source,
    google_datastream_connection_profile.destination,
  ]
}