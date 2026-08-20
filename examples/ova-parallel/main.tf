# Scenario 5: two VMs created in PARALLEL from the SAME OVA file.
#
# Reproduces the reported problem: with parallel creation, the OVA could
# not be imported into the second VM (VBoxManager contention between two
# concurrent `VBoxManage import` processes).
#
# Expected behaviour:
#   - BOTH imports succeed (serialized by the provider, or retried on
#     contention)
#   - both VMs registered and running
#   - `tofu destroy` removes both, including hard-poweroff fallback
#
# BUG if: the second `VBoxManage import` fails (e.g. "Timeout waiting for
# response", "locked by a running VirtualBox instance", or generic
# VBOX_E failures) while the first succeeds.

terraform {
  required_providers {
    virtualbox = {
      source = "registry.terraform.io/eran132/vbox"
    }
  }
  # Force real parallelism of the two creates.
  required_version = ">= 1.0"
}

provider "virtualbox" {}

variable "ova" {
  type        = string
  description = "Local path to the OVA used to create both VMs"
  default     = "C:\\Users\\Nutzer\\Downloads\\ubuntu-22.04-server-cloudimg-amd64.ova"
}

resource "virtualbox_vm" "parallel" {
  count = 2

  name       = "tf-ova-parallel-${count.index + 1}"
  ova_source = var.ova
  cpus       = 1
  memory     = "1024mib"

  network_adapter {
    type = "nat"
  }
}

output "vm_uuids" {
  value = virtualbox_vm.parallel[*].id
}
