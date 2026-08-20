package provider

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCleanupVMFolder(t *testing.T) {
	oldTimeout := vmFolderCleanupTimeout
	vmFolderCleanupTimeout = 3 * time.Second
	t.Cleanup(func() { vmFolderCleanupTimeout = oldTimeout })

	t.Run("missing folder is a no-op", func(t *testing.T) {
		dir := t.TempDir()
		gone := filepath.Join(dir, "does-not-exist")
		start := time.Now()
		cleanupVMFolder(gone)
		if time.Since(start) > time.Second {
			t.Fatalf("cleanup took %v, expected immediate return", time.Since(start))
		}
	})

	t.Run("empty baseFolder is a no-op", func(t *testing.T) {
		cleanupVMFolder("")
	})

	t.Run("leftover folder without machine config is removed", func(t *testing.T) {
		dir := t.TempDir()
		folder := filepath.Join(dir, "my-vm")
		if err := os.MkdirAll(filepath.Join(folder, "Logs"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, "Logs", "VBoxHardening.log"), []byte("log"), 0o644); err != nil {
			t.Fatal(err)
		}

		cleanupVMFolder(folder)

		if _, err := os.Stat(folder); !os.IsNotExist(err) {
			t.Fatalf("leftover folder was not removed (stat err: %v)", err)
		}
	})

	t.Run("folder with machine config is kept", func(t *testing.T) {
		dir := t.TempDir()
		folder := filepath.Join(dir, "my-vm")
		if err := os.MkdirAll(folder, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, "my-vm.vbox"), []byte("<Machine/>"), 0o644); err != nil {
			t.Fatal(err)
		}

		cleanupVMFolder(folder)

		if _, err := os.Stat(filepath.Join(folder, "my-vm.vbox")); err != nil {
			t.Fatalf("machine config was deleted: %v", err)
		}
	})
}
