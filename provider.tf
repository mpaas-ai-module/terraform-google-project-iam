terraform {
  required_version = ">=0.13"

  required_providers {
    google = {
      version = "~> 6.41.0" # PoC fork: standardized (matches sibling modules)
      source  = "hashicorp/google"
    }
  }
}
