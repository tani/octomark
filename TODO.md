# Octomark TODO

- [x] Tabs/indentation: implement CommonMark tab expansion (4-space stops).
- [x] Thematic breaks & headings: ATX/Setext and thematic breaks with linear scans.
- [x] Backslash escapes: treat only punctuation escapes.
- [x] Entity decoding: numeric and named entities (fixed Null Char and Attribute decoding).
- [x] Autolinks: scheme/email validation.
- [x] Inline emphasis: delimiter rules (flanking/rule of 3).
- [x] HTML blocks: Type 1-6 classification.
- [x] Hard line breaks: trailing spaces/backslash normalization.
- [ ] List precision: refine tight/loose list detection to handle blank lines between nested items strictly.
- [x] Link robustness: support balanced parentheses in destinations `(url(nested))` and multi-line titles.
- [x] Unicode categories: expand `isPunct` and whitespace checks to support mandatory Unicode ranges via lookup tables.
- [x] HTML Block Type 7: detect generic HTML start/end tags as block-level markers (interrupting paragraphs).
- [x] GFM Task Lists: implement `[ ]` and `[x]` markers for list items.
- [x] GFM Strikethrough: fully integrate `~~` into the delimiter stack for spec-compliant nesting.
- [x] Image alt text parsing: ensure inline parsing is applied to image `alt` attributes.
- [x] Setext continuity: handle multi-line paragraph content preceding Setext underlines.
- [x] HTML Block Content Loss: fix bug where inner lines of HTML blocks are dropped during rendering (e.g., `<div>\nbar\n</div>` renders as `<div></div>`).
- [x] HTML Block Termination: ensure blocks terminate correctly and do not consume subsequent non-block content (e.g., following `*foo*`).
- [x] HTML Block Whitespace: fix indentation preservation for raw info strings (Example 185).
- [x] Entity Null Char: handle `&#0;` replacement (Example 26).
- [x] Entity in Attributes: fix entity decoding in link destinations, titles, and code info strings (Examples 32, 33, 34).

## Remaining Compliance Failures (77 Tests)

Failed Examples (from latest compliance run):
1. Backslash/References: 23, 33, 194, 195, 196, 197, 198, 200, 202, 204, 205, 206, 207, 208, 209, 210, 212, 216, 217, 218, 219, 220.
2. Lists: 319.
3. Reference links/images (skipped by design): 529, 530, 531, 532, 533, 534, 535, 536, 537, 538, 539, 540, 541, 542, 543, 544, 545, 546, 547, 551, 552, 555, 556, 557, 558, 559, 560, 561, 562, 563, 564, 565, 566, 567, 568, 569, 570, 571, 572, 573, 575, 578, 579, 584, 585, 586, 587, 588, 589, 590, 591, 593, 594, 595.

## Updated Status (Feb 3, 2026)

- Compliance run: 578 passed, 77 failed (target 80% = 520 passed achieved).
- [x] **Backslash Escapes**: handle `\\` + `\r` and `\r\n` hard breaks.
- [x] **Block Quotes**: enforce `>` marker indent ≤ 3 columns; open on empty `>` lines.
- [x] **Code Spans**: exact backtick-run matching; skip code spans while scanning link labels.
- [x] **Fenced Code Blocks**: closing fence indent uses column count; entity decode in info string; tabs allowed in opening fence.
- [x] **Emphasis**: allow split runs to form `<strong><em>` in cases like `***`.
- [x] **Unicode Categories**: expanded punctuation/whitespace tables.
- [ ] **Lists & List Items** (most remaining): fix reference-definition handling inside lists (Example 319) or document skip.
- [x] **Inline Links**: tighten destination/title parsing (spaces/newlines/angle-bracket handling) to avoid false positives.
- [x] **HTML Blocks**: fixed remaining Type 1/6/7 list/indent edge cases.

## Edge/Corner Cases to Fix

- [ ] Reference definitions inside lists are still emitted as paragraphs (Example 319).
- [x] Indented code blocks inside list items (avoid extra leading space or paragraph handling).
- [x] Empty list items and list continuation markers (`-`, `*`, `2.`) breaking list structure.
- [x] Nested list indentation with mixed indent widths.
- [x] List tight/loose retroactive rendering (Examples 318, 321, 327, 328).
- [x] Blockquote + list continuation edge cases (Examples 261, 262, 322, 323).

## Priority Order (Easy → Hard)

1. Empty list items and list continuation rules.
2. Indented code blocks inside list items (including tabs).
3. Mixed-indent list nesting rules (marker indent vs content indent).
4. Inline link destination/title strictness (spaces, newlines, angle brackets).
5. HTML block edge cases inside lists/blockquote containers.

## Known Skips

- [ ] **Reference Links/Images**: intentionally not supported to preserve strict O(N) parsing.
