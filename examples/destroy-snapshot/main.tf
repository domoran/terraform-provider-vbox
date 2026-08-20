# Scenario 4: destroy of a VM that has SNAPSHOTS.
#
# A live snapshot is taken while the VM is running. On destroy the
# provider must delete the VM AND all snapshot files (snapshot VDIs and
# .sav state files live inside the VM folder).
#
# Expected destroy behaviour (observed with destroy-observer.ps1, with
# -BaseFolder pointing at the machine folder):
#   - both resources destroyed, `tofu destroy` exits 0
#   - VM gone from `VBoxManage list vms`
#   - NO leftover VM folder on disk (observer logs "ABSENT" without a
#     LEFTOVER-FOLDER annotation), i.e. no orphaned *.vdi / *.sav files
#
# BUG if: the VM folder or any snapshot disk remains on disk after a
# successful destroy.

terraform {
  required_providers {
    virtualbox = {
      source = "registry.terraform.io/eran132/vbox"
    }
  }
}

provider "virtualbox" {}

variable "ova" {
  type        = string
  description = "Local path to the OVA used to create the VM"
  default     = "C:\\Users\\Nutzer\\Downloads\\ubuntu-22.04-server-cloudimg-amd64.ova"
}

resource "virtualbox_vm" "destroy_snapshot" {
  name       = "tf-destroy-snapshot"
  ova_source = var.ova
  cpus       = 1
  memory     = "1024mib"

  network_adapter {
    type = "nat"
  }
}

resource "virtualbox_snapshot" "snap" {
  vm_id       = virtualbox_vm.destroy_snapshot.id
  name        = "pre-destroy"
  description = "snapshot that must be cleaned up on destroy"
  live        = true
}

output "vm_uuid" {
  value = virtualbox_vm.destroy_snapshot.id
}
