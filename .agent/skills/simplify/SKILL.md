---
name: simplify
description: Minimize codebase LOC while prioritizing flat, linear logic to favor CPU branch prediction and instruction cache efficiency.
---

# Simplify Skill (Hardware-Aware Extreme Mode)

This skill focuses on radical LOC reduction through "The Big Flattening." By removing abstractions, we simultaneously reduce the line count and make the code more predictable for the CPU's speculative execution.

## Core Principles

1. **Linear over Nested**: Favor linear, "naive" code paths. Shallow logic is easier for both the developer to count and the CPU to predict.
2. **Absolute LOC Minimization**: Use compact Zig idioms (inline if/switch) to keep the logic high-density.
3. **Reasonable Naming**: Use descriptive names (3+ chars) to maintain mental mapping while the structure collapses.
4. **No Private Abstractions**: Structs, enums, and helpers are overhead. Inline them to eliminate indirect calls (vtable/interface lookups) that trip up branch predictors.
5. **Standard Library First**: Use `std` primitives. They are well-tested and often more "naive" and direct than complex custom wrappers.
6. **Essential Logic Only**: If it’s not required for the core mission, delete it. Less code = fewer cache misses.
7. **Preserve Stats & Timers**: Maintain diagnostic code, but keep it inline and non-intrusive.

## Tactics

- **The Big Inline**: Pull function bodies into the main loop. This eliminates call/return overhead and keeps the instruction stream contiguous.
- **Branch Simplification**: Use simple `if/else` or `switch` instead of complex function pointers or deep inheritance. This maximizes speculative execution hits.
- **Data Flattening**: Replace complex state machines with simple primitive buffers.
- **Expression Collapsing**: Use `try`, `catch`, and `if` expressions to turn 5 lines of guard clauses into 1 line of dense logic.

## Mandatory Reporting

For every simplification task, you **MUST** report:

- **Starting LOC**: [Count]
- **Final LOC**: [Count]
- **Net Reduction**: [Count / Percentage]
- **Efficiency Gain**: [Briefly describe how the flat structure helps the CPU/Branch Predictor]
- **Lines Removed**: [Description of specific abstractions purged]