# Agent Rules for OctoMark

- **Do not use regular expressions (RegExp)**: The parser must be 100% regex-free to ensure predictability and avoid ReDoS risks.
- **Maintain Current Computing Performance**: Any refactoring or new features must be benchmarked to ensure they do not degrade the current performance (target ~2M lines/sec).
- **Keep Linear Complexity**:
  - Use a single main loop for processing.
  - Extra loops must be of constant depth/size (O(1)) relative to the line or small windows.
  - Avoid nested loops that lead to O(n²) or worse complexity.
