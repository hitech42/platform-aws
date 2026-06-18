variable "project_name" {
  description = "Short slug used as a prefix for all IAM resources (e.g. 'cvs-platform')."
  type        = string
}

variable "environment" {
  description = "Deployment environment — drives role naming and trust-policy ref conditions."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# ── GitHub OIDC ───────────────────────────────────────────────────────────────

variable "create_oidc_provider" {
  description = <<-EOT
    Set to true (default) to create the GitHub OIDC provider in this account.
    Set to false if the provider already exists — the module will look it up
    via a data source instead.  The OIDC provider is account-wide (not per-region
    or per-environment), so only one can exist per AWS account.
    If a second apply tries to create it, Terraform will error with
    EntityAlreadyExists; flip this to false and re-apply.
  EOT
  type        = bool
  default     = true
}

variable "oidc_thumbprints" {
  description = <<-EOT
    SHA-1 thumbprints of the GitHub OIDC TLS certificate.  AWS requires at least
    one thumbprint even though it now validates GitHub tokens at the service level.
    These are the two known GitHub OIDC cert thumbprints as of 2024; verify against
    https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
    before applying.
  EOT
  type        = list(string)
  default = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

variable "github_org" {
  description = "GitHub organisation or user that owns the repository (e.g. 'hitech42')."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name without the org prefix (e.g. 'platform-aws')."
  type        = string
}

variable "allowed_refs" {
  description = <<-EOT
    List of GitHub ref patterns that are allowed to assume this environment's
    deploy role.  Each entry becomes a value in the OIDC trust-policy
    StringLike condition for the `sub` claim.  Use exact refs (e.g.
    "refs/heads/develop") for branches; glob patterns are also supported by
    StringLike (e.g. "refs/heads/feature/*") if you need broader access.

    Design choice — one role per environment:
      dev role     → ["refs/heads/develop"]
      staging role → ["refs/heads/staging"]   (added in E4)
      prod role    → ["refs/heads/main"]       (added in E4)

    This ensures a compromised develop branch cannot trigger staging/prod
    deploys.  Each environment's trust boundary is enforced at the IAM layer,
    not just in the GitHub Actions workflow YAML (which can be edited in a PR).
  EOT
  type        = list(string)
  default     = ["refs/heads/develop"]
}

variable "allowed_environments" {
  description = <<-EOT
    List of GitHub Actions environment names that are allowed to assume this
    role. Required in addition to (not instead of) allowed_refs: when a
    workflow job declares `environment: <name>`, GitHub's OIDC token `sub`
    claim switches from `repo:ORG/REPO:ref:refs/heads/BRANCH` to
    `repo:ORG/REPO:environment:<name>` — it no longer carries the ref at all.
    Any job that declares an environment (e.g. to read an environment-scoped
    variable like AWS_DEPLOY_ROLE_ARN) needs its environment name listed here,
    or AssumeRoleWithWebIdentity is denied even though allowed_refs matches
    the branch the workflow ran on.
  EOT
  type        = list(string)
  default     = []
}

# ── State backend ─────────────────────────────────────────────────────────────

variable "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state (from bootstrap outputs). Used to scope the deploy role's S3 permissions."
  type        = string
}

# ── ECR ───────────────────────────────────────────────────────────────────────

variable "ecr_repository_name" {
  description = <<-EOT
    Name of the ECR repository this environment's GitHub Actions deploy role
    is allowed to manage and push to.  Defaults to var.project_name ("cvs-platform")
    which matches the dev repository.  Staging passes "cvs-platform-staging" so
    each environment's deploy role is scoped to exactly its own ECR repository
    (least-privilege: the staging role cannot push to the dev repo and vice versa).
  EOT
  type        = string
  default     = ""
}


