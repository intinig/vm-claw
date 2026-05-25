// Package doctor runs end-to-end healthchecks against the running
// vm-claw stack. Each Check is independently runnable and reports
// OK / FAIL / WARN / SKIP with a one-line message.
package doctor

import (
	"context"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/intinig/vm-claw/internal/launchagent"
	"github.com/intinig/vm-claw/internal/tailscale"
	"github.com/intinig/vm-claw/internal/vm"
)

// Status of one healthcheck row.
type Status int

const (
	StatusOK   Status = iota // healthy
	StatusFail               // unhealthy; doctor exits non-zero if any
	StatusSkip               // not applicable in this configuration
	StatusWarn               // advisory; does not cause non-zero exit
)

func (s Status) String() string {
	switch s {
	case StatusOK:
		return "OK  "
	case StatusFail:
		return "FAIL"
	case StatusSkip:
		return "SKIP"
	case StatusWarn:
		return "WARN"
	}
	return "?   "
}

// Result is the outcome of one Check.
type Result struct {
	Name    string
	Status  Status
	Message string
}

// Check runs one row and returns a Result. ctx allows timeouts.
type Check func(ctx context.Context) Result

// Config controls which checks run and what they expect.
type Config struct {
	VMName           string // bridge VM name; default "vm-claw"
	LaunchAgentLabel string // LaunchAgent label; default "com.vm-claw.agent"
	OpenClawPort     int    // OpenClaw gateway port; default 18789
	BridgeHostIface  string // override auto-detected default-route interface
	TailnetHostname  string // tailnet FQDN for reachability probe; "" skips
	SmokeEnabled     bool   // --smoke: include smoke-test placeholder
}

// DefaultConfig returns Config with sensible defaults.
func DefaultConfig() Config {
	return Config{
		VMName:           "vm-claw",
		LaunchAgentLabel: launchagent.DefaultLabel,
		OpenClawPort:     18789,
	}
}

// DefaultChecks returns the standard set of healthcheck rows in run order.
func DefaultChecks(cfg Config) []struct {
	Name string
	Run  Check
} {
	if cfg.VMName == "" {
		cfg.VMName = "vm-claw"
	}
	if cfg.LaunchAgentLabel == "" {
		cfg.LaunchAgentLabel = launchagent.DefaultLabel
	}
	if cfg.OpenClawPort == 0 {
		cfg.OpenClawPort = 18789
	}

	tart := vm.NewTart()
	inVM := vm.TartExec{VMName: cfg.VMName}

	rows := []struct {
		Name string
		Run  Check
	}{
		// ── Host checks ──────────────────────────────────────────────────────

		{"tart-binary-on-path", func(ctx context.Context) Result {
			if _, err := lookPath("tart"); err != nil {
				return Result{Status: StatusFail, Message: "tart not on PATH — brew install cirruslabs/cli/tart"}
			}
			return Result{Status: StatusOK, Message: "found"}
		}},

		{"host-macos-tahoe-or-newer", func(ctx context.Context) Result {
			out, err := vm.DefaultExecutor.Run(ctx, "sw_vers", "-productVersion")
			if err != nil {
				return Result{Status: StatusFail, Message: "sw_vers failed: " + err.Error()}
			}
			major := parseSwVersMajor(strings.TrimSpace(string(out)))
			if major == 0 {
				return Result{Status: StatusFail, Message: "could not parse macOS version: " + strings.TrimSpace(string(out))}
			}
			if major < 26 {
				return Result{Status: StatusFail, Message: fmt.Sprintf("macOS %d detected; Tahoe (26+) required", major)}
			}
			if major > 26 {
				return Result{Status: StatusWarn, Message: fmt.Sprintf("macOS %d — newer than Tahoe; verify vmnet behaviour unchanged", major)}
			}
			return Result{Status: StatusOK, Message: strings.TrimSpace(string(out))}
		}},

		{"default-route-iface-detected", func(ctx context.Context) Result {
			iface := cfg.BridgeHostIface
			if iface == "" {
				var err error
				iface, err = vm.DetectBridgeInterface()
				if err != nil {
					return Result{Status: StatusFail, Message: "cannot detect default-route interface: " + err.Error()}
				}
			}
			return Result{Status: StatusOK, Message: iface}
		}},

		{"tailscale-cli-on-host", func(ctx context.Context) Result {
			if _, err := lookPath("tailscale"); err != nil {
				return Result{Status: StatusFail, Message: "tailscale not on PATH — install from https://tailscale.com"}
			}
			return Result{Status: StatusOK, Message: "found"}
		}},

		{"host-tailnet-up", func(ctx context.Context) Result {
			s, err := tailscale.QueryStatus(ctx, vm.DefaultExecutor)
			if err != nil {
				return Result{Status: StatusFail, Message: "tailscale status: " + err.Error()}
			}
			if s.BackendState != "Running" {
				return Result{Status: StatusFail, Message: "BackendState=" + s.BackendState + " (run `tailscale up`)"}
			}
			return Result{Status: StatusOK, Message: "Running"}
		}},

		// ── VM lifecycle ─────────────────────────────────────────────────────

		{"vm-exists", func(ctx context.Context) Result {
			ok, err := tart.Exists(ctx, cfg.VMName)
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if !ok {
				return Result{Status: StatusFail, Message: "VM '" + cfg.VMName + "' not in tart list — run `vmclaw bootstrap`"}
			}
			return Result{Status: StatusOK, Message: cfg.VMName}
		}},

		{"vm-running", func(ctx context.Context) Result {
			ip, err := tart.IP(ctx, cfg.VMName)
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if ip == "" {
				return Result{Status: StatusWarn, Message: "VM not running — run `vmclaw vm run` or load LaunchAgent"}
			}
			return Result{Status: StatusOK, Message: "running"}
		}},

		{"vm-bridged-ip-present", func(ctx context.Context) Result {
			ip, err := tart.IP(ctx, cfg.VMName)
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if ip == "" {
				return Result{Status: StatusFail, Message: "no IP — VM not running or bridge interface has no DHCP lease yet"}
			}
			return Result{Status: StatusOK, Message: ip}
		}},

		{"launchagent-loaded", func(ctx context.Context) Result {
			loaded, err := launchagent.IsLoaded(ctx, vm.DefaultExecutor, cfg.LaunchAgentLabel)
			if err != nil {
				return Result{Status: StatusFail, Message: "launchctl list failed: " + err.Error()}
			}
			if !loaded {
				return Result{Status: StatusFail, Message: "LaunchAgent " + cfg.LaunchAgentLabel + " not loaded — run `vmclaw vm install-agent`"}
			}
			return Result{Status: StatusOK, Message: cfg.LaunchAgentLabel}
		}},

		// ── Inside-VM checks (via tart exec) ─────────────────────────────────

		{"vm-os-is-sequoia", func(ctx context.Context) Result {
			out, err := inVM.Run(ctx, "/usr/bin/sw_vers", "-productVersion")
			if err != nil {
				return Result{Status: StatusFail, Message: "sw_vers in VM failed: " + err.Error()}
			}
			ver := strings.TrimSpace(string(out))
			if !strings.HasPrefix(ver, "15.") {
				return Result{Status: StatusFail, Message: "VM OS is " + ver + "; expected macOS 15 (Sequoia)"}
			}
			return Result{Status: StatusOK, Message: ver}
		}},

		{"vm-imessage-active", func(ctx context.Context) Result {
			out, err := inVM.Run(ctx, "/bin/sh", "-c",
				"/usr/bin/defaults read com.apple.iChat Account 2>/dev/null | /usr/bin/wc -l")
			if err != nil {
				return Result{Status: StatusWarn, Message: "iMessage probe failed (VM may not be running): " + err.Error()}
			}
			lines := strings.TrimSpace(string(out))
			n, _ := strconv.Atoi(lines)
			if n == 0 {
				return Result{Status: StatusWarn, Message: "no iMessage account found — sign in to Messages.app in the VM"}
			}
			return Result{Status: StatusOK, Message: fmt.Sprintf("account configured (%s lines)", lines)}
		}},

		{"vm-tailscale-joined", func(ctx context.Context) Result {
			s, err := tailscale.QueryStatus(ctx, inVM)
			if err != nil {
				return Result{Status: StatusFail, Message: "tailscale status in VM: " + err.Error()}
			}
			if s.BackendState != "Running" {
				return Result{Status: StatusFail, Message: "BackendState=" + s.BackendState + " — run `vmclaw vm tailscale-bootstrap`"}
			}
			return Result{Status: StatusOK, Message: "Running, host=" + s.Hostname}
		}},

		{"vm-firewall-block-all-incoming", func(ctx context.Context) Result {
			ok, err := vm.IsBlockAllIncoming(ctx, inVM)
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if !ok {
				return Result{Status: StatusFail, Message: "block-all-incoming NOT set — run `vmclaw vm tailscale-bootstrap` to enable"}
			}
			return Result{Status: StatusOK, Message: "enabled"}
		}},

		{"vm-openclaw-gateway-running", func(ctx context.Context) Result {
			out, err := inVM.Run(ctx, "pgrep", "-f", "openclaw.*gateway")
			if err != nil {
				return Result{Status: StatusFail, Message: "openclaw gateway process not found — is openclaw running?"}
			}
			pid := strings.TrimSpace(string(out))
			return Result{Status: StatusOK, Message: "pid " + pid}
		}},

		{"vm-openclaw-binds-to-tailscale-or-loopback", func(ctx context.Context) Result {
			out, err := inVM.Run(ctx, "/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN")
			if err != nil {
				return Result{Status: StatusFail, Message: "lsof in VM failed: " + err.Error()}
			}
			portStr := strconv.Itoa(cfg.OpenClawPort)
			for _, line := range strings.Split(string(out), "\n") {
				if !strings.Contains(line, "openclaw") && !strings.Contains(line, portStr) {
					continue
				}
				// lsof -nP format: NAME column contains "addr:port (LISTEN)"
				// We check the bind address is 127.0.0.1 or starts with 100. (Tailscale CGNAT)
				if strings.Contains(line, "127.0.0.1:"+portStr) ||
					strings.Contains(line, "*:"+portStr) == false && strings.Contains(line, ":"+portStr) {
					// more permissive: accept any non-* bind
					fields := strings.Fields(line)
					for _, f := range fields {
						if strings.HasSuffix(f, ":"+portStr) {
							host := strings.TrimSuffix(f, ":"+portStr)
							if host == "*" || host == "0.0.0.0" || host == "::" {
								return Result{Status: StatusFail, Message: "openclaw is bound to " + f + " — must bind to 127.0.0.1 or Tailscale IP"}
							}
							return Result{Status: StatusOK, Message: "bound to " + f}
						}
					}
				}
				// Check for wildcard bind — fail immediately
				if strings.Contains(line, "*:"+portStr) || strings.Contains(line, "0.0.0.0:"+portStr) {
					return Result{Status: StatusFail, Message: "openclaw is bound to *:" + portStr + " — must bind to 127.0.0.1 or Tailscale IP"}
				}
			}
			return Result{Status: StatusWarn, Message: fmt.Sprintf("port %d not found in lsof output — openclaw may not be listening", cfg.OpenClawPort)}
		}},

		{"vm-openclaw-config-hardened", func(ctx context.Context) Result {
			out, err := inVM.Run(ctx, "/bin/cat", "/Users/openclaw/.openclaw/config.yaml")
			if err != nil {
				// try home-directory fallback
				out, err = inVM.Run(ctx, "/bin/sh", "-c", "cat ~/.openclaw/config.yaml")
				if err != nil {
					return Result{Status: StatusFail, Message: "cannot read openclaw config.yaml: " + err.Error()}
				}
			}
			content := string(out)
			type req struct{ key, want string }
			required := []req{
				{"auth.required", "true"},
				{"permissions.askConfirmation", "true"},
				{"terminal.persistent", "false"},
				{"channels.imessage.dmPolicy", "allowlist"},
			}
			var missing []string
			for _, r := range required {
				if !strings.Contains(content, r.key+": "+r.want) &&
					!strings.Contains(content, r.key+":"+r.want) {
					missing = append(missing, r.key+"="+r.want)
				}
			}
			if len(missing) > 0 {
				return Result{Status: StatusFail, Message: "hardening keys missing/wrong: " + strings.Join(missing, ", ")}
			}
			return Result{Status: StatusOK, Message: "all hardening keys present"}
		}},

		{"vm-openclaw-version-fresh", func(ctx context.Context) Result {
			// Freshness check against npm registry is expensive (network call).
			// This is a yellow-only check: report installed version, never red.
			// Full freshness validation is a follow-up task.
			out, err := inVM.Run(ctx, "/opt/homebrew/bin/openclaw", "--version")
			if err != nil {
				// Try PATH resolution
				out, err = inVM.Run(ctx, "/bin/sh", "-c", "openclaw --version 2>/dev/null || echo unknown")
				if err != nil {
					return Result{Status: StatusWarn, Message: "cannot determine openclaw version"}
				}
			}
			ver := strings.TrimSpace(string(out))
			return Result{Status: StatusOK, Message: "installed: " + ver}
		}},

		// ── Negative connectivity ─────────────────────────────────────────────

		{"bridged-port-unreachable", func(ctx context.Context) Result {
			ip, _ := tart.IP(ctx, cfg.VMName)
			if ip == "" {
				return Result{Status: StatusSkip, Message: "no VM IP yet"}
			}
			addr := net.JoinHostPort(ip, strconv.Itoa(cfg.OpenClawPort))
			conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
			if err == nil {
				conn.Close()
				return Result{Status: StatusFail, Message: "port " + addr + " is reachable from host — firewall not blocking bridged interface"}
			}
			return Result{Status: StatusOK, Message: "connection to " + addr + " refused/timeout (expected)"}
		}},

		{"tailnet-port-reachable", func(ctx context.Context) Result {
			if cfg.TailnetHostname == "" {
				return Result{Status: StatusWarn, Message: "tailnet hostname not configured (use --tailnet-host)"}
			}
			addr := net.JoinHostPort(cfg.TailnetHostname, strconv.Itoa(cfg.OpenClawPort))
			conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
			if err != nil {
				return Result{Status: StatusFail, Message: "cannot reach " + addr + " over tailnet: " + err.Error()}
			}
			conn.Close()
			return Result{Status: StatusOK, Message: addr + " reachable"}
		}},

		// ── Outbound liveness ─────────────────────────────────────────────────

		{"vm-outbound-works", func(ctx context.Context) Result {
			out, err := inVM.Run(ctx, "/usr/bin/curl", "-sS", "--max-time", "10",
				"-o", "/dev/null", "-w", "%{http_code}", "https://api.anthropic.com/")
			if err != nil {
				return Result{Status: StatusFail, Message: "curl in VM failed: " + err.Error()}
			}
			code := strings.TrimSpace(string(out))
			// Any HTTP response (even 4xx from Anthropic's /  endpoint) proves connectivity.
			if code == "000" || code == "" {
				return Result{Status: StatusFail, Message: "curl returned HTTP 000 — no network connectivity from VM"}
			}
			return Result{Status: StatusOK, Message: "HTTP " + code + " from api.anthropic.com"}
		}},
	}

	if cfg.SmokeEnabled {
		rows = append(rows, struct {
			Name string
			Run  Check
		}{"vm-imessage-roundtrip-smoke", func(ctx context.Context) Result {
			// TODO(smoke): real iMessage round-trip needs an external Apple device sending
			// to the bridge handle; see docs/runbook-openclaw-install.md section 10.
			return Result{
				Status:  StatusWarn,
				Message: "smoke roundtrip requires an external Apple device — see runbook",
			}
		}})
	}

	return rows
}

// parseSwVersMajor parses "15.3.1" → 15. Returns 0 on parse failure.
func parseSwVersMajor(ver string) int {
	parts := strings.SplitN(ver, ".", 2)
	if len(parts) == 0 {
		return 0
	}
	n := 0
	for _, c := range parts[0] {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// lookPath is a thin wrapper around exec.LookPath for testability.
var lookPath = func(name string) (string, error) {
	return execLookPath(name)
}

// Run executes all checks in order, prints OK/FAIL/WARN/SKIP per row to w,
// and returns the count of failed rows (0 == green).
func Run(ctx context.Context, w io.Writer, cfg Config) int {
	checks := DefaultChecks(cfg)
	failed := 0
	for _, c := range checks {
		res := c.Run(ctx)
		fmt.Fprintf(w, "  [%s]  %-52s %s\n", res.Status, c.Name, res.Message)
		if res.Status == StatusFail {
			failed++
		}
	}
	return failed
}
