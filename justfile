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

# Format Sources and Tests in place
fmt:
    swift format --in-place --recursive Sources Tests
