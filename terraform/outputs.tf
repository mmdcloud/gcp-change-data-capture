output "sql_instance_connection_name" {
  value = module.mysql.db_connection_name
}

output "sql_instance_private_ip" {
  value       = try(module.mysql.db_ip_address, null)
  description = "Null when enable_private_ip = true"
}

output "datastream_stream_id" {
  value = google_datastream_stream.stream.id
}

output "datastream_stream_state" {
  value = google_datastream_stream.stream.state
}
