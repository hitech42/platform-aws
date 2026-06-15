module "network" {
  source = "../../modules/network"

  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr
  # public_subnet_cidrs and private_subnet_cidrs use module defaults:
  #   public:  ["10.0.0.0/24", "10.0.1.0/24"]
  #   private: ["10.0.2.0/24", "10.0.3.0/24"]
  # app_port uses module default: 8000
}

module "iam" {
  source = "../../modules/iam"

  project_name         = var.project_name
  environment          = var.environment
  github_org           = var.github_org
  github_repo          = var.github_repo
  create_oidc_provider = var.create_oidc_provider
  allowed_refs         = var.allowed_refs
  state_bucket_name    = var.state_bucket_name
  # oidc_thumbprints uses module default (known GitHub OIDC cert thumbprints)
}
