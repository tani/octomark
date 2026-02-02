# Octomark TODO

- [x] Tabs/indentation: implement CommonMark tab expansion (4-space stops).
- [x] Thematic breaks & headings: ATX/Setext and thematic breaks with linear scans.
- [x] Backslash escapes: treat only punctuation escapes.
- [x] Entity decoding: numeric and named entities in O(1).
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
