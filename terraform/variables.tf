variable "region" {
  type = string
}

variable "project_id" {
  type = string
}

variable "image_family" {
  description = "Source image family for compute instances."
  type        = string
  default     = "ubuntu-2404-lts-amd64"
}

variable "image_project" {
  description = "Project that owns the source image family."
  type        = string
  default     = "ubuntu-os-cloud"
}

variable "instance_boot_disk_size_gb" {
  description = "Boot disk size (GB) for the consumer compute instance."
  type        = number
  default     = 10
}

variable "instance_boot_disk_type" {
  description = "Boot disk type for the consumer compute instance."
  type        = string
  default     = "pd-ssd"
}

variable "labels" {
  description = "Resource labels applied to the consumer instance and its boot disk."
  type        = map(string)
  default = {
    environment = "production"
    team        = "platform-eng"
    cost_center = "cc-1042"
  }
}
