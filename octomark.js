/**
 * OctoMark (Naive & Linear Edition)
 * - Regex-free, O(N) single-pass.
 * - Flat implementation with inlined logic.
 */
class OctoMark {
    constructor() {
        this.escapeMap = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
        this.specialChars = new Uint8Array(256);
        const specials = "\\['*`&<>\"_";
        for (let i = 0; i < specials.length; i++) {
            this.specialChars[specials.charCodeAt(i)] = 1;
        }
    }

    escape(str) {
        let res = "";
        let last = 0;

        for (let i = 0; i < str.length; i++) {
            const esc = this.escapeMap[str[i]];
            if (esc) {
                if (i > last) res += str.substring(last, i);
                res += esc;
                last = i + 1;
            }
        }

        return last < str.length ? res + str.substring(last) : res;
    }

    parse(input) {
        let output = "";
        let inCodeBlock = false;
        let inTable = false;
        let tableAligns = [];
        let listStack = [];
        let pos = 0;
        const len = input.length;

        while (pos < len) {
            // Find next line boundary
            let next = input.indexOf('\n', pos);
            if (next === -1) next = len;
            const line = input.substring(pos, next);
            pos = next + 1;

            const trimmed = line.trim();

            // Handle empty lines or code block escapes
            if (!inCodeBlock && !trimmed) {
                while (listStack.length) {
                    output += "</ul>\n";
                    listStack.pop();
                }
                if (inTable) {
                    output += "</tbody></table>\n";
                    inTable = false;
                }
                continue;
            }

            // Indentation Detection (Fixed 4 spaces)
            let indent = 0;
            if (!inCodeBlock) {
                while (line.startsWith('    ', indent * 4)) {
                    indent++;
                }
            }
            const rel = line.substring(indent * 4);

            // 8-character lookahead window for block dispatch (SIMD-ready logic)
            const window = rel.substring(0, 8).padEnd(8, ' ');

            // --- Fenced Code Block ---
            if (window[0] === '`' && window[1] === '`' && window[2] === '`') {
                while (listStack.length) {
                    output += "</ul>\n";
                    listStack.pop();
                }
                if (inTable) {
                    output += "</tbody></table>\n";
                    inTable = false;
                }

                if (!inCodeBlock) {
                    const langPart = rel.substring(3).trim();
                    const lang = langPart.split(' ')[0];
                    const langAttr = lang ? ` class="language-${this.escape(lang)}"` : "";
                    output += `<pre><code${langAttr}>`;
                } else {
                    output += "</code></pre>\n";
                }
                inCodeBlock = !inCodeBlock;
                continue;
            }

            if (inCodeBlock) {
                output += this.escape(line) + "\n";
                continue;
            }

            // --- Unordered Lists ---
            if (window[0] === '-' && window[1] === ' ') {
                // Adjust list depth
                while (listStack.length < indent + 1) {
                    output += "<ul>\n";
                    listStack.push(1);
                }
                while (listStack.length > indent + 1) {
                    output += "</ul>\n";
                    listStack.pop();
                }

                // Task list detection using window
                const isTask = window[2] === '[' && (window[3] === ' ' || window[3] === 'x') && window[4] === ']';

                if (isTask) {
                    const isChecked = window[3] === 'x';
                    const checkedAttr = isChecked ? "checked" : "";
                    const taskContent = rel.substring(6); // "- [x] " is 6 chars
                    output += `<li><input type="checkbox" ${checkedAttr} disabled> ${this.parseInline(taskContent)}</li>\n`;
                } else {
                    output += `<li>${this.parseInline(rel.substring(2))}</li>\n`;
                }
                continue;
            } else if (listStack.length) {
                // Not a list item, close all open lists
                while (listStack.length) {
                    output += "</ul>\n";
                    listStack.pop();
                }
            }

            // --- Block Elements ---
            if (window[0] === '#' && window[1] === ' ') {
                output += `<h1>${this.parseInline(rel.substring(2))}</h1>\n`;
            } else if (window[0] === '>' && window[1] === ' ') {
                output += `<blockquote>${this.parseInline(rel.substring(2))}</blockquote>\n`;
            } else if (window[0] === '-' && window[1] === '-' && window[2] === '-' && trimmed === '---') {
                output += "<hr>\n";
            } else if (window[0] === '|') {
                // Common cell splitting logic
                const splitRow = (l) => {
                    let s = l.trim();
                    if (s[0] === '|') s = s.substring(1);
                    if (s[s.length - 1] === '|') s = s.substring(0, s.length - 1);
                    return s.split('|').map(c => c.trim());
                };

                if (!inTable) {
                    // Peek ahead for separator line
                    let nextLineEnd = input.indexOf('\n', next + 1);
                    const lookaheadLine = input.substring(next + 1, nextLineEnd === -1 ? len : nextLineEnd).trim();

                    if (lookaheadLine[0] === '|' && (lookaheadLine[1] === '-' || lookaheadLine[1] === ':')) {
                        // New Table detected
                        const headerCells = splitRow(rel);
                        const sepCells = splitRow(lookaheadLine);

                        // Parse alignments
                        tableAligns = sepCells.map(c => {
                            const hasLeft = c.startsWith(':');
                            const hasRight = c.endsWith(':');
                            if (hasLeft && hasRight) return 'center';
                            if (hasRight) return 'right';
                            if (hasLeft) return 'left';
                            return '';
                        });

                        // Build Table Header
                        let headHtml = "<table><thead><tr>";
                        for (let i = 0; i < headerCells.length; i++) {
                            const align = tableAligns[i];
                            const style = align ? ` style="text-align:${align}"` : "";
                            headHtml += `<th${style}>${this.parseInline(headerCells[i])}</th>`;
                        }
                        output += headHtml + "</tr></thead><tbody>\n";

                        inTable = true;
                        pos = (nextLineEnd === -1 ? len : nextLineEnd) + 1;
                        continue;
                    }
                }

                // Table Body Row
                const rowCells = splitRow(rel);
                let rowHtml = "<tr>";
                for (let i = 0; i < rowCells.length; i++) {
                    const align = tableAligns[i];
                    const style = align ? ` style="text-align:${align}"` : "";
                    rowHtml += `<td${style}>${this.parseInline(rowCells[i])}</td>`;
                }
                output += rowHtml + "</tr>\n";
            } else {
                // Exit table if current line is not a table row
                if (inTable) {
                    output += "</tbody></table>\n";
                    inTable = false;
                }
                output += `<p>${this.parseInline(trimmed)}</p>\n`;
            }
        }

        // Cleanup
        while (listStack.length) {
            output += "</ul>\n";
            listStack.pop();
        }
        if (inTable) {
            output += "</tbody></table>\n";
        }

        return output;
    }

    parseInline(text) {
        let res = "";
        let i = 0;
        const len = text.length;
        const specs = this.specialChars;

        while (i < len) {
            let start = i;

            // --- SIMD-ready: 8-character jump scan ---
            // Skip plain text in chunks of 8 to minimize branch overhead
            while (i + 7 < len) {
                if (specs[text.charCodeAt(i)] || specs[text.charCodeAt(i + 1)] ||
                    specs[text.charCodeAt(i + 2)] || specs[text.charCodeAt(i + 3)] ||
                    specs[text.charCodeAt(i + 4)] || specs[text.charCodeAt(i + 5)] ||
                    specs[text.charCodeAt(i + 6)] || specs[text.charCodeAt(i + 7)]) break;
                i += 8;
            }

            // Finish scanning the residual plain text
            while (i < len && !specs[text.charCodeAt(i)]) {
                i++;
            }

            if (i > start) {
                res += text.substring(start, i);
            }

            if (i >= len) break;

            // --- Window-based Dispatch (8-char lookahead) ---
            const peek = text.substring(i, i + 8).padEnd(8, ' ');
            const char = peek[0];

            // Escaping
            if (char === '\\' && i + 1 < len) {
                const escaped = text[i + 1];
                res += this.escapeMap[escaped] || escaped;
                i += 2;
                continue;
            }

            // Links [text](url)
            if (char === '[') {
                let closeBracket = text.indexOf(']', i + 1);
                if (closeBracket !== -1 && text[closeBracket + 1] === '(') {
                    let closeParen = text.indexOf(')', closeBracket + 2);
                    if (closeParen !== -1) {
                        const url = text.substring(closeBracket + 2, closeParen);
                        if (url.indexOf(' ') === -1 && url.indexOf('\t') === -1) {
                            const linkText = text.substring(i + 1, closeBracket);
                            res += `<a href="${this.escape(url)}">${this.parseInline(linkText)}</a>`;
                            i = closeParen + 1;
                            continue;
                        }
                    }
                }
            }

            // Bold **text** (Peek helps here)
            if (char === '*' && peek[1] === '*') {
                let closeBold = text.indexOf('**', i + 2);
                if (closeBold !== -1) {
                    const boldText = text.substring(i + 2, closeBold);
                    res += `<strong>${this.parseInline(boldText)}</strong>`;
                    i = closeBold + 2;
                    continue;
                }
            }

            // Italic _text_
            if (char === '_') {
                let closeItalic = text.indexOf('_', i + 1);
                if (closeItalic !== -1) {
                    const italicText = text.substring(i + 1, closeItalic);
                    res += `<em>${this.parseInline(italicText)}</em>`;
                    i = closeItalic + 1;
                    continue;
                }
            }

            // Inline Code `text`
            if (char === '`') {
                let closeCode = text.indexOf('`', i + 1);
                if (closeCode !== -1) {
                    const codeText = text.substring(i + 1, closeCode);
                    res += `<code>${this.escape(codeText)}</code>`;
                    i = closeCode + 1;
                    continue;
                }
            }

            // Default: Escape special char if it's in escapeMap, or just add it
            res += this.escapeMap[char] || char;
            i++;
        }
        return res;
    }
}

export { OctoMark };
