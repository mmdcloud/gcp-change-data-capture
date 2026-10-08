resource "google_bigquery_dataset" "dataset" {
  dataset_id  = var.dataset_id
  location    = var.location
  description = var.description
}

resource "google_bigquery_table" "table" {
  count      = length(var.tables)
  table_id   = var.tables[count.index].table_id
  dataset_id = google_bigquery_dataset.dataset.dataset_id

  dynamic "time_partitioning" {
    for_each = var.tables[count.index].time_partitioning != null ? [var.tables[count.index].time_partitioning] : []
    content {
      field = time_partitioning.value.field
      type  = time_partitioning.value.type
    }
  }

  schema = var.tables[count.index].schema

  deletion_protection = var.tables[count.index].deletion_protection
}
