############################
# General
############################

variable "project_id" {
  description = "Project to create resources in. Leave null to use the provider's default project."
  type        = string
  default     = null
}

variable "region" {
  description = "Region for the Datastream resources (private connection, connection profiles, stream)."
  type        = string
}

variable "labels" {
  description = "Labels applied to all Datastream resources created by this module."
  type        = map(string)
  default     = {}
}

############################
# Networking / private connectivity
############################

variable "vpc_id" {
  description = "Self link or ID of the VPC network Datastream will peer with (google_compute_network.self_link / id)."
  type        = string
}

variable "network_name" {
  description = "Name (not self link) of the VPC network, used for the network peering routes config."
  type        = string
}

variable "private_vpc_connection_peering" {
  description = "Name of the existing VPC Service Networking peering connection (e.g. output of google_service_networking_connection.<name>.peering) that Datastream's reverse peering rides on."
  type        = string
}

variable "private_connection_id" {
  description = "Resource ID for the Datastream private connection."
  type        = string
  default     = "datastream-private-connection"
}

variable "private_connection_display_name" {
  description = "Display name for the Datastream private connection."
  type        = string
  default     = "datastream-private-connection"
}

variable "private_connection_subnet" {
  description = "Reserved CIDR range Datastream uses for VPC peering. Must be unused elsewhere in the VPC and at least a /29."
  type        = string
  default     = "10.99.0.0/29"

  validation {
    condition     = can(cidrhost(var.private_connection_subnet, 0)) && tonumber(split("/", var.private_connection_subnet)[1]) <= 29
    error_message = "private_connection_subnet must be a valid CIDR block with a prefix length of /29 or larger (e.g. 10.99.0.0/29)."
  }
}

variable "export_custom_routes" {
  description = "Whether the peering exports custom routes to the Datastream side. Usually required so Datastream can reach the MySQL private IP."
  type        = bool
  default     = true
}

variable "import_custom_routes" {
  description = "Whether the peering imports custom routes from the Datastream side."
  type        = bool
  default     = false
}

############################
# MySQL source
############################

variable "mysql_hostname" {
  description = "Private IP or hostname of the MySQL source (e.g. Cloud SQL private IP, or a proxy in front of it)."
  type        = string
}

variable "mysql_port" {
  description = "MySQL port."
  type        = number
  default     = 3306
}

variable "mysql_username" {
  description = "MySQL username Datastream connects as. Grant it REPLICATION SLAVE, REPLICATION CLIENT, SELECT on the relevant schemas."
  type        = string
}

variable "mysql_password" {
  description = "MySQL password. Prefer mysql_password_secret_id instead; set exactly one of the two."
  type        = string
  sensitive   = true
  default     = null
}

variable "mysql_password_secret_id" {
  description = "Full Secret Manager secret version resource ID (e.g. projects/PROJECT/secrets/NAME/versions/latest) holding the MySQL password. Takes precedence over mysql_password when set."
  type        = string
  default     = null
}

variable "mysql_ssl_config" {
  description = "Optional TLS config for the MySQL connection. Leave null to connect without client TLS."
  type = object({
    client_certificate = optional(string)
    client_key          = optional(string)
    ca_certificate       = optional(string)
  })
  default   = null
  sensitive = true
}

variable "mysql_source_config" {
  description = <<-EOT
    Objects to replicate and CDC/backfill concurrency. `include_objects` is required (Datastream
    needs an explicit allow-list); `exclude_objects` is optional and layered on top of it.
    Leave a table's `columns` null to let Datastream discover the schema automatically.
  EOT
  type = object({
    max_concurrent_cdc_tasks      = optional(number, 5)
    max_concurrent_backfill_tasks = optional(number, 10)
    include_objects = list(object({
      database = string
      tables = optional(list(object({
        table   = string
        columns = optional(list(string))
      })), [])
    }))
    exclude_objects = optional(list(object({
      database = string
      tables = optional(list(object({
        table = string
      })), [])
    })), [])
  })

  validation {
    condition     = length(var.mysql_source_config.include_objects) > 0
    error_message = "mysql_source_config.include_objects must list at least one database to replicate."
  }
}

############################
# Connection profiles
############################

variable "source_profile_id" {
  type    = string
  default = "source-profile"
}

variable "source_profile_display_name" {
  type    = string
  default = "Source connection profile"
}

variable "destination_profile_id" {
  type    = string
  default = "destination-profile"
}

variable "destination_profile_display_name" {
  type    = string
  default = "Destination connection profile"
}

############################
# Stream
############################

variable "stream_id" {
  type    = string
  default = "db-stream"
}

variable "stream_display_name" {
  type    = string
  default = "db-stream"
}

variable "desired_state" {
  description = "RUNNING, PAUSED, or NOT_STARTED. Recommend creating PAUSED, validating, then flipping to RUNNING."
  type        = string
  default     = "PAUSED"

  validation {
    condition     = contains(["RUNNING", "PAUSED", "NOT_STARTED"], var.desired_state)
    error_message = "desired_state must be one of RUNNING, PAUSED, NOT_STARTED."
  }
}

variable "ignore_desired_state_changes" {
  description = "If true, Terraform stops managing desired_state after creation (recommended, so pausing/resuming via console or gcloud during operations doesn't get reverted on the next apply). Set false if Terraform should always enforce desired_state."
  type        = bool
  default     = true
}

variable "backfill_strategy" {
  description = "\"all\" backfills every included table on stream creation, \"none\" starts CDC-only from the current position."
  type        = string
  default     = "all"

  validation {
    condition     = contains(["all", "none"], var.backfill_strategy)
    error_message = "backfill_strategy must be \"all\" or \"none\"."
  }
}

############################
# BigQuery destination
############################

variable "bigquery_dataset_location" {
  description = "Location for generated BigQuery datasets. Defaults to var.region when null."
  type        = string
  default     = null
}

variable "bigquery_dataset_id_prefix" {
  description = "Prefix used when Datastream creates one dataset per source database (ignored if bigquery_dataset_id is set)."
  type        = string
  default     = "dp"
}

variable "bigquery_dataset_id" {
  description = "If set, all replicated tables land in this single existing/target dataset instead of one dataset per source database."
  type        = string
  default     = null
}

variable "bigquery_data_freshness" {
  description = "Max data staleness before Datastream merges staged rows into BigQuery tables, as a duration string (e.g. \"900s\")."
  type        = string
  default     = "900s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.bigquery_data_freshness))
    error_message = "bigquery_data_freshness must be a duration string in seconds, e.g. \"900s\"."
  }
}