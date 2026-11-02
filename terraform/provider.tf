terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
  # backend "gcs" {}
}

provider "google" {
  project = "encoded-alpha-457108-e8"
  region  = "us-central1"
}

provider "google-beta" {
  project = "encoded-alpha-457108-e8"
  region  = "us-central1"
}
