output "tables" {
  value = google_bigquery_table.table[*]
}