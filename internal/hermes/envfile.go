package hermes

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

// BlueBubbles connector key names. Confirmed against Hermes docs at
// https://hermes-agent.nousresearch.com/docs/user-guide/messaging/bluebubbles.
//
// Hermes' BlueBubbles connector authenticates incoming webhooks by
// SENDER IDENTITY (DM-pairing flow or BLUEBUBBLES_ALLOWED_USERS
// allowlist), NOT a shared secret. There is no webhook-secret env var.
//
// BLUEBUBBLES_WEBHOOK_HOST defaults to 127.0.0.1 inside the Hermes
// container, which means Docker's `-p` port-publish has no effect
// because the listener never binds outside the container's loopback.
// We force 0.0.0.0 so the published port is reachable from the bridge VM.
const (
	BluebubblesServerURLKey   = "BLUEBUBBLES_SERVER_URL"
	BluebubblesPasswordKey    = "BLUEBUBBLES_PASSWORD"
	BluebubblesWebhookHostKey = "BLUEBUBBLES_WEBHOOK_HOST"
)

// parseEnvFile parses a dotenv-style file body into a map. Lines starting
// with `#` and blank lines are ignored. The first `=` separates key and
// value; everything after the `=` is the value as-is (no quote stripping,
// no comment stripping after `#` — values containing `#` are valid).
func parseEnvFile(body string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(body, "\n") {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		idx := strings.Index(line, "=")
		if idx <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		val := line[idx+1:]
		out[key] = val
	}
	return out
}

// renderEnvFile rewrites original by replacing values for keys present
// in updates, preserving unknown keys, comments, and overall ordering.
// Keys in updates that don't exist in original are appended at the end
// in deterministic (sorted) order.
func renderEnvFile(original string, updates map[string]string) string {
	var b strings.Builder
	seen := map[string]bool{}

	lines := strings.Split(original, "\n")
	// Drop a single trailing empty line so we don't double-up newlines.
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}

	for _, line := range lines {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			b.WriteString(line)
			b.WriteByte('\n')
			continue
		}
		idx := strings.Index(line, "=")
		if idx <= 0 {
			b.WriteString(line)
			b.WriteByte('\n')
			continue
		}
		key := strings.TrimSpace(line[:idx])
		if newVal, ok := updates[key]; ok {
			b.WriteString(key)
			b.WriteByte('=')
			b.WriteString(newVal)
			b.WriteByte('\n')
			seen[key] = true
		} else {
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}

	// Append new keys in deterministic order so re-runs produce stable output.
	var newKeys []string
	for k := range updates {
		if !seen[k] {
			newKeys = append(newKeys, k)
		}
	}
	sort.Strings(newKeys)
	for _, k := range newKeys {
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(updates[k])
		b.WriteByte('\n')
	}
	return b.String()
}

// parentDir returns path's directory.
func parentDir(path string) string {
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[:i]
	}
	return "."
}

// UpdateEnvFile reads the env file at path (or starts from empty if
// absent), merges in updates, writes back at mode 0600. Creates parent
// dir at mode 0700 if missing.
func UpdateEnvFile(path string, updates map[string]string) error {
	if err := os.MkdirAll(parentDir(path), 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", parentDir(path), err)
	}
	// MkdirAll only applies the mode to newly-created dirs. If the parent
	// already exists at a looser mode (very common: the upstream Hermes
	// setup wizard creates ~/.hermes at the user's umask default 0755),
	// tighten it now. Best-effort: if we don't own the dir, skip silently.
	if err := os.Chmod(parentDir(path), 0o700); err != nil && !os.IsPermission(err) {
		return fmt.Errorf("chmod %s: %w", parentDir(path), err)
	}
	var original string
	if b, err := os.ReadFile(path); err == nil {
		original = string(b)
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("read %s: %w", path, err)
	}

	rendered := renderEnvFile(original, updates)

	if err := os.WriteFile(path, []byte(rendered), 0o600); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}
