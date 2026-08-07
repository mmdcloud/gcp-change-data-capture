output "sql_instance_connection_name" {
  value = google_sql_database_instance.mysql.connection_name
}

output "sql_instance_public_ip" {
  value       = try(google_sql_database_instance.mysql.public_ip_address, null)
  description = "Null when enable_private_ip = true"
}

output "sql_instance_private_ip" {
  value       = try(google_sql_database_instance.mysql.private_ip_address, null)
  description = "Null unless enable_private_ip = true and a private_network is attached"
}

output "datastream_stream_id" {
  value = google_datastream_stream.stream.id
}

output "datastream_stream_state" {
  value = google_datastream_stream.stream.state
}