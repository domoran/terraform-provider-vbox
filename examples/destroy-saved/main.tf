# Scenario 3: destroy of a VM left in "saved" state.
#
# A VM saved via `controlvm savestate` (e.g. by VirtualBox Manager, a
# crash-recovery save, or host shutdown) is NOT running, so
# `acpipowerbutton` can never work on it. This is the "saved poweroff
# state" case: the VM is not running, but also not powered off.
#
# The VM is put into "saved" state EXTERNALLY (the provider does not
# know about it):
#
#   1. tofu apply -auto-approve        (VM created + started)
#   2. wait until it is running, then:
#      VBoxManage.exe controlvm tf-destroy-saved savestate
#      (or start the VirtualBox GUI and click "Save")
#   3. tofu destroy -auto-approve
#
# Expected destroy behaviour (observed with destroy-observer.ps1):
#   t=0     VMState: saved
#           - the provider must NOT waste 60s polling for an ACPI
#             shutdown that can never happen on a saved VM
#   t<~5s   VM unregistered + all files deleted
#
# BUG if: destroy takes ~60s for nothing, or refuses to unregister the
# saved VM.

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

resource "virtualbox_vm" "destroy_saved" {
  name       = "tf-destroy-saved"
  ova_source = var.ova
  cpus       = 1
  memory     = "1024mib"

  network_adapter {
    type = "nat"
  }
}

output "vm_uuid" {
  value = virtualbox_vm.destroy_saved.id
}
