// Package cli wires Cobra commands and exposes Execute as the binary entry point.
package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// Version is set at build time via -ldflags "-X main.version=...".
// main copies the linker-injected value into this package var.
var Version = "dev"

// rootCmd is the top-level vmclaw command. Subcommand packages register
// children onto it via init() functions.
var rootCmd = &cobra.Command{
	Use:           "vmclaw",
	Short:         "Manage the OpenClaw-on-Sequoia VM stack",
	Long:          "vmclaw owns the Tart Sequoia VM that hosts OpenClaw and Messages.app, plus the Tailscale lockdown and end-to-end doctor checks.",
	SilenceUsage:  true,  // don't dump help on RunE errors
	SilenceErrors: true,  // we print errors ourselves
	Version:       Version,
}

// Execute runs the root command. Returns the process exit code.
func Execute() int {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err.Error())
		return 1
	}
	return 0
}

// SetVersion lets main inject the linker-built version after init.
// Called once from cmd/vmclaw/main.go before Execute().
func SetVersion(v string) {
	Version = v
	rootCmd.Version = v
}

// RootCommand returns the root *cobra.Command for any external use.
// Internal subcommand packages typically use the package-level rootCmd directly.
func RootCommand() *cobra.Command {
	return rootCmd
}
