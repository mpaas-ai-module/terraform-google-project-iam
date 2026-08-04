###############################################################################
# Project-level IAM / service-agent role grants.
#
# GCP-managed service agents (Cloud Run, Serverless-VPC, Cloud SQL service
# networking, GCS) are created lazily and start with NO roles. On a freshly
# created project in a shared-VPC + CMEK setup that produces these apply errors:
#
#   * Cloud Run  -> "service agent ... permission [vpcaccess.connectors.use]"
#   * Cloud SQL  -> "SN_SERVICE_AGENT_PERMISSION_DENIED_ON_CONSUMER_PROJECT"
#   * GCS bucket -> "Service account service-<num>@gs-project-accounts... does
#                    not exist" when granting the KMS encrypt/decrypt role
#
# This module materializes the relevant agents and grants them the roles they
# need. Consumer-project grants always apply; host-project grants are gated by
# var.grant_host_project_iam (the deploying SA may not own host-project IAM).
###############################################################################

data "google_project" "service_project" {
  project_id = var.project_id
}

locals {
  svc_number = data.google_project.service_project.number
  # Gate on the plan-known bool, NOT on kms_key_id: kms_key_id is wired to
  # module.kms.id (unknown until apply on a first apply), and a count cannot
  # depend on an apply-time value ("Invalid count argument").
  manage_kms = var.manage_kms ? 1 : 0

  # Per-concern gates. The platform sets manage_* from the architecture (only the
  # services actually present), and grant_host_project_iam from whether the
  # deploying SA owns host-project IAM. Host grants require BOTH.
  manage_sql     = var.manage_cloudsql_sn ? 1 : 0
  grant_host_sql = (var.grant_host_project_iam && var.manage_cloudsql_sn) ? 1 : 0
  grant_host_run = (var.grant_host_project_iam && var.manage_cloudrun_vpc) ? 1 : 0

  # Cloud SQL CMEK grant fires only when SQL is present AND a key is supplied.
  manage_sql_kms = (local.manage_sql == 1 && local.manage_kms == 1) ? 1 : 0
  # Any grant at all → emit a propagation barrier (see time_sleep below).
  any_grant = (local.manage_sql + local.manage_kms + local.grant_host_sql + local.grant_host_run) > 0 ? 1 : 0

  # Service-agent emails derived from the service project number.
  cloudrun_agent       = "serviceAccount:service-${local.svc_number}@serverless-robot-prod.iam.gserviceaccount.com"
  serverless_vpc_agent = "serviceAccount:service-${local.svc_number}@gcp-sa-vpcaccess.iam.gserviceaccount.com"
}

# ── Cloud SQL service-networking agent (consumer project) ────────────────────
# Materialize the agent and grant it the service-agent role on its OWN project.
# This is what clears SN_SERVICE_AGENT_PERMISSION_DENIED_ON_CONSUMER_PROJECT.
resource "google_project_service_identity" "servicenetworking" {
  provider = google-beta
  project  = var.project_id
  service  = "servicenetworking.googleapis.com"
}

resource "google_project_iam_member" "sql_servicenetworking_agent" {
  count   = local.manage_sql
  project = var.project_id
  role    = "roles/servicenetworking.serviceAgent"
  member  = "serviceAccount:${google_project_service_identity.servicenetworking.email}"
}

# ── GCS service agent -> KMS encrypt/decrypt (consumer project) ──────────────
# The data source materializes the GCS agent; time_sleep gives IAM time to
# propagate before the key-scoped grant, so the binding no longer fails with
# "service account does not exist" on a brand-new project.
data "google_storage_project_service_account" "gcs" {
  count   = local.manage_kms
  project = var.project_id
}

resource "time_sleep" "wait_gcs_sa" {
  count           = local.manage_kms
  depends_on      = [data.google_storage_project_service_account.gcs]
  create_duration = var.gcs_sa_propagation_seconds
}

resource "google_kms_crypto_key_iam_member" "gcs_kms" {
  count         = local.manage_kms
  crypto_key_id = var.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs[0].email_address}"
  depends_on    = [time_sleep.wait_gcs_sa]
}

# ── Cloud SQL service agent -> KMS encrypt/decrypt (consumer project) ─────────
# A CMEK Cloud SQL instance fails with "Insufficient permission to use KMS key"
# until the Cloud SQL service agent (service-<num>@gcp-sa-cloud-sql…) has
# encrypt/decrypt on the key. Materialize the agent, then grant it.
resource "google_project_service_identity" "cloudsql" {
  count    = local.manage_sql_kms
  provider = google-beta
  project  = var.project_id
  service  = "sqladmin.googleapis.com"
}

// var.kms_key_id already forces Terraform to create the KMS key before this
// grant is evaluated (it's wired to module.kms.id at the call site) — this is
// not a missing depends_on. The gap is GCP's own eventual consistency: the KMS
// API needs a moment after the key exists before GetIamPolicy reliably finds
// it. The trigger on kms_key_id keeps this sleep correctly ordered after the
// key is known while adding the propagation buffer the grant itself lacks.
resource "time_sleep" "wait_kms_key" {
  count           = local.manage_sql_kms
  create_duration = var.kms_key_propagation_seconds
  triggers = {
    kms_key_id = var.kms_key_id
  }
}

resource "google_kms_crypto_key_iam_member" "cloudsql_kms" {
  count         = local.manage_sql_kms
  crypto_key_id = var.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.cloudsql[0].email}"

  // gcs_kms is NOT an ordering nicety — it is required for correctness.
  //
  // This grant and gcs_kms write the SAME role on the SAME key. Every
  // google_kms_crypto_key_iam_member is a read-modify-write of that key's whole
  // IAM policy (GetIamPolicy -> append member -> SetIamPolicy), and with nothing
  // between them Terraform runs both concurrently. The two RMW cycles interleave,
  // the later SetIamPolicy is computed from a policy snapshot taken before the
  // other member was added, and one binding is silently lost. The provider then
  // re-reads the member it just wrote, cannot find it, and reports what looks
  // like a provider defect:
  //
  //   Error: Provider produced inconsistent result after apply
  //   ...google_kms_crypto_key_iam_member.cloudsql_kms[0]... produced an
  //   unexpected new value: Root object was present, but now absent.
  //
  // Serializing the two writers is the fix. time_sleep.wait_kms_key does NOT
  // achieve this: it is an independent timer keyed on kms_key_id, so both grants
  // can still be in flight at once. Do not drop gcs_kms from this list.
  depends_on = [
    time_sleep.wait_kms_key,
    google_kms_crypto_key_iam_member.gcs_kms,
  ]
}

# ── Host-project grants (shared VPC) — gated ─────────────────────────────────
# Cloud Run with a host-project VPC connector: both the Cloud Run service agent
# and the Serverless-VPC access agent need roles/vpcaccess.user on the host
# project. Clears "permission [vpcaccess.connectors.use]".
resource "google_project_iam_member" "cloudrun_vpcaccess" {
  count   = local.grant_host_run
  project = var.host_project_id
  role    = "roles/vpcaccess.user"
  member  = local.cloudrun_agent
}

resource "google_project_iam_member" "serverless_vpcaccess" {
  count   = local.grant_host_run
  project = var.host_project_id
  role    = "roles/vpcaccess.user"
  member  = local.serverless_vpc_agent
}

# Cloud SQL private-IP via host shared VPC: the service-networking agent needs
# the service-agent + network-user roles on the host project to manage the
# private-services-access peering.
resource "google_project_iam_member" "sn_host_servicenetworking" {
  count   = local.grant_host_sql
  project = var.host_project_id
  role    = "roles/servicenetworking.serviceAgent"
  member  = "serviceAccount:${google_project_service_identity.servicenetworking.email}"
}

resource "google_project_iam_member" "sn_host_networkuser" {
  count   = local.grant_host_sql
  project = var.host_project_id
  role    = "roles/compute.networkUser"
  member  = "serviceAccount:${google_project_service_identity.servicenetworking.email}"
}

# ── Propagation barrier ──────────────────────────────────────────────────────
# Service-agent IAM grants are eventually-consistent (seconds–minutes). A
# consumer (Cloud Run connector use, Cloud SQL private IP / CMEK) created the
# instant the binding returns can still hit "permission denied". Callers add
# depends_on = [module.project_iam]; this sleep makes that wait cover
# propagation, converting the modules' documented two-pass apply into one.
resource "time_sleep" "wait_iam_propagation" {
  count           = local.any_grant
  create_duration = var.iam_propagation_seconds
  depends_on = [
    google_project_iam_member.sql_servicenetworking_agent,
    google_project_iam_member.cloudrun_vpcaccess,
    google_project_iam_member.serverless_vpcaccess,
    google_project_iam_member.sn_host_servicenetworking,
    google_project_iam_member.sn_host_networkuser,
    google_kms_crypto_key_iam_member.gcs_kms,
    google_kms_crypto_key_iam_member.cloudsql_kms,
  ]
}
