package provider

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"time"

	humanize "github.com/dustin/go-humanize"
	"github.com/hashicorp/terraform-plugin-log/tflog"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/retry"
	"github.com/hashicorp/terraform-plugin-sdk/v2/helper/schema"
)

// waitForPoweroff sends an ACPI poweroff button signal to the VM and waits for the
// VM state to reach "poweroff" or the timeout expires. This ensures the guest
// OS has time to shut down cleanly before we proceed with modifications.
func waitForPoweroff(ctx context.Context, vmUUID string, timeout time.Duration) error {
	// Send ACPI poweroff signal (graceful shutdown via guest OS).
	// VBoxManage returns immediately, so we must poll for actual state.
	_, _, err := vboxRun(ctx, "controlvm", vmUUID, "acpipowerbutton")
	if err != nil {
		// If the VM is already poweroff or not found, that's fine — continue.
		tflog.Warn(ctx, "controlvm poweroff returned error, proceeding anyway", map[string]any{
			"vm": vmUUID, "error": err,
		})
	}

	// Poll until VM reaches "poweroff" state.
	stateConf := &retry.StateChangeConf{
		Pending:      []string{"running", "paused", "saved"},
		Target:       []string{"poweroff"},
		Refresh: func() (interface{}, string, error) {
			vm, err := getMachine(vmUUID)
			if err != nil {
				return nil, "", fmt.Errorf("get machine: %w", err)
			}
			return vm, string(vm.State), nil
		},
		Timeout:    timeout,
		MinTimeout: 2 * time.Second,
	}
	_, err = stateConf.WaitForStateContext(ctx)
	if err != nil {
		return fmt.Errorf("timed out waiting for VM to power off (timeout=%v): %w", timeout, err)
	}
	return nil
}

// startVM starts the VM respecting the gui attribute. When gui is true,
// VBoxManage startvm is called with --type gui; otherwise headless.
func startVM(ctx context.Context, d *schema.ResourceData, vm *Machine) error {
	gui := d.Get("gui").(bool)
	if gui {
		return startVMGUI(ctx, vm.UUID)
	}
	return startVMHeadless(ctx, vm.UUID)
}

func powerOnAndWait(ctx context.Context, d *schema.ResourceData, vm *Machine, meta any) error {
	if err := startVM(ctx, d, vm); err != nil {
		return fmt.Errorf("can't start vm: %w", err)
	}

	if err := waitUntilVMIsReady(ctx, d, vm, meta); err != nil {
		return fmt.Errorf("unable to power on and wait: %w", err)
	}

	return nil
}

// Wait until VM is ready, and 'ready' means the first non NAT NIC get a ipv4_address assigned.
// If the timeout is reached, the VM is still considered created — the IP may be assigned later
// (e.g. when DHCP is configured or a static IP is set via provisioning).
func waitUntilVMIsReady(ctx context.Context, d *schema.ResourceData, vm *Machine, meta any) error {
	for i, nic := range vm.NICs {
		if nic.Network == NICNetNAT {
			continue
		}

		key := fmt.Sprintf("network_adapter.%d.ipv4_address_available", i)
		if _, err := waitForVMAttribute(
			ctx,
			d,
			[]string{"yes"},
			[]string{"no"},
			key,
			meta,
			30*time.Second,
			1*time.Second,
		); err != nil {
			// Timeout is not fatal — VM is running, just no IP yet
			tflog.Warn(ctx, "timeout waiting for IP on non-NAT adapter, VM is running but may need DHCP or static IP configuration", map[string]any{
				"vm":      d.Get("name"),
				"adapter": i,
			})
		}
		break
	}
	return nil
}

func tfToVbox(ctx context.Context, d *schema.ResourceData, vm *Machine) error {
	var err error

	vm.OSType = d.Get("os_type").(string)
	vm.CPUs = uint(d.Get("cpus").(int))
	bytes, err := humanize.ParseBytes(d.Get("memory").(string))
	if err != nil {
		return fmt.Errorf("cannot humanize bytes: %w", err)
	}
	vm.Memory = uint(bytes / humanize.MiByte) // VirtualBox expect memory to be in MiB units

	vm.VRAM = uint(d.Get("vram").(int))
	vm.Flag = FlagACPI | FlagRTCUSEUTC | FlagHWVIRTEX | FlagNESTEDPAGING | FlagLONGMODE | FlagVTXUX
	if d.Get("ioapic").(bool) {
		vm.Flag |= FlagIOAPIC
	}
	if d.Get("pae").(bool) {
		vm.Flag |= FlagPAE
	}
	if d.Get("largepages").(bool) {
		vm.Flag |= FlagLARGEPAGES
	}
	if d.Get("vtx_vpid").(bool) {
		vm.Flag |= FlagVTXVPID
	}
	vm.NICs, err = netTfToVbox(ctx, d)
	vm.BootOrder = defaultBootOrder
	for i, bootDev := range d.Get("boot_order").([]any) {
		vm.BootOrder[i] = bootDev.(string)
	}
	return err
}

func waitForVMAttribute(ctx context.Context, d *schema.ResourceData, target []string, pending []string, attribute string, meta any, delay, interval time.Duration) (any, error) {
	// Wait for the vm so we can get the networking attributes that show up
	// after a while.
	tflog.Debug(ctx, "waiting for vm to have required attribute value", map[string]any{
		"vm":        d.Get("name"),
		"attribute": attribute,
		"target":    "target",
	})

	stateConf := &retry.StateChangeConf{
		Pending:        pending,
		Target:         target,
		Refresh:        newVMStateRefreshFunc(ctx, d, attribute, meta),
		Timeout:        5 * time.Minute,
		Delay:          delay,
		MinTimeout:     interval,
		NotFoundChecks: 60,
	}

	return stateConf.WaitForStateContext(ctx)
}

func newVMStateRefreshFunc(ctx context.Context, d *schema.ResourceData, attribute string, meta any) retry.StateRefreshFunc {
	return func() (any, string, error) {
		err := resourceVMRead(ctx, d, meta)
		if err != nil {
			// TODO: How do we provide context easily without exploring the
			//       diag.Diagnostics
			return nil, "", fmt.Errorf("unable to read VM")
		}

		// See if we can access our attribute
		if attr, ok := d.GetOk(attribute); ok {
			// Retrieve the VM properties
			vm, err := getMachine(d.Id())
			if err != nil {
				return nil, "", fmt.Errorf("unable to retrieve vm: %w", err)
			}

			return &vm, attr.(string), nil
		}

		return nil, "", nil
	}
}

func fetchIfRemote(u *url.URL) (string, error) {
	// If the schema is empty, treat it as a local path, otherwise
	// use it as a remote.
	if u.Scheme == "" {
		return u.Path, nil
	}

	// TODO: Add special handing for other schemes, such as
	//		 s3, gcs, (s)ftp(s).
	// We want to quit if the scheme is not currently supported.
	switch u.Scheme {
	case "http", "https":
		break
	default:
		return "", fmt.Errorf("unsupported scheme %s", u.Scheme)
	}

	_, file := filepath.Split(u.Path)

	// Make the download path absolute so tar can find it regardless of CWD
	absFile, _ := filepath.Abs(file)
	file = absFile

	// if the file is not found, and the error is unexpected, return
	if _, err := os.Stat(file); err != nil && !os.IsNotExist(err) {
		return "", err
	}

	f, err := os.Create(file)
	if err != nil {
		return "", err
	}
	defer f.Close() //nolint:errcheck

	resp, err := http.Get(u.String()) //nolint:gosec
	if err != nil {
		return "", err
	}
	defer resp.Body.Close() //nolint:errcheck

	if _, err := io.Copy(f, resp.Body); err != nil {
		return "", err
	}

	return file, nil
}
