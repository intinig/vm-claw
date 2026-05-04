package cli

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/intinig/vm-claw/internal/doctor"
	"github.com/intinig/vm-claw/internal/hermes"
	"github.com/intinig/vm-claw/internal/launchagent"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

func init() {
	bootstrapCmd := &cobra.Command{
		Use:   "bootstrap",
		Short: "Run all automatable pre-Phase-2 setup steps",
		Long: "Bootstrap creates the bridge VM, bootstraps the Hermes Docker stack, " +
			"installs the auto-start LaunchAgent, generates the BlueBubbles webhook secret, " +
			"and prints the manual Phase 2 runbook. Safe to re-run.",
		RunE: runBootstrap,
	}

	bootstrapFinalizeCmd := &cobra.Command{
		Use:   "finalize",
		Short: "Run all post-Phase-2 wiring + final healthcheck",
		Long:  "Reads stashed webhook secret, prompts for BlueBubbles password, writes ~/.hermes/.env, restarts the Hermes gateway with --add-host, runs doctor.",
		RunE:  runBootstrapFinalize,
	}

	bootstrapCmd.AddCommand(bootstrapFinalizeCmd)
	rootCmd.AddCommand(bootstrapCmd)
}

func runBootstrap(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	out := cmd.OutOrStdout()

	fmt.Fprintln(out, "==> Checking prerequisites")
	if _, err := exec.LookPath("tart"); err != nil {
		return fmt.Errorf("tart not on PATH (brew install cirruslabs/cli/tart)")
	}
	if _, err := exec.LookPath("softnet"); err != nil {
		return fmt.Errorf("softnet not on PATH (brew install cirruslabs/cli/softnet)")
	}
	if err := vm.VmnetCollisionCheck(); err != nil {
		return err
	}
	fmt.Fprintln(out, "[OK]    prerequisites")

	fmt.Fprintln(out, "==> Creating bridge VM")
	tart := vm.NewTart()
	exists, err := tart.Exists(ctx, defaultVMName)
	if err != nil {
		return err
	}
	if exists {
		fmt.Fprintf(out, "[SKIP]  VM %q already exists\n", defaultVMName)
	} else {
		fmt.Fprintf(out, "[DOING] tart clone %s %s\n", defaultBaseImage, defaultVMName)
		if err := tart.Clone(ctx, defaultBaseImage, defaultVMName); err != nil {
			return err
		}
		fmt.Fprintf(out, "[OK]    VM %q ready\n", defaultVMName)
	}

	fmt.Fprintln(out, "==> Bootstrapping Hermes host stack")
	if err := hermes.EnsureBrewInstalled(ctx, vm.DefaultExecutor); err != nil {
		return err
	}
	if err := hermes.EnsurePackagesInstalled(ctx, vm.DefaultExecutor, "colima", "docker", "docker-compose"); err != nil {
		return err
	}
	if err := hermes.NewColima().Start(ctx, hermes.DefaultColimaConfig()); err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	hcfg := hermes.DefaultHermesConfig(home)
	if err := hermes.NewDocker().PullImage(ctx, hcfg.Image); err != nil {
		return err
	}
	if err := hermes.NewDocker().PullImage(ctx, hcfg.SandboxImage); err != nil {
		return err
	}
	if err := os.MkdirAll(hcfg.HermesHome, 0o700); err != nil {
		return err
	}
	// MkdirAll only applies the mode to newly-created dirs.
	// Tighten if pre-existing.
	if err := os.Chmod(hcfg.HermesHome, 0o700); err != nil && !os.IsPermission(err) {
		return fmt.Errorf("chmod %s: %w", hcfg.HermesHome, err)
	}
	if err := hermes.NewDocker().EnsureNetwork(ctx, hcfg.Network); err != nil {
		return err
	}
	fmt.Fprintln(out, "[OK]    hermes bootstrap")

	fmt.Fprintln(out, "==> Installing bridge-vm LaunchAgent")
	tartPath, err := exec.LookPath("tart")
	if err != nil {
		return err
	}
	if err := launchagent.Install(ctx, vm.DefaultExecutor, home, launchagent.Options{
		Label:    launchagent.DefaultLabel,
		TartPath: tartPath,
		VMName:   defaultVMName,
	}); err != nil {
		return err
	}
	fmt.Fprintln(out, "[OK]    LaunchAgent loaded")

	printPhase2Runbook(out)
	return nil
}

func printPhase2Runbook(out io.Writer) {
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "================================================================")
	fmt.Fprintln(out, "==> Pre-Phase-2 setup complete. NEXT STEP: manual VM provisioning.")
	fmt.Fprintln(out, "================================================================")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "1. Wait for the LaunchAgent to boot the VM (next user login)")
	fmt.Fprintln(out, "   OR run `vmclaw vm run` in another terminal now.")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "2. Inside the VM, complete the runbook in")
	fmt.Fprintln(out, "   docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md#vm-provisioning-runbook")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "3. In BlueBubbles Server → Settings → API → Webhooks, register a webhook")
	fmt.Fprintln(out, "   pointing at the host's softnet-gateway IP (visible from inside the VM via")
	fmt.Fprintln(out, "   `route -n get default | awk '/gateway/{print $2}'`):")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "       http://<softnet-gw-ip>:8645/bluebubbles-webhook")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "   No auth header — Hermes authenticates by sender identity. After the first")
	fmt.Fprintln(out, "   inbound message, Hermes sends a pairing code via iMessage; approve it on")
	fmt.Fprintln(out, "   the host with `hermes pairing approve bluebubbles <CODE>` (or pre-allowlist")
	fmt.Fprintln(out, "   senders via BLUEBUBBLES_ALLOWED_USERS in ~/.hermes/.env).")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "4. When BlueBubbles is up and the webhook is configured, return here and run:")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "       vmclaw bootstrap finalize")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "================================================================")
}

func runBootstrapFinalize(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	out := cmd.OutOrStdout()

	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}

	tart := vm.NewTart()
	ip, err := tart.IP(ctx, defaultVMName)
	if err != nil {
		return err
	}
	if ip == "" {
		return fmt.Errorf("VM %q not running (load LaunchAgent or run `vmclaw vm run` first)", defaultVMName)
	}

	fmt.Fprintln(out, "==> Probing BlueBubbles liveness")
	if err := probeBlueBubblesLiveness(ctx, ip, defaultBBPort); err != nil {
		return fmt.Errorf("BlueBubbles not reachable at %s:%d (Phase 2 incomplete?): %w", ip, defaultBBPort, err)
	}
	fmt.Fprintln(out, "[OK]    BlueBubbles responding")

	// Three states for the Hermes container:
	//   1. Not wired (env missing keys / wrong --add-host): full wire (prompts password).
	//   2. Wired but container stopped (e.g., user ran `docker stop hermes` for
	//      `hermes setup`): just `docker start` it — no prompt, config is intact.
	//   3. Wired and running: nothing to do.
	docker := hermes.NewDocker()
	switch {
	case !alreadyWired(ctx, home, ip):
		fmt.Fprintln(out, "==> Wiring Hermes BlueBubbles connector")
		if err := runHermesWireCmd(ctx, out, ip); err != nil {
			return err
		}
	case !containerRunning(ctx, docker, "hermes"):
		fmt.Fprintln(out, "==> Hermes container stopped; starting")
		if _, err := vm.DefaultExecutor.Run(ctx, "docker", "start", "hermes"); err != nil {
			return fmt.Errorf("docker start hermes: %w", err)
		}
		fmt.Fprintln(out, "[OK]    started")
	default:
		fmt.Fprintln(out, "[SKIP]  Hermes already wired and running")
	}

	fmt.Fprintln(out, "==> Running doctor")
	failed := doctor.Run(ctx, out, doctor.Config{
		Executor:      vm.DefaultExecutor,
		VMName:        defaultVMName,
		BBPort:        defaultBBPort,
		BBPassword:    readBBPasswordFromEnvFile(filepath.Join(home, ".hermes", ".env")),
		HermesGateway: "hermes",
	})
	if failed > 0 {
		return fmt.Errorf("%d check(s) FAILED — finalize incomplete", failed)
	}
	fmt.Fprintln(out, "[OK]    bootstrap complete")
	return nil
}

// probeBlueBubblesLiveness checks BlueBubbles is up by hitting
// /api/v1/server/info without a password. Treats 200, 401, 403 all
// as "BB is up and accepting requests" — the password-validation
// step happens later in runHermesWireCmd via probeBlueBubblesAuth.
//
// Confirm against current BlueBubbles docs at implementation time —
// if a public auth-less endpoint exists, switch this to use it.
func probeBlueBubblesLiveness(ctx context.Context, ip string, port int) error {
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	url := fmt.Sprintf("http://%s:%d/api/v1/server/info", ip, port)
	req, err := http.NewRequestWithContext(cctx, "GET", url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == 200:
		return nil
	case resp.StatusCode == 401 || resp.StatusCode == 403:
		return nil
	default:
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
}

// containerRunning is a small wrapper that swallows errors and returns
// false on any failure — finalize uses this only as a branch hint, not
// a hard precondition. The downstream `doctor` step is the source of
// truth for "is the gateway actually serving."
func containerRunning(ctx context.Context, d *hermes.Docker, name string) bool {
	running, err := d.ContainerRunning(ctx, name)
	if err != nil {
		return false
	}
	return running
}

// alreadyWired reports whether the Hermes container is already running
// with BlueBubbles config matching the current state — that is, the
// three connector keys are in ~/.hermes/.env AND the running gateway
// container has --add-host bridge-vm:<current-ip> baked in. When true,
// `vmclaw bootstrap finalize` skips the password prompt and gateway
// restart and just runs doctor.
//
// Spec invariant: bootstrap finalize is safe to re-run; detects
// "already wired" and short-circuits to doctor only.
func alreadyWired(ctx context.Context, home, ip string) bool {
	envPath := filepath.Join(home, ".hermes", ".env")
	body, err := os.ReadFile(envPath)
	if err != nil {
		return false
	}
	text := string(body)
	for _, key := range []string{
		hermes.BluebubblesServerURLKey,
		hermes.BluebubblesPasswordKey,
		hermes.BluebubblesWebhookHostKey,
	} {
		if !strings.Contains(text, key+"=") {
			return false
		}
	}
	out, err := vm.DefaultExecutor.Run(ctx, "docker", "inspect", "hermes",
		"--format", "{{range .HostConfig.ExtraHosts}}{{.}}\n{{end}}")
	if err != nil {
		return false
	}
	return strings.Contains(string(out), "bridge-vm:"+ip)
}

// runHermesWireCmd inlines what `vmclaw hermes wire` would do, with
// the bridge IP already known. Avoids re-resolving the IP and
// re-validating preconditions.
func runHermesWireCmd(ctx context.Context, out io.Writer, ip string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	password, err := promptPassword(out, "BlueBubbles admin password: ")
	if err != nil {
		return err
	}
	if err := probeBlueBubblesAuth(ctx, ip, defaultBBPort, password); err != nil {
		return fmt.Errorf("password rejected by BlueBubbles: %w", err)
	}
	updates := map[string]string{
		hermes.BluebubblesServerURLKey:   "http://bridge-vm:" + fmt.Sprintf("%d", defaultBBPort),
		hermes.BluebubblesPasswordKey:    password,
		hermes.BluebubblesWebhookHostKey: "0.0.0.0",
	}
	envPath := filepath.Join(home, ".hermes", ".env")
	if err := hermes.UpdateEnvFile(envPath, updates); err != nil {
		return err
	}
	fmt.Fprintf(out, "[OK]    wrote %d keys to %s\n", len(updates), envPath)

	docker := hermes.NewDocker()
	hcfg := hermes.DefaultHermesConfig(home)
	if err := docker.RunHermesGateway(ctx, hcfg, ip); err != nil {
		return err
	}
	fmt.Fprintln(out, "[OK]    Hermes gateway running with --add-host bridge-vm:"+ip)
	return nil
}
