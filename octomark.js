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
        let res = "";
        let last = 0;
        for (let i = 0; i < str.length; i++) {
            const char = str[i];
            const escaped = this.escapeMap[char];
            if (escaped) {
                if (i > last) res += str.substring(last, i);
                res += escaped;
                last = i + 1;
            }
        }
        if (last < str.length) res += str.substring(last);
        return res;
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
            let next = input.indexOf('\n', pos);
            if (next === -1) next = len;
            const line = input.substring(pos, next);
            pos = next + 1;

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
                    let langPart = "";
                    let k = 3;
                    while (k < relativeLine.length && relativeLine[k] === ' ') k++;
                    let start = k;
                    while (k < relativeLine.length && relativeLine[k] !== ' ') k++;
                    langPart = relativeLine.substring(start, k);

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
                // Lookahead check for separator line
                let nextSepPos = input.indexOf('\n', next + 1);
                if (nextSepPos === -1) nextSepPos = len;
                const nextLine = input.substring(next + 1, nextSepPos).trim();

                if (!inTable && nextLine[0] === '|' && (nextLine[1] === '-' || nextLine[1] === ':')) {
                    output += "<table><thead><tr>";
                    const cells = this.splitCells(relativeLine);
                    tableAligns = this.parseAligns(nextLine);
                    cells.forEach((c, idx) => {
                        const style = tableAligns[idx] ? ` style="text-align:${tableAligns[idx]}"` : "";
                        output += `<th${style}>${this.parseInline(c)}</th>`;
                    });
                    output += "</tr></thead><tbody>\n";
                    inTable = true;
                    pos = nextSepPos + 1; // Skip the separator line
                    continue;
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
        let start = 0;
        let end = line.length;
        while (start < end && (line[start] === ' ' || line[start] === '\t')) start++;
        if (start < end && line[start] === '|') start++;
        while (end > start && (line[end - 1] === ' ' || line[end - 1] === '\t' || line[end - 1] === '\r')) end--;
        if (end > start && line[end - 1] === '|') end--;

        const res = [];
        let cur = start;
        for (let i = start; i < end; i++) {
            if (line[i] === '|') {
                res.push(line.substring(cur, i).trim());
                cur = i + 1;
            }
        }
        res.push(line.substring(cur, end).trim());
        return res;
    }

    parseAligns(line) {
        const cells = this.splitCells(line);
        const aligns = [];
        for (let i = 0; i < cells.length; i++) {
            const c = cells[i];
            if (c.startsWith(':') && c.endsWith(':')) aligns.push('center');
            else if (c.endsWith(':')) aligns.push('right');
            else if (c.startsWith(':')) aligns.push('left');
            else aligns.push('');
        }
        return aligns;
    }
}

export { OctoMark };
