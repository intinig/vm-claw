# vmclaw build / install
BIN_NAME := vmclaw
BIN_DIR  := bin
PKG      := ./cmd/vmclaw

GIT_SHA     := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
VERSION     := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
LDFLAGS     := -ldflags "-X main.version=$(VERSION)+$(GIT_SHA)"

.PHONY: all build install uninstall test integration clean

all: build

build:
	@mkdir -p $(BIN_DIR)
	go build $(LDFLAGS) -o $(BIN_DIR)/$(BIN_NAME) $(PKG)

install:
	go install $(LDFLAGS) $(PKG)

uninstall:
	rm -f $$(go env GOPATH)/bin/$(BIN_NAME)

test:
	go test ./...

integration:
	go test -tags=integration ./...

clean:
	rm -rf $(BIN_DIR)
