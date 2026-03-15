variable "project" { type = string }
variable "environment" { type = string }

variable "github_org" {
  description = "GitHub organisation (e.g. hydrosat)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (e.g. dagster-platform)"
  type        = string
}

variable "create_oidc_provider" {
  description = "Set false if the GitHub OIDC provider already exists in this account"
  type        = bool
  default     = true
}

variable "tf_state_bucket" {
  description = "S3 bucket name used for Terraform state (for scoped S3 permissions)"
  type        = string
}

variable "tf_lock_table" {
  description = "DynamoDB table name for Terraform state locking"
  type        = string
}
