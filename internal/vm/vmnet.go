package vm

import (
	"bufio"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"
)

// ifaceInfo summarizes one interface for vmnet collision detection.
type ifaceInfo struct {
	IPv4          string // first IPv4 address, or empty
	IsVmnetBridge bool   // bridge* with a "member: vmenet*" line
}

var inetLineRE = regexp.MustCompile(`^\s+inet\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\b`)

// parseIfconfig parses the output of `ifconfig` (or `ifconfig -a`) into a
// map of interface name -> info. Only IPv4 addresses are recorded; a bridge*
// interface with a `member: vmenet*` line is flagged as the vmnet bridge.
func parseIfconfig(r io.Reader) map[string]ifaceInfo {
	out := map[string]ifaceInfo{}

	var current string
	var info ifaceInfo

	flush := func() {
		if current != "" {
			out[current] = info
		}
	}

	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "\t") && !strings.HasPrefix(line, " ") && strings.Contains(line, ":") {
			// New interface header, e.g. "bridge100: flags=...".
			flush()
			current = strings.SplitN(line, ":", 2)[0]
			info = ifaceInfo{}
			continue
		}
		if m := inetLineRE.FindStringSubmatch(line); m != nil && info.IPv4 == "" {
			info.IPv4 = m[1]
		}
		if strings.HasPrefix(current, "bridge") && strings.Contains(line, "member: vmenet") {
			info.IsVmnetBridge = true
		}
	}
	flush()
	return out
}

// detectVmnetCollision returns an error if the vmnet bridge's /24 subnet
// is also used by an active host interface (e.g. en0). When this happens
// the VM gets an IP already in use on the LAN and return traffic is
// asymmetrically routed, breaking internet from the guest.
//
// If no vmnet bridge is present in `ifaces`, returns nil — we can't
// detect a collision until vmnet is up. Loopback (127.0.0.0/8) is ignored.
func detectVmnetCollision(ifaces map[string]ifaceInfo) error {
	var vmnetIface, vmnetIP, vmnetPrefix string
	for name, info := range ifaces {
		if info.IsVmnetBridge && info.IPv4 != "" {
			vmnetIface = name
			vmnetIP = info.IPv4
			vmnetPrefix = ipPrefix24(info.IPv4)
			break
		}
	}
	if vmnetPrefix == "" {
		return nil
	}

	for name, info := range ifaces {
		if name == vmnetIface || info.IPv4 == "" {
			continue
		}
		if strings.HasPrefix(info.IPv4, "127.") {
			continue
		}
		if ipPrefix24(info.IPv4) == vmnetPrefix {
			return fmt.Errorf(
				"vmnet subnet collides with active host interface: %s (%s) vs %s (%s); "+
					"the VM would get an IP already in use on your LAN. Pick a non-overlapping "+
					"subnet for vmnet — see CLAUDE.md \"vmnet bridge collides with host LAN\"",
				name, info.IPv4, vmnetIface, vmnetIP)
		}
	}
	return nil
}

// ipPrefix24 returns the /24 prefix (e.g. "192.168.1") of an IPv4 address.
// Returns "" for empty or malformed input.
func ipPrefix24(ip string) string {
	idx := strings.LastIndex(ip, ".")
	if idx <= 0 {
		return ""
	}
	return ip[:idx]
}

// VmnetCollisionCheck runs `ifconfig -a` and returns an error if the active
// vmnet bridge subnet collides with any other host interface.
func VmnetCollisionCheck() error {
	cmd := exec.Command("ifconfig", "-a")
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("ifconfig -a: %w", err)
	}
	return detectVmnetCollision(parseIfconfig(strings.NewReader(string(out))))
}
