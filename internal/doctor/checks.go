// Package doctor runs end-to-end healthchecks against the running
// vm-claw stack. Each Check is independently runnable and reports
// OK / FAIL / SKIP with a one-line message.
package doctor

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	urlpkg "net/url"
	"strings"
	"time"

	"github.com/intinig/vm-claw/internal/vm"
)

// Status of one healthcheck row.
type Status int

const (
	StatusOK   Status = iota // healthy
	StatusFail               // unhealthy; doctor exits non-zero if any
	StatusSkip               // not applicable in this configuration
)

func (s Status) String() string {
	switch s {
	case StatusOK:
		return "OK"
	case StatusFail:
		return "FAIL"
	case StatusSkip:
		return "SKIP"
	}
	return "?"
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
	Executor      vm.Executor // tart, docker, etc.
	VMName        string      // bridge VM name
	BBPort        int         // BlueBubbles port (default 1234)
	BBPassword    string      // BB admin password; if "", checks that need it Skip
	HermesGateway string      // gateway container name (default "hermes")
}

// DefaultChecks returns the standard set of healthcheck rows in run order.
func DefaultChecks(cfg Config) []struct {
	Name string
	Run  Check
} {
	tart := vm.NewTartWithExecutor(cfg.Executor)
	if cfg.BBPort == 0 {
		cfg.BBPort = 1234
	}
	if cfg.HermesGateway == "" {
		cfg.HermesGateway = "hermes"
	}

	return []struct {
		Name string
		Run  Check
	}{
		{"tart binary present", func(ctx context.Context) Result {
			if _, err := cfg.Executor.Run(ctx, "command", "-v", "tart"); err != nil {
				return Result{Status: StatusFail, Message: "tart not on PATH (brew install cirruslabs/cli/tart)"}
			}
			return Result{Status: StatusOK, Message: "found"}
		}},

		{"bridge VM exists", func(ctx context.Context) Result {
			ok, err := tart.Exists(ctx, cfg.VMName)
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if !ok {
				return Result{Status: StatusFail, Message: "VM '" + cfg.VMName + "' not in tart list (run `vmclaw vm create`)"}
			}
			return Result{Status: StatusOK, Message: cfg.VMName}
		}},

		{"bridge VM has IP", func(ctx context.Context) Result {
			ip, err := tart.IP(ctx, cfg.VMName)
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if ip == "" {
				return Result{Status: StatusFail, Message: "VM not running (run `vmclaw vm run` or load LaunchAgent)"}
			}
			return Result{Status: StatusOK, Message: ip}
		}},

		{"BlueBubbles reachable from host", func(ctx context.Context) Result {
			ip, _ := tart.IP(ctx, cfg.VMName)
			if ip == "" {
				return Result{Status: StatusSkip, Message: "no VM IP yet"}
			}
			url := fmt.Sprintf("http://%s:%d/api/v1/server/info", ip, cfg.BBPort)
			if cfg.BBPassword != "" {
				url += "?password=" + urlpkg.QueryEscape(cfg.BBPassword)
			}
			if err := probeHTTP(ctx, url, 3*time.Second); err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			return Result{Status: StatusOK, Message: "200 from " + url}
		}},

		{"colima registered as brew service", func(ctx context.Context) Result {
			out, err := cfg.Executor.Run(ctx, "brew", "services", "list")
			if err != nil {
				return Result{Status: StatusFail, Message: "brew services list failed: " + err.Error()}
			}
			for _, line := range strings.Split(string(out), "\n") {
				fields := strings.Fields(line)
				if len(fields) < 2 || fields[0] != "colima" {
					continue
				}
				switch fields[1] {
				case "started", "scheduled":
					return Result{Status: StatusOK, Message: fields[1] + " (auto-starts at login)"}
				case "stopped", "none":
					return Result{Status: StatusFail, Message: "status=" + fields[1] + " — run `brew services start colima` so it survives reboot"}
				default:
					return Result{Status: StatusFail, Message: "status=" + fields[1]}
				}
			}
			return Result{Status: StatusFail, Message: "colima not in brew services list"}
		}},

		{"docker daemon reachable", func(ctx context.Context) Result {
			if _, err := cfg.Executor.Run(ctx, "docker", "version"); err != nil {
				return Result{Status: StatusFail, Message: "docker not reachable (start colima?)"}
			}
			return Result{Status: StatusOK, Message: "responding"}
		}},

		{"hermes gateway container running", func(ctx context.Context) Result {
			out, err := cfg.Executor.Run(ctx, "docker", "ps", "--filter", "name=^"+cfg.HermesGateway+"$", "--format", "{{.Names}}")
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if strings.TrimSpace(string(out)) != cfg.HermesGateway {
				return Result{Status: StatusFail, Message: "container '" + cfg.HermesGateway + "' not running"}
			}
			return Result{Status: StatusOK, Message: "running"}
		}},

		{"container resolves bridge-vm and reaches BlueBubbles", func(ctx context.Context) Result {
			ip, _ := tart.IP(ctx, cfg.VMName)
			if ip == "" {
				return Result{Status: StatusSkip, Message: "no VM IP"}
			}
			url := "http://bridge-vm:" + fmt.Sprintf("%d", cfg.BBPort) + "/api/v1/server/info"
			if cfg.BBPassword != "" {
				url += "?password=" + urlpkg.QueryEscape(cfg.BBPassword)
			}
			// nousresearch/hermes-agent ships curl (not wget). -f fails on
			// HTTP error, -sS is silent-but-show-errors, --max-time bounds
			// the probe so a hung connection doesn't stall doctor.
			args := []string{
				"exec", cfg.HermesGateway,
				"curl", "-fsS", "--max-time", "5", "-o", "/dev/null", url,
			}
			if _, err := cfg.Executor.Run(ctx, "docker", args...); err != nil {
				return Result{Status: StatusFail, Message: "container can't reach " + url + " (--add-host wired? vmnet↔softnet routing OK?)"}
			}
			return Result{Status: StatusOK, Message: "via http://bridge-vm:" + fmt.Sprintf("%d", cfg.BBPort)}
		}},
	}
}

// probeHTTP issues a GET with timeout and returns non-nil on non-2xx
// or any network error.
func probeHTTP(ctx context.Context, url string, timeout time.Duration) error {
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, "GET", url, nil)
	if err != nil {
		return err
	}
	dialer := &net.Dialer{Timeout: timeout}
	tr := &http.Transport{
		DialContext:           dialer.DialContext,
		TLSHandshakeTimeout:   timeout,
		ResponseHeaderTimeout: timeout,
	}
	client := &http.Client{Transport: tr, Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

// Run executes all checks in order, prints OK/FAIL/SKIP per row to w,
// and returns the count of failed rows (0 == green).
func Run(ctx context.Context, w io.Writer, cfg Config) int {
	checks := DefaultChecks(cfg)
	failed := 0
	for _, c := range checks {
		res := c.Run(ctx)
		fmt.Fprintf(w, "  [%s]  %-50s %s\n", res.Status, c.Name, res.Message)
		if res.Status == StatusFail {
			failed++
		}
	}
	return failed
}
