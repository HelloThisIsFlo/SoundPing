# SoundPing task runner. Recipes only orchestrate; the logic lives in scripts/.

# List the available recipes
default:
    @just --list

# Run the unit tests
test:
    scripts/test.sh

# Build and run the soundping CLI, e.g. `just cli --version`
cli *ARGS:
    scripts/cli.sh {{ARGS}}

# Run a simulated round trip, e.g. `just sim --json --seed 7`
sim *ARGS:
    scripts/cli.sh run round-trip --simulate {{ARGS}}

# Run the tests that need real audio hardware (a loop from the interface's output back to an input)
hw-test:
    SOUNDPING_HW=1 swift test --filter Hardware

# Measure the Phase 1 exit gates on real hardware (the loop on an audio interface); see scripts/bench.sh
bench:
    scripts/bench.sh

# Format Sources and Tests in place
fmt:
    swift format --in-place --recursive Sources Tests
