output "db_user" {
  value = google_sql_user.db_user.name
}

output "db_password" {
  value = google_sql_user.db_user.password
}

output "db_ip_address" {
  value = google_sql_database_instance.db_instance.private_ip_address
}

output "db_name" {
  value = google_sql_database_instance.db_instance.name
}

output "db_connection_name" {
  value = google_sql_database_instance.db_instance.connection_name
}

output "psc_service_attachment_link" {
  value = google_sql_database_instance.db_instance.psc_service_attachment_link
}

output "private_vpc_connection_peering" {
  value = try(google_service_networking_connection.private_vpc_connection[0].peering, null)
}