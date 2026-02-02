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
- [ ] Unicode categories: expand `isPunct` and whitespace checks to support mandatory Unicode ranges via lookup tables.
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

## Remaining Compliance Failures (204 Tests)

- [ ] **Reference Links & Definitions** (78 failures): Implement full support for reference-style links `[foo][bar]`, `[foo][]`, and link reference definitions `[foo]: /url "title"`.
    - Handle case-insensitive label matching.
    - Support potentially multiline titles and destinations.
    - Implement the link label normalization algorithm.
- [ ] **Lists & List Items** (44 failures): Fix complex list nesting and interruption rules.
    - Strictly handle blank lines between list items (tight vs loose).
    - Fix ordered list start number parsing (max 9 digits).
    - Handle indentation requirements for sub-lists vs indented code blocks.
- [ ] **Emphasis** (25 failures): Refine inline delimiter run processing.
    - Re-verify "left-flanking" and "right-flanking" semantics for `_` vs `*`.
    - Fix precedence rules when multiple delimiters are adjacent (e.g., `***abc***`).
- [ ] **Fenced Code Blocks** (14 failures): Fix edge cases for info strings and indentation.
    - Handle backticks inside info strings properly.
    - Fix closing fence indentation limits (up to 3 spaces).
- [ ] **Images** (14 failures): Fix reference-style images `![foo][bar]`.
    - (Dependent on Reference Links implementation).
- [ ] **Code Spans** (10 failures): Handle leading/trailing spaces and backtick stripping.
    - Examples: ``` `` ` `` ```, ``` `` `` ```.
- [ ] **HTML Blocks** (8 failures): Fix remaining edge cases (likely Type 7 or interrupt rules).
    - Verify interrupt conditions for different block types.
- [ ] **Backslash Escapes** (3 failures): Fix remaining escape sequences.
- [ ] **Block Quotes** (3 failures): Fix lazy continuation or double nesting issues.
