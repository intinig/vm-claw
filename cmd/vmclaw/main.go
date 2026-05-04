// Package main is the vmclaw entrypoint. Build with:
//
//	go build -ldflags "-X main.version=$(git describe --tags --always)+$(git rev-parse --short HEAD)" ./cmd/vmclaw
//
// or use the project Makefile.
package main

import (
	"os"

	"github.com/intinig/vm-claw/internal/cli"
)

// version is overridden at build time via -ldflags. Default "dev" for
// local `go run`/`go build` without ldflags.
var version = "dev"

func main() {
	cli.SetVersion(version)
	os.Exit(cli.Execute())
}
