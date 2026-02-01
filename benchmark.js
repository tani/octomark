import { OctoMark } from "./octomark.js";
import MarkdownIt from "npm:markdown-it";

const parser = new OctoMark();
const mdIt = new MarkdownIt();

const tests = [
    {
        name: "Heading",
        input: "# Hello World",
        expected: "<h1>Hello World</h1>\n"
    },
    {
        name: "Blockquote",
        input: "> This is a quote",
        expected: "<blockquote>This is a quote</blockquote>\n"
    },
    {
        name: "Horizontal Rule",
        input: "---",
        expected: "<hr>\n"
    },
    {
        name: "Inline Styles",
        input: "**Bold** and _Italic_ and `Code`",
        expected: "<p><strong>Bold</strong> and <em>Italic</em> and <code>Code</code></p>\n"
    },
    {
        name: "Links",
        input: "[Google](https://google.com)",
        expected: '<p><a href="https://google.com">Google</a></p>\n'
    },
    {
        name: "Escaping",
        input: "\\*Not Bold\\*",
        expected: "<p>*Not Bold*</p>\n"
    },
    {
        name: "Fenced Code Block",
        input: "```js\nconsole.log('hi');\n```",
        expected: '<pre><code class="language-js">console.log(&#39;hi&#39;);\n</code></pre>\n'
    },
    {
        name: "Unordered List",
        input: "- Item 1\n- Item 2",
        expected: "<ul>\n<li>Item 1</li>\n<li>Item 2</li>\n</ul>\n"
    },
    {
        name: "Task List",
        input: "- [ ] Todo\n- [x] Done",
        expected: '<ul>\n<li><input type="checkbox"  disabled> Todo</li>\n<li><input type="checkbox" checked disabled> Done</li>\n</ul>\n'
    },
    {
        name: "Nested List (4 spaces)",
        input: "- Level 1\n    - Level 2\n- Back to 1",
        expected: "<ul>\n<li>Level 1</li>\n<ul>\n<li>Level 2</li>\n</ul>\n<li>Back to 1</li>\n</ul>\n"
    },
    {
        name: "Table",
        input: "| Head A | Head B |\n|---|---|\n| Cell 1 | Cell 2 |",
        expected: "<table><thead><tr><th>Head A</th><th>Head B</th></tr></thead><tbody>\n<tr><td>Cell 1</td><td>Cell 2</td></tr>\n</tbody></table>\n"
    },
    {
        name: "Aligned Table",
        input: "| Left | Center | Right |\n|:---|:---:|---:|\n| A | B | C |",
        expected: '<table><thead><tr><th style="text-align:left">Left</th><th style="text-align:center">Center</th><th style="text-align:right">Right</th></tr></thead><tbody>\n<tr><td style="text-align:left">A</td><td style="text-align:center">B</td><td style="text-align:right">C</td></tr>\n</tbody></table>\n'
    },
    {
        name: "Table with Spaces in Separator",
        input: "| Head |\n|  :--- |\n| Cell |",
        expected: '<table><thead><tr><th style="text-align:left">Head</th></tr></thead><tbody>\n<tr><td style="text-align:left">Cell</td></tr>\n</tbody></table>\n'
    },
    {
        name: "Nested Inline Styles",
        input: "**_Bold Italic_**",
        expected: "<p><strong><em>Bold Italic</em></strong></p>\n"
    },
    {
        name: "Table with Inline Styles",
        input: "| **Bold** | `Code` |\n|---|---|\n| _Italic_ | [Link](url) |",
        expected: "<table><thead><tr><th><strong>Bold</strong></th><th><code>Code</code></th></tr></thead><tbody>\n<tr><td><em>Italic</em></td><td><a href=\"url\">Link</a></td></tr>\n</tbody></table>\n"
    },
    {
        name: "Code Block Escaping",
        input: "```html\n<div></div>\n```",
        expected: '<pre><code class="language-html">&lt;div&gt;&lt;/div&gt;\n</code></pre>\n'
    },
    {
        name: "Mixed List Types",
        input: "- Regular\n- [ ] Task",
        expected: "<ul>\n<li>Regular</li>\n<li><input type=\"checkbox\"  disabled> Task</li>\n</ul>\n"
    },
    {
        name: "Ordered List",
        input: "1. Item 1\n2. Item 2",
        expected: "<ol>\n<li>Item 1</li>\n<li>Item 2</li>\n</ol>\n"
    },
    {
        name: "Image",
        input: "![Octo](https://octo.com/logo.png)",
        expected: '<p><img src="https://octo.com/logo.png" alt="Octo"></p>\n'
    },
    {
        name: "Strikethrough",
        input: "~~Deleted text~~",
        expected: "<p><del>Deleted text</del></p>\n"
    },
    {
        name: "Autolink",
        input: "Search on https://google.com now",
        expected: '<p>Search on <a href="https://google.com">https://google.com</a> now</p>\n'
    },
    {
        name: "Mixed List Transformation",
        input: "- Bullet\n1. Numbered",
        expected: "<ul>\n<li>Bullet</li>\n</ul>\n<ol>\n<li>Numbered</li>\n</ol>\n"
    },
    {
        name: "Linear Paragraphs",
        input: "Line 1\nLine 2",
        expected: "<p>Line 1</p>\n<p>Line 2</p>\n"
    }
];

console.log("--- Starting Correctness Tests ---");
let passed = 0;
let failed = 0;

for (const test of tests) {
    const output = parser.parse(test.input);
    if (output === test.expected) {
        passed++;
    } else {
        console.error(`[FAIL] ${test.name}`);
        console.error(`Expected:\n${JSON.stringify(test.expected)}`);
        console.error(`Actual:\n${JSON.stringify(output)}`);
        failed++;
    }
}

console.log(`\nTest Summary: ${passed} Passed, ${failed} Failed.`);

if (failed > 0) {
    console.error("Correctness tests failed. Aborting performance benchmark.");
    Deno.exit(1);
}

// --- Performance Benchmark ---
console.log("\n--- Starting Performance Benchmark ---");

const lines = [];
for (let i = 0; i < 5000; i++) {
    lines.push(`# Heading ${i}`);
    lines.push(`- List item ${i}`);
    lines.push(`    - Nested item ${i}`);
    lines.push(`> Quote ${i}`);
    lines.push(`| Col 1 | Col 2 |`);
    lines.push(`|---|---|`);
    lines.push(`| Val ${i} | Val ${i} |`);
    lines.push("");
}
const hugeInput = lines.join("\n");

console.log(`Parsing ${lines.length} lines of Markdown...`);

const start = performance.now();
parser.parse(hugeInput);
const end = performance.now();

const duration = end - start;
console.log(`[OctoMark] Time taken: ${duration.toFixed(2)}ms`);
console.log(`[OctoMark] Speed: ${(lines.length / (duration / 1000)).toFixed(0)} lines/sec`);

console.log(`\nParsing with markdown-it...`);
const startMd = performance.now();
mdIt.render(hugeInput);
const endMd = performance.now();

const durationMd = endMd - startMd;
console.log(`[markdown-it] Time taken: ${durationMd.toFixed(2)}ms`);
console.log(`[markdown-it] Speed: ${(lines.length / (durationMd / 1000)).toFixed(0)} lines/sec`);

console.log(`\nComparison: OctoMark is ${(durationMd / duration).toFixed(2)}x faster than markdown-it`);

// --- Deeply Nested List Benchmark ---
console.log("\n--- Starting Deeply Nested List Benchmark ---");
const nestedLines = [];
for (let i = 0; i < 500; i++) {
    nestedLines.push(" ".repeat(i * 4) + "- Nest Level " + i);
}
// Unwind
for (let i = 499; i >= 0; i--) {
    nestedLines.push(" ".repeat(i * 4) + "- Nest Level " + i);
}
const nestedInput = nestedLines.join("\n");

console.log(`Parsing ${nestedLines.length} lines of Deeply Nested List...`);

const startNested = performance.now();
parser.parse(nestedInput);
const endNested = performance.now();
console.log(`[OctoMark] Nested Time: ${(endNested - startNested).toFixed(2)}ms`);

const startNestedMd = performance.now();
mdIt.render(nestedInput);
const endNestedMd = performance.now();
console.log(`[markdown-it] Nested Time: ${(endNestedMd - startNestedMd).toFixed(2)}ms`);


// --- Long Inline Benchmark ---
console.log("\n--- Starting Long Inline Benchmark ---");
const longLine = "Word ".repeat(10000) + "**Bold** " + "_Italic_ " + "`Code` ".repeat(100);
const longInput = longLine.repeat(100); // 100 huge paragraphs

console.log(`Parsing ${longInput.length} chars of Heavy Inline content...`);

const startInline = performance.now();
parser.parse(longInput);
const endInline = performance.now();
console.log(`[OctoMark] Inline Time: ${(endInline - startInline).toFixed(2)}ms`);

const startInlineMd = performance.now();
mdIt.render(longInput);
const endInlineMd = performance.now();
console.log(`[markdown-it] Inline Time: ${(endInlineMd - startInlineMd).toFixed(2)}ms`);