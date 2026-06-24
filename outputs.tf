output "service_project_number" {
  description = "The numeric id of the service project; service-agent emails are derived from it."
  value       = data.google_project.service_project.number
}

output "service_networking_agent" {
  description = "The Cloud SQL service-networking agent email that was granted the service-agent role."
  value       = google_project_service_identity.servicenetworking.email
}

output "gcs_service_account" {
  description = "The GCS service agent email granted KMS encrypt/decrypt (empty when kms_key_id is unset)."
  value       = local.manage_kms == 1 ? data.google_storage_project_service_account.gcs[0].email_address : ""
}
