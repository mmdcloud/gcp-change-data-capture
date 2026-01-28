output "db_public_ip_address" {
  value = google_sql_database_instance.mysql.public_ip_address
}

output "db_private_ip_address" {
  value = google_sql_database_instance.mysql.private_ip_address
}