---
name: compliance_test
description: Run Octomark against the CommonMark spec tests to check for compliance.
---

# Compliance Test Skill

This skill allows you to verify Octomark's compliance with the CommonMark specification using the official spec tests.

## Prerequisites

- Python 3
- The `commonmark-spec` submodule must be present in the root directory.
- `zig` must be installed to build the project.

## Usage

### Using the helper script

The easiest way to run the tests is using the provided helper script:

```bash
./scripts/compliance.sh
```

You can also pass additional arguments to the script (like `-P` or `-n`):

```bash
./scripts/compliance.sh -P "Links"
```

### Manual Usage

If you prefer to run it manually:

```bash
# Build the project first
zig build -Doptimize=ReleaseSafe

# Run the spec tests
python3 commonmark-spec/test/spec_tests.py --program "./zig-out/bin/octomark" --spec commonmark-spec/spec.txt
```

### Run a specific test section

You can limit the tests to a specific section (e.g., "Links") using the `-P` or `--pattern` flag:

```bash
python3 commonmark-spec/test/spec_tests.py --program "./zig-out/bin/octomark" --spec commonmark-spec/spec.txt --pattern "Links"
```

### Run a single example

Each test in the spec has a number. Use `-n` to run a specific example:

```bash
python3 commonmark-spec/test/spec_tests.py --program "./zig-out/bin/octomark" --spec commonmark-spec/spec.txt -n 123
```

## Interpreting Results

Octomark focuses on extreme performance and streaming efficiency. Some CommonMark edge cases (especially those requiring multiple passes, like complex reference links) might fail. The goal is to maximize compliance without sacrificing the O(N) performance target.

Common failures to ignore or monitor:

- **Reference Links**: Octomark currently focuses on inline links.
- **HTML Normalization**: Minor differences in HTML tag self-closing or whitespace.
- **Deep Nesting**: Octomark has a maximum nesting limit for security.
