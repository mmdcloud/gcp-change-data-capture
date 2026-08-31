output "private_connection_id" {
  description = "Fully qualified ID of the Datastream private connection."
  value       = google_datastream_private_connection.this.id
}

output "private_connection_state" {
  description = "Current state reported by the Datastream private connection (e.g. CREATED, CREATING, FAILED)."
  value       = google_datastream_private_connection.this.state
}

output "source_connection_profile_id" {
  description = "Fully qualified ID of the MySQL source connection profile."
  value       = google_datastream_connection_profile.source.id
}

output "destination_connection_profile_id" {
  description = "Fully qualified ID of the BigQuery destination connection profile."
  value       = google_datastream_connection_profile.destination.id
}

output "stream_id" {
  description = "Fully qualified ID of the Datastream stream."
  value       = google_datastream_stream.this.id
}

output "stream_name" {
  description = "Short stream_id as configured."
  value       = google_datastream_stream.this.stream_id
}

output "stream_state" {
  description = "Actual runtime state of the stream as reported by the API (distinct from desired_state)."
  value       = google_datastream_stream.this.state
}