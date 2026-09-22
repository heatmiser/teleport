# These variables are extracted from build.assets/Makefile so they can be imported
# by other Makefiles

HOST_ARCH := $(shell uname -m)

RUNTIME_ARCH_x86_64 := amd64
# uname returns different value on Linux (aarch64) and macOS (arm64).
RUNTIME_ARCH_arm64 := arm64
RUNTIME_ARCH_aarch64 := arm64
RUNTIME_ARCH := $(RUNTIME_ARCH_$(HOST_ARCH))

HOST_GOARCH := $(shell GOTOOLCHAIN=local go env GOARCH 2>/dev/null)
ARCH ?= $(if $(HOST_GOARCH),$(HOST_GOARCH),$(RUNTIME_ARCH))
