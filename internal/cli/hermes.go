package cli

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/intinig/vm-claw/internal/hermes"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

const (
	defaultBBPort = 1234
)

func init() {
	hermesCmd := &cobra.Command{
		Use:   "hermes",
		Short: "Manage the host-side Hermes Docker stack",
	}

	hermesBootstrapCmd := &cobra.Command{
		Use:   "bootstrap",
		Short: "Install Colima/docker, start Colima, pull Hermes images, create ~/.hermes",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			out := cmd.OutOrStdout()

			fmt.Fprintln(out, "==> Ensuring brew + container runtime")
			if err := hermes.EnsureBrewInstalled(ctx, vm.DefaultExecutor); err != nil {
				return err
			}
			if err := hermes.EnsurePackagesInstalled(ctx, vm.DefaultExecutor, "colima", "docker", "docker-compose"); err != nil {
				return err
			}

			fmt.Fprintln(out, "==> Starting Colima")
			colima := hermes.NewColima()
			cfg := hermes.DefaultColimaConfig()
			if err := colima.Start(ctx, cfg); err != nil {
				return err
			}

			fmt.Fprintln(out, "==> Pulling Hermes images")
			docker := hermes.NewDocker()
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			hcfg := hermes.DefaultHermesConfig(home)
			if err := docker.PullImage(ctx, hcfg.Image); err != nil {
				return err
			}
			if err := docker.PullImage(ctx, hcfg.SandboxImage); err != nil {
				return err
			}

			fmt.Fprintln(out, "==> Preparing ~/.hermes")
			if err := os.MkdirAll(hcfg.HermesHome, 0o700); err != nil {
				return fmt.Errorf("mkdir %s: %w", hcfg.HermesHome, err)
			}

			fmt.Fprintln(out, "==> Ensuring docker network")
			if err := docker.EnsureNetwork(ctx, hcfg.Network); err != nil {
				return err
			}

			fmt.Fprintln(out, "[OK]    hermes bootstrap complete")
			return nil
		},
	}

	hermesWireCmd := &cobra.Command{
		Use:   "wire",
		Short: "Write BlueBubbles config to ~/.hermes/.env and restart Hermes gateway",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			out := cmd.OutOrStdout()

			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			secretPath := filepath.Join(home, ".hermes", ".bb-webhook-secret")
			envPath := filepath.Join(home, ".hermes", ".env")

			secret, err := loadSecretOrErr(secretPath)
			if err != nil {
				return err
			}

			tart := vm.NewTart()
			ip, err := tart.IP(ctx, vmName)
			if err != nil {
				return err
			}
			if ip == "" {
				return fmt.Errorf("VM %q not running; run `vmclaw vm run` or load the LaunchAgent first", vmName)
			}

			password, err := promptPassword(out, "BlueBubbles admin password: ")
			if err != nil {
				return err
			}

			// Validate the password against BlueBubbles' API.
			if err := probeBlueBubblesAuth(ctx, ip, defaultBBPort, password); err != nil {
				return fmt.Errorf("password rejected by BlueBubbles: %w", err)
			}

			// Persist BlueBubbles connector keys.
			updates := map[string]string{
				hermes.BluebubblesServerURLKey:     "http://bridge-vm:" + fmt.Sprintf("%d", defaultBBPort),
				hermes.BluebubblesPasswordKey:      password,
				hermes.BluebubblesWebhookSecretKey: secret,
			}
			if err := hermes.UpdateEnvFile(envPath, updates); err != nil {
				return err
			}
			fmt.Fprintf(out, "[OK]    wrote %d keys to %s\n", len(updates), envPath)

			// Restart gateway with --add-host bridge-vm:<ip>.
			docker := hermes.NewDocker()
			hcfg := hermes.DefaultHermesConfig(home)
			fmt.Fprintf(out, "[DOING] restarting %q with --add-host bridge-vm:%s\n", hcfg.GatewayName, ip)
			if err := docker.RunHermesGateway(ctx, hcfg, ip); err != nil {
				return err
			}
			fmt.Fprintln(out, "[OK]    Hermes gateway running")
			return nil
		},
	}

	hermesCmd.AddCommand(hermesBootstrapCmd, hermesWireCmd)
	rootCmd.AddCommand(hermesCmd)
}

// loadSecretOrErr returns a friendly error if the secret file is missing.
func loadSecretOrErr(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("missing %s — run `vmclaw bootstrap` first to generate it", path)
		}
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

// promptPassword prints a prompt to w and reads a masked password from stdin.
// Falls back to non-masked read if stdin isn't a terminal (e.g., piped tests).
func promptPassword(w interface {
	Write([]byte) (int, error)
}, prompt string) (string, error) {
	fmt.Fprint(w, prompt)
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		var s string
		if _, err := fmt.Fscanln(os.Stdin, &s); err != nil {
			return "", err
		}
		return s, nil
	}
	b, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(w)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// probeBlueBubblesAuth verifies the password by hitting
// /api/v1/server/info?password=<pw>. Confirm the actual liveness/auth
// path against current BlueBubbles docs at implementation time.
func probeBlueBubblesAuth(ctx context.Context, ip string, port int, password string) error {
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	url := fmt.Sprintf("http://%s:%d/api/v1/server/info?password=%s", ip, port, password)
	req, err := http.NewRequestWithContext(cctx, "GET", url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return fmt.Errorf("HTTP %d (wrong password?)", resp.StatusCode)
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("HTTP %d (BlueBubbles unhealthy?)", resp.StatusCode)
	}
	return nil
}
