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

# Format Sources and Tests in place
fmt:
    swift format --in-place --recursive Sources Tests
