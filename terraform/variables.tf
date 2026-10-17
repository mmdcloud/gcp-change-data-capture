############################################################
# Global / project
############################################################

variable "project_id" {
  description = "GCP project ID that all resources are created in."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources (Cloud SQL, VPC subnets, Datastream, compute zone base)."
  type        = string
}

variable "environment" {
  description = "Environment name used for naming/labeling (e.g. dev, staging, prod)."
  type        = string
  default     = "prod"
}

variable "labels" {
  description = "Common labels applied to resources that accept labels (e.g. the sql-proxy boot disk)."
  type        = map(string)
  default     = {}
}

############################################################
# Vault-backed secrets
############################################################

variable "vault_secret_path" {
  description = "Vault path holding the MySQL credentials (expects a 'password' key, and ideally distinct paths per credential in production)."
  type        = string
  default     = "secret/sql"
}

variable "db_password_secret_id" {
  description = "Secret Manager secret ID for the Cloud SQL root/admin password."
  type        = string
  default     = "db_password_secret"
}

variable "datastream_reader_secret_id" {
  description = "Secret Manager secret ID for the dedicated datastream_reader MySQL user's password."
  type        = string
  default     = "datastream_reader_password_secret"
}

############################################################
# VPC
############################################################

variable "vpc_name" {
  description = "Name of the VPC network."
  type        = string
  default     = "vpc"
}

variable "vpc_subnet_name" {
  description = "Name of the primary private subnet."
  type        = string
  default     = "vpc-subnet"
}

variable "vpc_subnet_cidr" {
  description = "CIDR range for the primary private subnet."
  type        = string
  default     = "10.0.0.0/16"
}

variable "psc_subnet_name" {
  description = "Name of the subnet hosting the Datastream SQL proxy VM."
  type        = string
  default     = "datastream-psc-subnet"
}

variable "protect_resources" {
  type    = bool
  default = true
}

variable "psc_subnet_cidr" {
  description = "CIDR range for the proxy VM subnet."
  type        = string
  default     = "10.10.0.0/24" # Important : should not be 10.1.0.0/16 and 10.2.2.0/24 because these are reserved for datastream internal ranges
}

############################################################
# Cloud SQL (MySQL)
############################################################
variable "db_name" {
  type    = string
  default = "db"
}

variable "db_instance_name_prefix" {
  description = "Prefix for the Cloud SQL instance/database name; a random suffix is appended."
  type        = string
  default     = "mysql"
}

variable "db_admin_username" {
  description = "Root/admin username for the Cloud SQL instance."
  type        = string
  default     = "app_admin"
}

variable "db_version" {
  description = "Cloud SQL database engine and version."
  type        = string
  default     = "MYSQL_8_0"
}

variable "db_tier" {
  description = "Machine tier for the Cloud SQL instance."
  type        = string
  default     = "db-custom-2-8192"
}

variable "db_availability_type" {
  description = "Cloud SQL availability type."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.db_availability_type)
    error_message = "db_availability_type must be either \"ZONAL\" or \"REGIONAL\"."
  }
}

variable "db_disk_size_gb" {
  description = "Initial disk size, in GB, for the Cloud SQL instance."
  type        = number
  default     = 100
}

variable "db_disk_type" {
  description = "Disk type for the Cloud SQL instance."
  type        = string
  default     = "PD_SSD"

  validation {
    condition     = contains(["PD_SSD", "PD_HDD"], var.db_disk_type)
    error_message = "db_disk_type must be either \"PD_SSD\" or \"PD_HDD\"."
  }
}

variable "db_disk_autoresize" {
  description = "Whether to enable automatic disk growth for the Cloud SQL instance."
  type        = bool
  default     = true
}

variable "db_disk_autoresize_limit_gb" {
  description = "Maximum size, in GB, the Cloud SQL disk can auto-grow to. 0 means no limit."
  type        = number
  default     = 500
}

variable "db_ipv4_enabled" {
  description = "Whether the Cloud SQL instance is assigned a public IPv4 address."
  type        = bool
  default     = false
}

variable "db_backup_start_time" {
  description = "Start time (HH:MM, UTC) for the daily automated backup window."
  type        = string
  default     = "03:00"
}

variable "db_backup_retained_count" {
  description = "Number of automated backups to retain."
  type        = number
  default     = 30
}

variable "db_max_connections" {
  type    = number
  default = 1000
}

variable "db_database_flags" {
  description = "Cloud SQL database flags to set on the instance."
  type = list(object({
    name  = string
    value = string
  }))
  default = [
    { name = "general_log", value = "off" },
    { name = "log_queries_not_using_indexes", value = "on" },
    { name = "skip_show_database", value = "on" },
    { name = "slow_query_log", value = "on" },
    { name = "long_query_time", value = "2" },
    { name = "log_output", value = "FILE" },
    { name = "binlog_expire_logs_seconds", value = "604800" },
    { name = "binlog_row_image", value = "full" },
  ]
}

############################################################
# Datastream SQL proxy VM
############################################################
variable "sql_port" {
  description = "TCP port the proxy listens on and forwards to Cloud SQL. Must match db_port."
  type        = number
  default     = 3306
}

############################################################
# Datastream
############################################################

variable "datastream_stream_id" {
  description = "Resource ID for the Datastream stream."
  type        = string
  default     = "db-stream"
}

variable "datastream_display_name" {
  description = "Display name for the Datastream stream."
  type        = string
  default     = "db-stream"
}

variable "datastream_desired_state" {
  description = "Desired state of the Datastream stream."
  type        = string
  default     = "RUNNING"

  validation {
    condition     = contains(["RUNNING", "PAUSED", "NOT_STARTED"], var.datastream_desired_state)
    error_message = "datastream_desired_state must be one of RUNNING, PAUSED, NOT_STARTED."
  }
}

variable "datastream_tables" {
  description = "List of table names in the source database to include in the stream."
  type        = list(string)
  default     = ["users"]
}

variable "datastream_max_concurrent_cdc_tasks" {
  description = "Maximum number of concurrent CDC (change data capture) tasks."
  type        = number
  default     = 1
}

variable "datastream_max_concurrent_backfill_tasks" {
  description = "Maximum number of concurrent backfill tasks."
  type        = number
  default     = 1
}

variable "datastream_bq_dataset_id_prefix" {
  description = "Prefix applied to the BigQuery dataset(s) Datastream creates per source database."
  type        = string
  default     = "dp"
}

variable "datastream_data_freshness" {
  description = "Data freshness SLA for the BigQuery destination, as a duration string (e.g. \"900s\")."
  type        = string
  default     = "900s"
}

variable "notification_channels" {
  type    = list(string)
  default = []
}

variable "run_grant_script" {
  description = "Whether to run the datastream reader grant script."
  type        = bool
  default     = false
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "vault_datastream_reader_secret_path" {
  type    = string
  default = "secret/datastream_reader"
}

variable "grants_applied" {
  description = "Set true once datastream_reader has replication grants (script run manually)."
  type        = bool
  default     = false
}