// Package hermes manages the host-side Hermes Docker stack: Colima,
// docker daemon, the ~/.hermes data directory, and the BlueBubbles
// webhook secret reused across bootstrap and finalize.
package hermes

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
)

// generateSecret returns 32 random bytes hex-encoded (64 hex chars).
// Used as the shared secret between BlueBubbles' webhook config and the
// Hermes BlueBubbles connector's expected Authorization Bearer token.
func generateSecret() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("crypto/rand: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// persistSecret writes secret to path with permissions 0600. Creates
// parent directories if missing (mode 0700).
func persistSecret(path, secret string) error {
	if err := os.MkdirAll(parentDir(path), 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", parentDir(path), err)
	}
	if err := os.WriteFile(path, []byte(secret+"\n"), 0o600); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// loadSecret reads a previously-persisted secret from path. Trims trailing
// whitespace.
func loadSecret(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	return strings.TrimSpace(string(b)), nil
}

// EnsureSecret reads the persisted webhook secret at path, or generates +
// persists a fresh one if absent. The secret is generated exactly once
// per host and never rotated automatically — rotating means BlueBubbles'
// webhook config has to be re-edited too. Idempotent across re-runs of
// vmclaw bootstrap.
func EnsureSecret(path string) (string, error) {
	if existing, err := loadSecret(path); err == nil && existing != "" {
		return existing, nil
	}
	fresh, err := generateSecret()
	if err != nil {
		return "", err
	}
	if err := persistSecret(path, fresh); err != nil {
		return "", err
	}
	return fresh, nil
}

// parentDir returns path's directory.
func parentDir(path string) string {
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[:i]
	}
	return "."
}
