# OctoMark

<p align="center">
  <img width="300" src="octomark.webp">
</p>

OctoMark is an ultra-high performance, streaming Markdown parser written in Zig. It is designed for environments where parsing speed and memory efficiency are critical, such as real-time editors, high-traffic servers, or resource-constrained systems.

## Key Features

- **Extreme Performance**: Sustained throughput depends on input; see the benchmark section for local measurement.
- **Pure Zig**: No external dependencies beyond Zig's standard library. Highly portable.
- **Streaming First**: Built-in support for chunked data processing using a persistent state and leftover buffer management.
- **Buffer Passing Architecture**: Minimizes memory allocations by using a flexible buffer management system.
- **Turbo Optimized**:
  - **SWAR Scanning**: Scans 8 bytes at a time for special characters using bit-masking.
  - **Zero-Allocation Metadata**: Uses stack-based bitsets and fixed-size arrays for list nesting and table alignments.

## Performance Benchmark

The benchmark runner (`octomark-benchmark`) repeats `EXAMPLE.md` to reach target sizes and measures
streaming throughput.

```bash
zig build -Doptimize=ReleaseFast bench
```

Recent run (EXAMPLE.md on this machine, ReleaseFast):

- 10 MB: 21.74 ms (0.45 GB/s)
- 50 MB: 79.83 ms (0.61 GB/s)
- 100 MB: 158.95 ms (0.61 GB/s)
- 200 MB: 325.69 ms (0.60 GB/s)

## Syntax Support

OctoMark supports GFM-like Markdown with extensions:

- **Block Elements**: Headers, Lists (Ordered/Unordered), Blockquotes, Fenced Code Blocks, Tables, Horizontal Rules, Task Lists, Definition Lists.
- **Inline Elements**: Bold (`**strong**`), Italic (`_em_`), Strikethrough, Inline Code, Links, Images, Autolinks, Hard Line Breaks (two trailing spaces).
- **Extensions**: Math support (Block `$$` and Inline `$`).

## Getting Started

### Build

```bash
zig build -Doptimize=ReleaseFast
```

### Run as a CLI

```bash
zig build run -- < EXAMPLE.md
```

### Example Input

`EXAMPLE.md` includes a comprehensive syntax sample, including mixed and nested
constructs.

### Integration

To use OctoMark in your own Zig project, import the module and drive the parser with a standard `std.io.Reader` and `std.io.Writer`.

```zig
const std = @import("std");
const octomark = @import("octomark");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    defer parser.deinit(allocator);

    const stdout = std.io.getStdOut();
    var buffered_writer = std.io.bufferedWriter(stdout.writer());
    const writer = buffered_writer.writer();

    const input = "# Hello Octo\nStream data here.";
    var input_stream = std.io.fixedBufferStream(input);
    const reader = input_stream.reader();

    try parser.parse(reader.any(), writer.any(), allocator);
    try buffered_writer.flush();
}
```

## Testing

A correctness test suite is provided in `src/test.zig`.

```bash
zig build test
```

## License

MIT License
