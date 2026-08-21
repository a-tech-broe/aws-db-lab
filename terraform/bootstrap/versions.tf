terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Deliberately local state. This module creates the bucket that every other
  # environment stores its state in, so it cannot store its own state there.
  # It is applied once, by hand, and rarely changes -- commit nothing but the
  # code; the state file stays on the operator's machine.
}
