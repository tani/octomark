#!/bin/bash
set -e

# Build the project
echo "Building Octomark..."
zig build -Doptimize=ReleaseSafe

# Run the compliance tests
echo "Running CommonMark spec tests..."
python3 commonmark-spec/test/spec_tests.py --program "./zig-out/bin/octomark" --spec commonmark-spec/spec.txt "$@"
