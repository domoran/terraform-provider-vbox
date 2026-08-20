# Scenario 2: destroy of a RUNNING VM that does NOT react to ACPI.
#
# ACPI is disabled after the provider applies its configuration via the
# `customize` escape hatch (runs after modifyvm), so the guest can never
# shut down on `acpipowerbutton`. This simulates guests that ignore ACPI
# (e.g. while still booting, crashed kernels, missing acpid).
#
# Expected destroy behaviour (observed with destroy-observer.ps1):
#   t=0     acpipowerbutton sent (or rejected) - no effect on the guest
#   t=5..65 VMState stays "running" the whole polling window
#   t~65s   provider escalates: `controlvm poweroff` (hard poweroff)
#           VMState: running -> poweroff within ~1-10s
#   t~70s   VM unregistered
#
# BUG if: destroy errors out, the VM stays running, or the VM is
# unregistered while still running.

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

resource "virtualbox_vm" "destroy_no_acpi" {
  name       = "tf-destroy-no-acpi"
  ova_source = var.ova
  cpus       = 1
  memory     = "1024mib"

  # Disable ACPI *after* the provider's own modifyvm, so the guest
  # ignores the ACPI power button.
  customize = [
    ["modifyvm", ":id", "--acpi", "off"],
  ]

  network_adapter {
    type = "nat"
  }
}

output "vm_uuid" {
  value = virtualbox_vm.destroy_no_acpi.id
}
