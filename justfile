set shell := ["/bin/sh", "-eu", "-c"]

# List commands.
default:
  @just --list --unsorted

# Format the repository.
fmt:
  nix fmt

# Check formatting and run the script tests.
check:
  nix flake check -L

# Evaluate every output without building anything.
check-eval:
  nix flake check --no-build --all-systems

# Run the script tests directly.
test:
  python3 tests/network-link-recorder.py scripts/network-link-recorder.sh
  python3 tests/network-link-recorder-client.py scripts/network-link-recorder-client.sh

# Lint the scripts.
lint:
  shellcheck --shell=bash scripts/network-link-recorder.sh scripts/network-link-recorder-client.sh
