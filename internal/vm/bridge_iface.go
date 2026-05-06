package vm

import (
	"fmt"
	"os/exec"
	"strings"
)

// DetectBridgeInterface returns the host interface name that carries the
// IPv4 default route (e.g. "en0", "en1"). This is the interface Tart
// should bridge onto when running with --net-bridged on macOS.
//
// Workaround for the macOS Tahoe vmnet regression that broke softnet's
// configurable subnet (see CLAUDE.md "iMessage Bridge VM Requirements").
// Override with the BRIDGE_HOST_IFACE env var.
func DetectBridgeInterface() (string, error) {
	out, err := exec.Command("route", "-n", "get", "default").Output()
	if err != nil {
		return "", fmt.Errorf("route -n get default: %w", err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "interface:" {
			return fields[1], nil
		}
	}
	return "", fmt.Errorf("no default-route interface in `route -n get default` output")
}
