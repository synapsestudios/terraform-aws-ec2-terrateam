terraform {
  required_version = ">= 1.10"

  required_providers {
    # Reusable modules declare a minimum (>=) and let the consuming root config
    # pick the maximum — never a pessimistic ~> pin. The integration test
    # (tests/integration/main.tf) repeats this constraint; change both together.
    # (HashiCorp provider-requirements guidance for reusable modules.)
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
