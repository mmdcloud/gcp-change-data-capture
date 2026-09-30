variable "dataset_id" {}
variable "location" {}
variable "description" {}
variable "tables" {
  type = list(object({
    table_id            = string
    schema              = string
    deletion_protection = bool
    time_partitioning = object({
      field = string
      type  = string
    })
  }))
}