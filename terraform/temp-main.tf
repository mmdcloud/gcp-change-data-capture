resource "google_sql_database_instance" "instance" {
  name             = "my-instance"
  database_version = "MYSQL_8_0"
  region           = "us-central1"
  settings {
    tier = "db-f1-micro"
    backup_configuration {
      enabled            = true
      binary_log_enabled = true
    }

    ip_configuration {

      // Datastream IPs will vary by region.
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

  deletion_protection = true
}

resource "google_sql_database" "db" {
  instance = google_sql_database_instance.instance.name
  name     = "db"
}

resource "google_sql_user" "user" {
  name     = "mohit"
  instance = google_sql_database_instance.instance.name
  host     = "%"
  password = "12345678"
}

resource "google_datastream_connection_profile" "source_connection_profile" {
  display_name          = "Source connection profile"
  location              = "us-central1"
  connection_profile_id = "source-profile"

  mysql_profile {
    hostname = google_sql_database_instance.instance.public_ip_address
    username = google_sql_user.user.name
    password = google_sql_user.user.password
  }
}

resource "google_datastream_connection_profile" "destination_connection_profile" {
  display_name          = "Connection profile"
  location              = "us-central1"
  connection_profile_id = "destination-profile"

  bigquery_profile {}
}

resource "google_datastream_stream" "default" {
  stream_id    = "my-stream"
  location     = "us-central1"
  display_name = "my stream"
  source_config {
    source_connection_profile = google_datastream_connection_profile.source_connection_profile.id
    mysql_source_config {}
  }
  destination_config {
    destination_connection_profile = google_datastream_connection_profile.destination_connection_profile.id
    bigquery_destination_config {
      source_hierarchy_datasets {
        dataset_template {
          location = "us-central1"
        }
      }
    }
  }

  backfill_none {
  }
}
