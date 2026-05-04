package hermes

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

// BlueBubbles connector key names. **Placeholders** until the actual
// names are confirmed against current Hermes docs (see the spec's
// "Open / deferred items" section). Update these in a follow-up commit
// once the BlueBubbles connector docs are read.
const (
	BluebubblesServerURLKey     = "BLUEBUBBLES_SERVER_URL"
	BluebubblesPasswordKey      = "BLUEBUBBLES_PASSWORD"
	BluebubblesWebhookSecretKey = "BLUEBUBBLES_WEBHOOK_SECRET"
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

// UpdateEnvFile reads the env file at path (or starts from empty if
// absent), merges in updates, writes back at mode 0600. Creates parent
// dir at mode 0700 if missing.
func UpdateEnvFile(path string, updates map[string]string) error {
	if err := os.MkdirAll(parentDir(path), 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", parentDir(path), err)
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
