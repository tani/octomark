# OctoMark

OctoMark is an ultra-high performance, streaming Markdown parser written in pure C99. It is designed for environments where parsing speed and memory efficiency are critical, such as real-time editors, high-traffic servers, or resource-constrained systems.

## Key Features

- **Extreme Performance**: Achieves typical throughput of **0.6+ GB/s** (over 650 MB/s) on modern hardware.
- **Pure C99**: No external dependencies beyond the C standard library. Highly portable.
- **Streaming First**: Built-in support for chunked data processing using a persistent state and leftover buffer management.
- **Buffer Passing Architecture**: Minimizes memory allocations by using a flexible buffer management system.
- **Turbo Optimized**:
  - **SWAR Scanning**: Scans 8 bytes at a time for special characters using bit-masking.
  - **Zero-Allocation Metadata**: Uses stack-based bitsets and fixed-size arrays for list nesting and table alignments.
  - **Alias Resolution**: Leverages C99 `restrict` pointers to maximize compiler optimization and vectorization.

## Performance Benchmark

On an M-series Mac / modern x86_64, OctoMark C99 implementation shows:

- **Speed**: ~0.65 GB/s
- **Correctness**: Passes 100% of the cross-platform test suite (25+ cases including Tables, Math, and Lists).

## Syntax Support

OctoMark supports GFM-like Markdown with extensions:

- **Block Elements**: Headers, Lists (Ordered/Unordered), Blockquotes, Fenced Code Blocks, Tables, Horizontal Rules, Task Lists.
- **Inline Elements**: Bold, Italic, Strikethrough, Inline Code, Links, Images, Autolinks.
- **Extensions**: Math support (Block `$$` and Inline `$`).

## Getting Started

### Compilation

Use any C99-compliant compiler with high optimization flags:

```bash
gcc -O3 -std=c99 octomark.c -o octomark
```

### Usage as a CLI / Benchmark

Running the built binary executes the internal performance benchmark:

```bash
./octomark
```

### Integration

To use OctoMark in your own project, include the logic from `octomark.c` (or define `OCTOMARK_NO_MAIN` to include it as a header-like file).

```c
#define OCTOMARK_NO_MAIN
#include "octomark.c"

int main() {
    OctoMark om;
    octomark_init(&om);
    
    Buffer output;
    buf_init(&output, 4096);
    
    const char *chunk = "# Hello Octo\nStream data here.";
    octomark_feed(&om, chunk, strlen(chunk), &output);
    octomark_finish(&om, &output);
    
    printf("%s", output.data);
    
    buf_free(&output);
    octomark_free(&om);
    return 0;
}
```

## Testing

A correctness test suite is provided in `test.c` which mirrors the JavaScript benchmark suite.

```bash
gcc -O3 -std=c99 test.c -o test_runner
./test_runner
```

## License

MIT License
