// required variables
variable "project_id" {
  type        = string
  description = "The service project id. Service-agent emails are derived from this project's number, so the role grants below land on the correct agents."
}

// optional variables
variable "host_project_id" {
  type        = string
  description = "The shared-VPC host project id. Only used when grant_host_project_iam is true (Cloud Run VPC connector + Cloud SQL private-IP service networking live in the host project)."
  default     = ""
}

variable "grant_host_project_iam" {
  type        = bool
  description = "When true, emit the cross-project IAM bindings on the host project (roles/vpcaccess.user for the Cloud Run + Serverless-VPC agents, network roles for the service-networking agent). Set false when the deploying SA lacks IAM-admin on the host project — those grants are then a one-time platform prerequisite."
  default     = false
}

variable "manage_cloudsql_sn" {
  type        = bool
  description = "Emit the service-networking agent grants (consumer + host) needed by private-IP services (Cloud SQL, Memorystore Redis, Filestore). The platform sets this true only when such a service is in the architecture. Default true keeps backward-compatible behavior when unset."
  default     = true
}

variable "manage_cloudrun_vpc" {
  type        = bool
  description = "Emit the host-project roles/vpcaccess.user grants needed by Cloud Run with a host VPC connector. The platform sets this true only when Cloud Run is in the architecture. Default true keeps backward-compatible behavior when unset."
  default     = true
}

variable "kms_key_id" {
  type        = string
  description = "Full crypto-key id (…/keyRings/<ring>/cryptoKeys/<key>) used for CMEK. When set, the GCS service agent is granted encrypt/decrypt on it so CMEK buckets can be created on a brand-new project. Leave empty to skip."
  default     = ""
}

variable "gcs_sa_propagation_seconds" {
  type        = string
  description = "Delay between materializing the GCS service agent and granting it the KMS role. Avoids the 'service account does not exist' race on fresh projects."
  default     = "45s"
}

variable "iam_propagation_seconds" {
  type        = string
  description = "How long consumers (via depends_on = [module.project_iam]) wait after the service-agent grants are written, so cross-project IAM has time to propagate before the connector/private-IP/CMEK resource is created."
  default     = "90s"
}
