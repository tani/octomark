#include <algorithm>
#include <chrono>
#include <cstring>
#include <future>
#include <iostream>
#include <map>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

/**
 * OctoMark Native C++ Edition (Full Feature parity with JS)
 *
 * Optimized with SWAR (64-bit word operations) and Multi-threading.
 * Maintains O(N) complexity and regex-free logic.
 */

class OctoMark {
public:
  OctoMark() {
    std::fill(std::begin(special_chars), std::end(special_chars), false);
    std::fill(std::begin(escape_table), std::end(escape_table), nullptr);
    std::string specs = "\\['*`&<>\"_~!$";
    for (char c : specs)
      special_chars[(unsigned char)c] = true;
    special_chars['h'] = true;

    escape_table['&'] = "&amp;";
    escape_table['<'] = "&lt;";
    escape_table['>'] = "&gt;";
    escape_table['"'] = "&quot;";
    escape_table['\''] = "&#39;";
  }

  bool special_chars[256];
  const char *escape_table[256];

  std::string escape(std::string_view str) const {
    std::string res;
    res.reserve(str.size() * 1.1);
    for (char c : str) {
      const char *esc = escape_table[(unsigned char)c];
      if (esc)
        res += esc;
      else
        res += c;
    }
    return res;
  }

  std::string split_cells_and_parse(std::string_view l) const {
    // Simplified cell splitting logic
    std::string s(l);
    // Trim leading/trailing pipes if present
    size_t start = s.find_first_not_of(" \t");
    if (start != std::string::npos && s[start] == '|')
      start++;
    size_t end = s.find_last_not_of(" \t");
    if (end != std::string::npos && s[end] == '|')
      end--;

    if (start > end || start == std::string::npos)
      return "";
    return s.substr(start, end - start + 1);
  }

  std::vector<std::string> split_row(std::string_view line) const {
    std::vector<std::string> cells;
    std::string s(line);
    size_t start = 0;
    size_t end = s.length();

    // Find first and last pipes for trimming
    size_t first_pipe = s.find('|');
    size_t last_pipe = s.rfind('|');

    if (first_pipe != std::string::npos)
      start = first_pipe + 1;
    if (last_pipe != std::string::npos && last_pipe > first_pipe)
      end = last_pipe;

    std::string content = s.substr(start, end - start);
    size_t pos = 0;
    while (true) {
      size_t next = content.find('|', pos);
      std::string cell = std::string(content.substr(
          pos, (next == std::string::npos ? content.length() : next) - pos));
      // Trim cell
      size_t c_start = cell.find_first_not_of(" \t");
      size_t c_end = cell.find_last_not_of(" \t");
      if (c_start != std::string::npos) {
        cells.push_back(cell.substr(c_start, c_end - c_start + 1));
      } else {
        cells.push_back("");
      }
      if (next == std::string::npos)
        break;
      pos = next + 1;
    }
    return cells;
  }

  std::string parse_inline(std::string_view text) const {
    std::string res;
    res.reserve(text.size());
    size_t i = 0;
    const size_t len = text.length();

    while (i < len) {
      size_t start = i;

      // --- SWAR Jump Scan ---
      while (i + 7 < len) {
        uint64_t word;
        std::memcpy(&word, text.data() + i, 8);
        if (special_chars[(word >> 0) & 0xFF] ||
            special_chars[(word >> 8) & 0xFF] ||
            special_chars[(word >> 16) & 0xFF] ||
            special_chars[(word >> 24) & 0xFF] ||
            special_chars[(word >> 32) & 0xFF] ||
            special_chars[(word >> 40) & 0xFF] ||
            special_chars[(word >> 48) & 0xFF] ||
            special_chars[(word >> 56) & 0xFF])
          break;
        i += 8;
      }
      while (i < len && !special_chars[(unsigned char)text[i]])
        i++;

      if (i > start)
        res += text.substr(start, i - start);
      if (i >= len)
        break;

      // Peek window
      std::string peek(text.substr(i, std::min((size_t)8, len - i)));
      while (peek.length() < 8)
        peek += ' ';
      char char_at = peek[0];

      // Escaping
      if (char_at == '\\' && i + 1 < len) {
        char escaped = text[i + 1];
        const char *esc = escape_table[(unsigned char)escaped];
        if (esc)
          res += esc;
        else
          res += escaped;
        i += 2;
        continue;
      }

      // Links/Images
      if (char_at == '[' || (char_at == '!' && peek[1] == '[')) {
        bool is_img = (char_at == '!');
        size_t offset = is_img ? 1 : 0;
        size_t close_bracket = text.find(']', i + offset + 1);
        if (close_bracket != std::string::npos && close_bracket + 1 < len &&
            text[close_bracket + 1] == '(') {
          size_t close_paren = text.find(')', close_bracket + 2);
          if (close_paren != std::string::npos) {
            std::string_view url = text.substr(
                close_bracket + 2, close_paren - (close_bracket + 2));
            if (url.find(' ') == std::string_view::npos) {
              std::string_view link_text =
                  text.substr(i + offset + 1, close_bracket - (i + offset + 1));
              if (is_img) {
                res += "<img src=\"" + escape(url) + "\" alt=\"" +
                       escape(link_text) + "\">";
              } else {
                res += "<a href=\"" + escape(url) + "\">" +
                       parse_inline(link_text) + "</a>";
              }
              i = close_paren + 1;
              continue;
            }
          }
        }
      }

      // Bold/Strikethrough
      if ((char_at == '*' && peek[1] == '*') ||
          (char_at == '~' && peek[1] == '~')) {
        std::string marker = (char_at == '*') ? "**" : "~~";
        std::string tag = (char_at == '*') ? "strong" : "del";
        size_t close = text.find(marker, i + 2);
        if (close != std::string::npos) {
          res += "<" + tag + ">" +
                 parse_inline(text.substr(i + 2, close - (i + 2))) + "</" +
                 tag + ">";
          i = close + 2;
          continue;
        }
      }

      // Italic
      if (char_at == '_') {
        size_t close = text.find('_', i + 1);
        if (close != std::string::npos) {
          res += "<em>" + parse_inline(text.substr(i + 1, close - (i + 1))) +
                 "</em>";
          i = close + 1;
          continue;
        }
      }

      // Code
      if (char_at == '`') {
        size_t close = text.find('`', i + 1);
        if (close != std::string::npos) {
          res += "<code>" + escape(text.substr(i + 1, close - (i + 1))) +
                 "</code>";
          i = close + 1;
          continue;
        }
      }

      // Math
      if (char_at == '$') {
        size_t close = text.find('$', i + 1);
        if (close != std::string::npos) {
          res += "<span class=\"math\">" +
                 escape(text.substr(i + 1, close - (i + 1))) + "</span>";
          i = close + 1;
          continue;
        }
      }

      // Autolinks
      if (char_at == 'h' && peek.substr(0, 4) == "http") {
        bool is_full =
            peek.substr(0, 7) == "http://" || peek.substr(0, 8) == "https://";
        if (is_full) {
          size_t k = i;
          while (k < len) {
            char c = text[k];
            if (std::isspace(c) || c == '<' || c == '>' || c == '"' ||
                c == '\'' || c == '[' || c == ']' || c == '(' || c == ')')
              break;
            k++;
          }
          if (k > i + 7) {
            std::string_view url = text.substr(i, k - i);
            res += "<a href=\"" + escape(url) + "\">" + escape(url) + "</a>";
            i = k;
            continue;
          }
        }
      }

      const char *esc = escape_table[(unsigned char)char_at];
      if (esc)
        res += esc;
      else
        res += char_at;
      i++;
    }
    return res;
  }

  std::string parse_chunk(std::string_view input) const {
    std::string output;
    output.reserve(input.size() * 1.1);
    bool in_code = false, in_math = false, in_table = false;
    std::vector<std::string> table_aligns;
    std::vector<std::string> list_stack;
    size_t pos = 0, len = input.length();

    while (pos < len) {
      size_t next = input.find('\n', pos);
      if (next == std::string::npos)
        next = len;
      std::string_view line = input.substr(pos, next - pos);
      pos = next + 1;

      std::string trimmed_str(line);
      size_t t_start = trimmed_str.find_first_not_of(" \t\r");
      size_t t_end = trimmed_str.find_last_not_of(" \t\r");
      std::string trimmed =
          (t_start == std::string::npos)
              ? ""
              : trimmed_str.substr(t_start, t_end - t_start + 1);

      if (!in_code && trimmed.empty()) {
        while (!list_stack.empty()) {
          output += "</" + list_stack.back() + ">\n";
          list_stack.pop_back();
        }
        if (in_table) {
          output += "</tbody></table>\n";
          in_table = false;
        }
        continue;
      }

      size_t indent = 0;
      if (!in_code) {
        while (line.length() >= indent * 4 + 4 &&
               line.substr(indent * 4, 4) == "    ")
          indent++;
      }
      std::string_view rel = line.substr(indent * 4);
      uint64_t window = 0;
      size_t cp = std::min((size_t)8, rel.length());
      if (cp > 0)
        std::memcpy(&window, rel.data(), cp);

      // Fenced Code
      if ((window & 0xFFFFFF) == 0x606060) {
        while (!list_stack.empty()) {
          output += "</" + list_stack.back() + ">\n";
          list_stack.pop_back();
        }
        if (in_table) {
          output += "</tbody></table>\n";
          in_table = false;
        }
        if (!in_code) {
          std::string lang = std::string(rel.substr(3));
          size_t l_end = lang.find_first_of(" \t\r");
          if (l_end != std::string::npos)
            lang = lang.substr(0, l_end);
          output +=
              "<pre><code" +
              (lang.empty() ? "" : " class=\"language-" + escape(lang) + "\"") +
              ">";
        } else
          output += "</code></pre>\n";
        in_code = !in_code;
        continue;
      }

      // Block Math
      if ((window & 0xFFFF) == 0x2424) {
        if (in_table) {
          output += "</tbody></table>\n";
          in_table = false;
        }
        if (!in_math)
          output += "<div class=\"math\">";
        else
          output += "</div>\n";
        in_math = !in_math;
        continue;
      }

      if (in_math || in_code) {
        output += escape(line) + "\n";
        continue;
      }

      // Lists
      bool is_ul = rel.length() >= 2 && rel.substr(0, 2) == "- ";
      bool is_ol =
          rel.length() >= 3 && std::isdigit(rel[0]) && rel.substr(1, 2) == ". ";
      if (is_ul || is_ol) {
        std::string tag = is_ul ? "ul" : "ol";
        while (list_stack.size() < indent + 1) {
          output += "<" + tag + ">\n";
          list_stack.push_back(tag);
        }
        while (list_stack.size() > indent + 1) {
          output += "</" + list_stack.back() + ">\n";
          list_stack.pop_back();
        }
        if (list_stack.back() != tag) {
          output += "</" + list_stack.back() + ">\n<" + tag + ">\n";
          list_stack.back() = tag;
        }

        if (is_ul) {
          std::string_view rest = rel.substr(2);
          if (rest.length() >= 4 &&
              (rest.substr(0, 4) == "[ ] " || rest.substr(0, 4) == "[x] ")) {
            bool checked = rest[1] == 'x';
            output += "<li><input type=\"checkbox\" " +
                      std::string(checked ? "checked" : "") + " disabled> " +
                      parse_inline(rest.substr(4)) + "</li>\n";
          } else
            output += "<li>" + parse_inline(rest) + "</li>\n";
        } else
          output += "<li>" + parse_inline(rel.substr(3)) + "</li>\n";
        continue;
      } else if (!list_stack.empty()) {
        while (!list_stack.empty()) {
          output += "</" + list_stack.back() + ">\n";
          list_stack.pop_back();
        }
      }

      // Other blocks
      if ((window & 0xFFFF) == 0x2023)
        output += "<h1>" + parse_inline(rel.substr(2)) + "</h1>\n";
      else if ((window & 0xFFFF) == 0x203E)
        output +=
            "<blockquote>" + parse_inline(rel.substr(2)) + "</blockquote>\n";
      else if (trimmed == "---")
        output += "<hr>\n";
      else if (rel[0] == '|') {
        if (!in_table) {
          // Very simple lookahead for table
          size_t next_n = input.find('\n', pos);
          if (next_n != std::string::npos) {
            std::string_view la = input.substr(pos, next_n - pos);
            size_t t_s = la.find_first_not_of(" \t\r");
            if (t_s != std::string::npos && la[t_s] == '|') {
              std::vector<std::string> header = split_row(rel);
              std::vector<std::string> sep = split_row(la);
              table_aligns.clear();
              for (const auto &s : sep) {
                bool l = !s.empty() && s[0] == ':';
                bool r = !s.empty() && s[s.length() - 1] == ':';
                if (l && r)
                  table_aligns.push_back("center");
                else if (r)
                  table_aligns.push_back("right");
                else if (l)
                  table_aligns.push_back("left");
                else
                  table_aligns.push_back("");
              }
              output += "<table><thead><tr>";
              for (size_t i = 0; i < header.size(); ++i) {
                std::string style =
                    (i < table_aligns.size() && !table_aligns[i].empty())
                        ? " style=\"text-align:" + table_aligns[i] + "\""
                        : "";
                output +=
                    "<th" + style + ">" + parse_inline(header[i]) + "</th>";
              }
              output += "</tr></thead><tbody>\n";
              in_table = true;
              pos = next_n + 1;
              continue;
            }
          }
          output += "<p>" + parse_inline(trimmed) + "</p>\n";
        } else {
          std::vector<std::string> cells = split_row(rel);
          output += "<tr>";
          for (size_t i = 0; i < cells.size(); ++i) {
            std::string style =
                (i < table_aligns.size() && !table_aligns[i].empty())
                    ? " style=\"text-align:" + table_aligns[i] + "\""
                    : "";
            output += "<td" + style + ">" + parse_inline(cells[i]) + "</td>";
          }
          output += "</tr>\n";
        }
      } else {
        if (in_table) {
          output += "</tbody></table>\n";
          in_table = false;
        }
        output += "<p>" + parse_inline(trimmed) + "</p>\n";
      }
    }
    while (!list_stack.empty()) {
      output += "</" + list_stack.back() + ">\n";
      list_stack.pop_back();
    }
    if (in_table)
      output += "</tbody></table>\n";
    if (in_math)
      output += "</div>\n";
    return output;
  }

  std::string parse_parallel(std::string_view input) const {
    unsigned int threads = std::thread::hardware_concurrency();
    if (threads == 0)
      threads = 1;
    std::vector<std::future<std::string>> futures;
    size_t start = 0, sz = input.size(), c_sz = sz / threads;
    for (unsigned int i = 0; i < threads; ++i) {
      size_t end = (i == threads - 1) ? sz : input.find('\n', start + c_sz);
      if (end == std::string::npos)
        end = sz;
      futures.push_back(
          std::async(std::launch::async, [this, input, start, end]() {
            return this->parse_chunk(input.substr(start, end - start));
          }));
      start = end + 1;
      if (start >= sz)
        break;
    }
    std::string res;
    for (auto &f : futures)
      res += f.get();
    return res;
  }
};

int main() {
  std::string data;
  for (int i = 0; i < 1000000; ++i)
    data += "# Title\n- [x] Task\n| A | B |\n|---|---|\n| 1 | 2 |\n\nRegular "
            "text with **bold** and $x^2$.\n";
  OctoMark om;
  auto t1 = std::chrono::high_resolution_clock::now();
  std::string result = om.parse_parallel(data);
  auto t2 = std::chrono::high_resolution_clock::now();
  auto ms = std::chrono::duration<double, std::milli>(t2 - t1).count();
  std::cout << "Size: " << data.size() / 1e6 << " MB, Time: " << ms
            << " ms, Speed: " << (data.size() / ms / 1e6) << " GB/s"
            << std::endl;
  return 0;
}
