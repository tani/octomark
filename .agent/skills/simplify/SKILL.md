---
name: simplify
description: Strictly minimize the codebase by prioritizing total lines of code reduction above all else, including readability and performance.
---

# Simplify Skill (Extreme Mode)

This skill focuses on the absolute minimization of the Octomark codebase. **Total Lines of Code (LOC) reduction is the only metric of success.**

## Core Principles

1. **Absolute LOC Minimization**: Every byte and every newline must be justified. If logic can be compressed into fewer lines (even if it becomes "ugly" or "clever"), it must be.
2. **Readability is Secondary**: Do not sacrifice a line-saving optimization for the sake of readability. High cognitive load is acceptable if the file footprint is smaller.
3. **Complexity is Secondary**: Hard-to-follow logic that uses fewer lines is preferred over simple, verbose logic.
4. **No Performance-First Logic**: Strip all code that exists only for performance (SWAR, timers, debug stats). Use idiomatic, compact Zig.
5. **Strictly `std` Only**: Any custom utility that can be replaced by a `std` call (even a slightly slower or more complex one) must be deleted.
6. **No Private Abstractions**: Structs, enums, and helper functions are bloat. Flatten them, inline them, or remove them.
7. **Delete Everything Non-Essential**: If it isn't required to pass the core tests, it is gone. This includes options, complex error handling, and "just in case" state.
8. Do not remove Stats and Timer code.

## Tactics

- **The Big Inline**: Merge specialized functions into larger blocks to save headers, scopes, and call sites.
- **Compact Expressions**: Use `if` expressions, nested calls, and `std.mem` utilities to collapse multi-line logic into single lines.
- **Flatten Data structures**: Replace stacks, specialized arrays, or complex structs with simple buffers or primitive variables if it saves lines.
- **Minimalist IO**: Remove all "interface detection" or "buffered" abstractions. Use raw `anytype` for readers/writers.
- **Consolidate Error Handling**: Use `anyerror` or a single-member error set to remove verbose error definitions and propagation.

## Mandatory Reporting

For every simplification task, you **MUST** report:
- **Starting LOC**: [Count]
- **Final LOC**: [Count]
- **Net Reduction**: [Count]
- **Lines Removed**: [Description of specific sections purged]
