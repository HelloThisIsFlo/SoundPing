#!/usr/bin/env bash
set -euo pipefail

swift test
bash scripts/ci-sim.sh
