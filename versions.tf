terraform {
  required_version = ">= 1.10"

  required_providers {
    # Reusable modules declare a minimum (>=) and let the consuming root config
    # pick the maximum — never a pessimistic ~> pin. This is the single source of
    # truth for the AWS provider version: the examples and the integration test
    # omit their own aws version and inherit this constraint via intersection at
    # init. (HashiCorp provider-requirements guidance for reusable modules.)
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
