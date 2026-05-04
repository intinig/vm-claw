package hermes

import (
	"context"
	"fmt"
	"strings"

	"github.com/intinig/vm-claw/internal/vm"
)

// HermesConfig is the per-profile configuration for the Hermes container
// stack. Mirrors the env vars that the deleted hermes-setup.sh consumed.
type HermesConfig struct {
	ProfileName   string // hermes profile (default: "default")
	HermesHome    string // host data dir bind-mounted to /opt/data
	GatewayName   string // gateway container name
	DashboardName string // dashboard container name
	GatewayPort   int    // host port for gateway
	DashboardPort int    // host port for dashboard
	Network       string // docker network shared by gateway+dashboard
	Image         string // hermes-agent image ref
	SandboxImage  string // sandbox image (nikolaik/python-nodejs)
}

// DefaultHermesConfig is the standard config for profile "default".
func DefaultHermesConfig(homeDir string) HermesConfig {
	return HermesConfig{
		ProfileName:   "default",
		HermesHome:    homeDir + "/.hermes",
		GatewayName:   "hermes",
		DashboardName: "hermes-dashboard",
		GatewayPort:   8642,
		DashboardPort: 9119,
		Network:       "hermes-net-default",
		Image:         "nousresearch/hermes-agent:latest",
		SandboxImage:  "nikolaik/python-nodejs:python3.11-nodejs20",
	}
}

// Docker wraps the docker CLI.
type Docker struct {
	exec vm.Executor
}

func NewDocker() *Docker { return &Docker{exec: vm.DefaultExecutor} }

// PullImage pulls an image. Idempotent (docker re-uses cached layers).
func (d *Docker) PullImage(ctx context.Context, image string) error {
	if _, err := d.exec.Run(ctx, "docker", "pull", image); err != nil {
		return fmt.Errorf("docker pull %s: %w", image, err)
	}
	return nil
}

// EnsureNetwork creates the named docker network if it doesn't exist.
func (d *Docker) EnsureNetwork(ctx context.Context, name string) error {
	if _, err := d.exec.Run(ctx, "docker", "network", "inspect", name); err == nil {
		return nil
	}
	if _, err := d.exec.Run(ctx, "docker", "network", "create", name); err != nil {
		return fmt.Errorf("docker network create %s: %w", name, err)
	}
	return nil
}

// ContainerExists returns true if a container with the given name exists
// (running or stopped).
func (d *Docker) ContainerExists(ctx context.Context, name string) (bool, error) {
	out, err := d.exec.Run(ctx, "docker", "ps", "-a", "--filter", "name=^"+name+"$", "--format", "{{.Names}}")
	if err != nil {
		return false, fmt.Errorf("docker ps: %w", err)
	}
	return strings.TrimSpace(string(out)) == name, nil
}

// ContainerRunning returns true if the named container exists and is running.
func (d *Docker) ContainerRunning(ctx context.Context, name string) (bool, error) {
	out, err := d.exec.Run(ctx, "docker", "ps", "--filter", "name=^"+name+"$", "--format", "{{.Names}}")
	if err != nil {
		return false, fmt.Errorf("docker ps: %w", err)
	}
	return strings.TrimSpace(string(out)) == name, nil
}

// RemoveContainer stops and removes a container by name. No-op if absent.
func (d *Docker) RemoveContainer(ctx context.Context, name string) error {
	exists, err := d.ContainerExists(ctx, name)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	_, _ = d.exec.Run(ctx, "docker", "stop", name) // best effort
	if _, err := d.exec.Run(ctx, "docker", "rm", "-f", name); err != nil {
		return fmt.Errorf("docker rm: %w", err)
	}
	return nil
}

// RunHermesGateway starts the gateway container with --add-host
// bridge-vm:<bridgeIP>. Removes any existing container with the same
// name first.
func (d *Docker) RunHermesGateway(ctx context.Context, cfg HermesConfig, bridgeIP string) error {
	if err := d.RemoveContainer(ctx, cfg.GatewayName); err != nil {
		return err
	}
	args := []string{
		"run", "-d",
		"--name", cfg.GatewayName,
		"--restart", "unless-stopped",
		"--network", cfg.Network,
		"--add-host", "bridge-vm:" + bridgeIP,
		"-v", cfg.HermesHome + ":/opt/data",
		"-p", fmt.Sprintf("%d:8642", cfg.GatewayPort),
		"--memory", "4g",
		"--cpus", "2",
		"--shm-size", "1g",
		cfg.Image,
		"gateway", "run",
	}
	if _, err := d.exec.Run(ctx, "docker", args...); err != nil {
		return fmt.Errorf("docker run hermes gateway: %w", err)
	}
	return nil
}
