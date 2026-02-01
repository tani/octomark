/**
 * OctoMark (Final Integrated Edition)
 * - 4-space fixed indentation for infinite nested lists.
 * - 8-char window lookahead for block dispatch.
 * - True O(n) pointer-jumping inline scanner.
 * - Long language name support & backslash escaping.
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
        return str.replace(/[&<>"']/g, m => this.escapeMap[m]);
    }

    parse(input) {
        const lines = input.split('\n');
        let output = "";
        let inCodeBlock = false;
        let inTable = false;
        let tableAligns = [];
        let listStack = []; // <ul> の階層管理用

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            const trimmed = line.trim();

            // --- 1. Indent Detection (Fixed 4-space) ---
            let indentLevel = 0;
            if (!inCodeBlock) {
                while (line.startsWith('    ', indentLevel * 4)) {
                    indentLevel++;
                }
            }
            const relativeLine = line.substring(indentLevel * 4);
            const window = Array.from(relativeLine.padEnd(8, ' ')).slice(0, 8);

            // --- 2. Fenced Code Block (```) ---
            if (window[0] === '`' && window[1] === '`' && window[2] === '`') {
                this.closeAllLists(listStack, () => { output += "</ul>\n"; });
                if (inTable) { output += "</tbody></table>\n"; inTable = false; }

                if (!inCodeBlock) {
                    const langPart = relativeLine.substring(3).trim().split(' ')[0];
                    const langClass = langPart ? ` class="language-${this.escape(langPart)}"` : "";
                    output += `<pre><code${langClass}>`;
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

            // --- 3. Table / List Exit Guard ---
            if (inTable && !relativeLine.startsWith('|')) {
                output += "</tbody></table>\n";
                inTable = false;
            }

            // 空行の処理
            if (trimmed === "") {
                this.closeAllLists(listStack, () => { output += "</ul>\n"; });
                if (inTable) { output += "</tbody></table>\n"; inTable = false; }
                continue;
            }

            // --- 4. Nested List Logic ---
            if (window[0] === '-' && window[1] === ' ') {
                // 階層が増える場合
                while (listStack.length < indentLevel + 1) {
                    output += "<ul>\n";
                    listStack.push(true);
                }
                // 階層が減る場合
                while (listStack.length > indentLevel + 1) {
                    output += "</ul>\n";
                    listStack.pop();
                }

                if (window[2] === '[' && (window[3] === ' ' || window[3] === 'x') && window[4] === ']') {
                    const checked = window[3] === 'x' ? "checked" : "";
                    output += `<li><input type="checkbox" ${checked} disabled> ${this.parseInline(relativeLine.substring(6))}</li>\n`;
                } else {
                    output += `<li>${this.parseInline(relativeLine.substring(2))}</li>\n`;
                }
                continue;
            } else {
                // リスト以外の要素が来たらリストを閉じる
                this.closeAllLists(listStack, () => { output += "</ul>\n"; });
            }

            // --- 5. Other Block Elements ---
            if (window[0] === '#' && window[1] === ' ') {
                output += `<h1>${this.parseInline(relativeLine.substring(2))}</h1>\n`;
                continue;
            }
            if (window[0] === '>' && window[1] === ' ') {
                output += `<blockquote>${this.parseInline(relativeLine.substring(2))}</blockquote>\n`;
                continue;
            }
            if (window[0] === '-' && window[1] === '-' && window[2] === '-' && trimmed === '---') {
                output += "<hr>\n";
                continue;
            }

            // --- 6. Tables ---
            if (window[0] === '|') {
                const nextLine = lines[i+1]?.trim() || "";
                if (!inTable && nextLine[0] === '|' && (nextLine[1] === '-' || nextLine[1] === ':')) {
                    output += "<table><thead><tr>";
                    const cells = this.splitCells(relativeLine);
                    tableAligns = this.parseAligns(lines[i+1]);
                    cells.forEach((c, idx) => {
                        const style = tableAligns[idx] ? ` style="text-align:${tableAligns[idx]}"` : "";
                        output += `<th${style}>${this.parseInline(c)}</th>`;
                    });
                    output += "</tr></thead><tbody>\n";
                    inTable = true;
                    i++; continue;
                } else if (inTable) {
                    output += "<tr>";
                    this.splitCells(relativeLine).forEach((c, idx) => {
                        const style = tableAligns[idx] ? ` style="text-align:${tableAligns[idx]}"` : "";
                        output += `<td${style}>${this.parseInline(c)}</td>`;
                    });
                    output += "</tr>\n";
                    continue;
                }
            }

            output += `<p>${this.parseInline(trimmed)}</p>\n`;
        }
        this.closeAllLists(listStack, () => { output += "</ul>\n"; });
        if (inTable) output += "</tbody></table>\n";
        return output;
    }

    closeAllLists(stack, callback) {
        while (stack.length > 0) {
            callback();
            stack.pop();
        }
    }

    parseInline(text) {
        let res = "";
        let i = 0;
        const len = text.length;

        while (i < len) {
            const start = i;
            // Manual Scan for special chars
            while (i < len) {
                const code = text.charCodeAt(i);
                if (code < 256 && this.specialChars[code]) break;
                i++;
            }
            
            if (i > start) {
                res += text.substring(start, i);
            }

            if (i >= len) break;

            const char = text[i];
            
            if (char === '\\' && i + 1 < len) {
                const next = text[i + 1];
                res += this.escapeMap[next] || next;
                i += 2; continue;
            }
            if (char === '[') {
                let j = i + 1;
                let linkText = "";
                let foundBracket = false;
                while (j < len) {
                    if (text[j] === ']') { foundBracket = true; break; }
                    linkText += text[j]; j++;
                }
                if (foundBracket && text[j + 1] === '(') {
                    let k = j + 2;
                    let url = "";
                    let foundParen = false;
                    let hasSpace = false;
                    while (k < len) {
                        if (text[k] === ')') { foundParen = true; break; }
                        if (text[k] === ' ' || text[k] === '\t') { hasSpace = true; break; }
                        url += text[k]; k++;
                    }
                    if (foundParen && !hasSpace) {
                        res += `<a href="${this.escape(url)}">${this.parseInline(linkText)}</a>`;
                        i = k + 1; continue;
                    }
                }
            }
            if (char === '*' && text[i + 1] === '*') {
                let j = i + 2;
                let found = false;
                while (j < len - 1) {
                    if (text[j] === '*' && text[j + 1] === '*') { found = true; break; }
                    j++;
                }
                if (found) {
                    res += `<strong>${this.parseInline(text.substring(i + 2, j))}</strong>`;
                    i = j + 2; continue;
                }
            }
            if (char === '_') {
                let j = i + 1;
                let found = false;
                while (j < len) {
                    if (text[j] === '_') { found = true; break; }
                    j++;
                }
                if (found) {
                    res += `<em>${this.parseInline(text.substring(i + 1, j))}</em>`;
                    i = j + 1; continue;
                }
            }
            if (char === '`') {
                let j = i + 1;
                let found = false;
                while (j < len) {
                    if (text[j] === '`') { found = true; break; }
                    j++;
                }
                if (found) {
                    res += `<code>${this.escape(text.substring(i + 1, j))}</code>`;
                    i = j + 1; continue;
                }
            }
            
            res += this.escapeMap[char] || char;
            i++;
        }
        return res;
    }

    splitCells(line) {
        return line.trim().replace(/^\||\|$/g, '').split('|').map(s => s.trim());
    }

    parseAligns(line) {
        return this.splitCells(line).map(c => {
            if (c.startsWith(':') && c.endsWith(':')) return 'center';
            if (c.endsWith(':')) return 'right';
            if (c.startsWith(':')) return 'left';
            return '';
        });
    }
}

export { OctoMark };
