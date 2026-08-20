# Scenario 1: baseline destroy of a RUNNING VM that reacts to ACPI.
#
# NOTE: wait for the guest to actually finish booting before destroying
# (the Ubuntu cloud image needs ~20-40 s until its ACPI handler is up).
# Destroying while the guest is still booting exercises the escalation
# path instead: ACPI is ignored for 60 s, then a hard poweroff fires and
# the VM must still be removed completely.
#
#   1. tofu apply -auto-approve
#   2. sleep 30                      # let the guest finish booting
#   3. tofu destroy -auto-approve
#
# Expected destroy behaviour (observed with destroy-observer.ps1):
#   t=0      destroy sends `controlvm acpipowerbutton`
#   t<~10s   guest OS shuts down, VMState: running -> poweroff
#   t<~10s   VM unregistered, gone from `VBoxManage list vms`
#
# If the VM never reaches poweroff before unregistration, that's a bug.

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

resource "virtualbox_vm" "destroy_running" {
  name       = "tf-destroy-running"
  ova_source = var.ova
  cpus       = 1
  memory     = "1024mib"

  network_adapter {
    type = "nat"
  }
}

output "vm_uuid" {
  value = virtualbox_vm.destroy_running.id
}
