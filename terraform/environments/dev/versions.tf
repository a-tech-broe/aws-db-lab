terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Phase 1 runs on local state so the lab is easy to stand up and tear down.
  # Uncomment once the state bucket exists; the GitHub Actions pipeline that
  # arrives with the CI/CD work needs remote state with locking.
  #
  # backend "s3" {
  #   bucket       = "<account-id>-tfstate-us-east-1"
  #   key          = "aws-db-lab/dev/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}
