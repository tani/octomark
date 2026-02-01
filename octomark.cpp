#include <algorithm>
#include <chrono>
#include <cstring>
#include <iostream>
#include <string>
#include <string_view>
#include <vector>

/**
 * OctoMark Native C++ Edition (Streaming & Buffer Passing)
 *
 * This version is specialized for streaming data. It maintains a persistent
 * state within the class, allowing you to feed it data chunks of any size.
 * It uses SWAR for fast scanning and avoids unnecessary heap allocations.
 *
 * Compile: g++ -O3 -std=c++17 octomark.cpp -o octomark
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

  /**
   * Feed a chunk of data to the parser.
   * Partial lines are buffered in 'leftover' and processed when the next chunk
   * arrives.
   */
  void feed(std::string_view chunk, std::string &out) {
    if (chunk.empty())
      return;

    // Combine previous leftover with the new chunk
    std::string data;
    if (!leftover.empty()) {
      data = std::move(leftover);
      data.append(chunk);
    } else {
      data = std::string(chunk);
    }

    size_t pos = 0;
    const size_t len = data.length();

    while (pos < len) {
      size_t next = data.find('\n', pos);

      // If no newline, this line is incomplete. Buffer it and wait for more
      // data.
      if (next == std::string::npos) {
        leftover = data.substr(pos);
        break;
      }

      std::string_view line = std::string_view(data).substr(pos, next - pos);

      // Check if we need to peek at the next line (for table headers)
      if (!in_code && !in_math && !in_table && !line.empty()) {
        size_t t_s = line.find_first_not_of(" \t\r");
        if (t_s != std::string::npos && line[t_s] == '|') {
          // We see a pipe, we NEED the next line to confirm if it's a table
          size_t next_next = data.find('\n', next + 1);
          if (next_next == std::string::npos) {
            // Next line isn't fully available yet, buffer everything from
            // 'line' onwards
            leftover = data.substr(pos);
            break;
          }
        }
      }

      process_line(line, out, data, next + 1);
      pos = next + 1;
    }
  }

  /**
   * Finalize the stream. Flushes any remaining leftover data and closes open
   * tags.
   */
  void finish(std::string &out) {
    if (!leftover.empty()) {
      // Process the last bit as a line (force append a newline internally if
      // needed)
      std::string last = std::move(leftover);
      process_line(last, out, last, last.length());
      leftover.clear();
    }

    while (!list_stack.empty()) {
      out.append("</");
      out.append(list_stack.back());
      out.append(">\n");
      list_stack.pop_back();
    }
    if (in_table) {
      out.append("</tbody></table>\n");
      in_table = false;
    }
    if (in_math) {
      out.append("</div>\n");
      in_math = false;
    }
    if (in_code) {
      out.append("</code></pre>\n");
      in_code = false;
    }
  }

private:
  bool special_chars[256];
  const char *escape_table[256];

  // Persistent state for streaming
  bool in_code = false;
  bool in_math = false;
  bool in_table = false;
  std::vector<std::string> table_aligns;
  std::vector<std::string> list_stack;
  std::string leftover;

  void escape(std::string_view str, std::string &out) const {
    for (char c : str) {
      const char *esc = escape_table[(unsigned char)c];
      if (esc)
        out.append(esc);
      else
        out.push_back(c);
    }
  }

  void parse_inline(std::string_view text, std::string &out) const {
    size_t i = 0;
    const size_t len = text.length();
    while (i < len) {
      size_t start = i;
      // SWAR Jump Scan
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
        out.append(text.substr(start, i - start));
      if (i >= len)
        break;

      char char_at = text[i];
      std::string_view peek = text.substr(i, std::min((size_t)8, len - i));

      // Escaping
      if (char_at == '\\' && i + 1 < len) {
        char escaped = text[i + 1];
        const char *esc = escape_table[(unsigned char)escaped];
        if (esc)
          out.append(esc);
        else
          out.push_back(escaped);
        i += 2;
        continue;
      }

      // Links/Images
      if (char_at == '[' ||
          (char_at == '!' && peek.length() > 1 && peek[1] == '[')) {
        bool is_img = (char_at == '!');
        size_t off = is_img ? 1 : 0;
        size_t close_b = text.find(']', i + off + 1);
        if (close_b != std::string_view::npos && close_b + 1 < len &&
            text[close_b + 1] == '(') {
          size_t close_p = text.find(')', close_b + 2);
          if (close_p != std::string_view::npos) {
            std::string_view url =
                text.substr(close_b + 2, close_p - (close_b + 2));
            if (url.find(' ') == std::string_view::npos) {
              std::string_view link_t =
                  text.substr(i + off + 1, close_b - (i + off + 1));
              if (is_img) {
                out.append("<img src=\"");
                escape(url, out);
                out.append("\" alt=\"");
                escape(link_t, out);
                out.append("\">");
              } else {
                out.append("<a href=\"");
                escape(url, out);
                out.append("\">");
                parse_inline(link_t, out);
                out.append("</a>");
              }
              i = close_p + 1;
              continue;
            }
          }
        }
      }

      // Bold/Strikethrough
      if ((char_at == '*' && peek.length() > 1 && peek[1] == '*') ||
          (char_at == '~' && peek.length() > 1 && peek[1] == '~')) {
        std::string_view tag = (char_at == '*') ? "strong" : "del";
        std::string_view marker = (char_at == '*') ? "**" : "~~";
        size_t close = text.find(marker, i + 2);
        if (close != std::string_view::npos) {
          out.append("<");
          out.append(tag);
          out.append(">");
          parse_inline(text.substr(i + 2, close - (i + 2)), out);
          out.append("</");
          out.append(tag);
          out.append(">");
          i = close + 2;
          continue;
        }
      }

      // Italic, Code, Math, Autolinks... (truncated for brevity but logic is
      // identical)
      if (char_at == '_') {
        size_t close = text.find('_', i + 1);
        if (close != std::string_view::npos) {
          out.append("<em>");
          parse_inline(text.substr(i + 1, close - (i + 1)), out);
          out.append("</em>");
          i = close + 1;
          continue;
        }
      }
      if (char_at == '`') {
        size_t close = text.find('`', i + 1);
        if (close != std::string_view::npos) {
          out.append("<code>");
          escape(text.substr(i + 1, close - (i + 1)), out);
          out.append("</code>");
          i = close + 1;
          continue;
        }
      }
      if (char_at == '$') {
        size_t close = text.find('$', i + 1);
        if (close != std::string_view::npos) {
          out.append("<span class=\"math\">");
          escape(text.substr(i + 1, close - (i + 1)), out);
          out.append("</span>");
          i = close + 1;
          continue;
        }
      }
      if (char_at == 'h' && peek.length() >= 4 && peek.substr(0, 4) == "http") {
        bool f = (peek.length() >= 7 && peek.substr(0, 7) == "http://") ||
                 (peek.length() >= 8 && peek.substr(0, 8) == "https://");
        if (f) {
          size_t k = i;
          while (k < len && !std::isspace(text[k]) &&
                 std::string_view("<>\"'[]()").find(text[k]) ==
                     std::string_view::npos)
            k++;
          if (k > i + 7) {
            std::string_view url = text.substr(i, k - i);
            out.append("<a href=\"");
            escape(url, out);
            out.append("\">");
            escape(url, out);
            out.append("</a>");
            i = k;
            continue;
          }
        }
      }

      const char *esc = escape_table[(unsigned char)char_at];
      if (esc)
        out.append(esc);
      else
        out.push_back(char_at);
      i++;
    }
  }

  void process_line(std::string_view line, std::string &out,
                    std::string_view full_data, size_t next_pos) {
    size_t t_start = line.find_first_not_of(" \t\r");
    size_t t_end = line.find_last_not_of(" \t\r");
    std::string_view trimmed = (t_start == std::string::npos)
                                   ? ""
                                   : line.substr(t_start, t_end - t_start + 1);

    if (!in_code && trimmed.empty()) {
      while (!list_stack.empty()) {
        out.append("</");
        out.append(list_stack.back());
        out.append(">\n");
        list_stack.pop_back();
      }
      if (in_table) {
        out.append("</tbody></table>\n");
        in_table = false;
      }
      return;
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
    if (rel.length() >= 3 && rel.substr(0, 3) == "```") {
      while (!list_stack.empty()) {
        out.append("</");
        out.append(list_stack.back());
        out.append(">\n");
        list_stack.pop_back();
      }
      if (in_table) {
        out.append("</tbody></table>\n");
        in_table = false;
      }
      if (!in_code) {
        std::string_view lang_line = rel.substr(3);
        size_t l_e = lang_line.find_first_of(" \t\r");
        std::string_view lang = (l_e == std::string_view::npos)
                                    ? lang_line
                                    : lang_line.substr(0, l_e);
        out.append("<pre><code");
        if (!lang.empty()) {
          out.append(" class=\"language-");
          escape(lang, out);
          out.append("\"");
        }
        out.append(">");
      } else
        out.append("</code></pre>\n");
      in_code = !in_code;
      return;
    }

    // Block Math
    if ((window & 0xFFFF) == 0x2424) {
      if (in_table) {
        out.append("</tbody></table>\n");
        in_table = false;
      }
      if (!in_math)
        out.append("<div class=\"math\">");
      else
        out.append("</div>\n");
      in_math = !in_math;
      return;
    }

    if (in_math || in_code) {
      escape(line, out);
      out.push_back('\n');
      return;
    }

    // Lists
    bool is_ul = rel.length() >= 2 && rel.substr(0, 2) == "- ";
    bool is_ol =
        rel.length() >= 3 && std::isdigit(rel[0]) && rel.substr(1, 2) == ". ";
    if (is_ul || is_ol) {
      std::string tag = is_ul ? "ul" : "ol";
      while (list_stack.size() < indent + 1) {
        out.append("<");
        out.append(tag);
        out.append(">\n");
        list_stack.push_back(tag);
      }
      while (list_stack.size() > indent + 1) {
        out.append("</");
        out.append(list_stack.back());
        out.append(">\n");
        list_stack.pop_back();
      }
      if (list_stack.back() != tag) {
        out.append("</");
        out.append(list_stack.back());
        out.append(">\n<");
        out.append(tag);
        out.append(">\n");
        list_stack.back() = tag;
      }
      if (is_ul) {
        std::string_view rest = rel.substr(2);
        if (rest.length() >= 4 &&
            (rest.substr(0, 4) == "[ ] " || rest.substr(0, 4) == "[x] ")) {
          out.append("<li><input type=\"checkbox\" ");
          if (rest[1] == 'x')
            out.append("checked ");
          out.append("disabled> ");
          parse_inline(rest.substr(4), out);
          out.append("</li>\n");
        } else {
          out.append("<li>");
          parse_inline(rest, out);
          out.append("</li>\n");
        }
      } else {
        out.append("<li>");
        parse_inline(rel.substr(3), out);
        out.append("</li>\n");
      }
      return;
    } else if (!list_stack.empty()) {
      while (!list_stack.empty()) {
        out.append("</");
        out.append(list_stack.back());
        out.append(">\n");
        list_stack.pop_back();
      }
    }

    // Other blocks (Header, Quote, HR, Table)
    if ((window & 0xFFFF) == 0x2023) {
      out.append("<h1>");
      parse_inline(rel.substr(2), out);
      out.append("</h1>\n");
    } else if ((window & 0xFFFF) == 0x203E) {
      out.append("<blockquote>");
      parse_inline(rel.substr(2), out);
      out.append("</blockquote>\n");
    } else if (trimmed == "---")
      out.append("<hr>\n");
    else if (!rel.empty() && rel[0] == '|') {
      if (!in_table) {
        size_t n_n = full_data.find('\n', next_pos);
        if (n_n != std::string_view::npos) {
          std::string_view la = full_data.substr(next_pos, n_n - next_pos);
          size_t t_s = la.find_first_not_of(" \t\r");
          if (t_s != std::string_view::npos && la[t_s] == '|') {
            std::vector<std::string_view> header, sep;
            auto inline_split = [](std::string_view l,
                                   std::vector<std::string_view> &cells) {
              cells.clear();
              size_t s_p = l.find('|'), e_p = l.rfind('|');
              size_t start = (s_p != std::string_view::npos) ? s_p + 1 : 0;
              size_t end = (e_p != std::string_view::npos && e_p > s_p)
                               ? e_p
                               : l.length();
              std::string_view content = l.substr(start, end - start);
              size_t p = 0;
              while (true) {
                size_t n = content.find('|', p);
                std::string_view c = content.substr(
                    p,
                    (n == std::string_view::npos ? content.length() : n) - p);
                size_t l_s = c.find_first_not_of(" \t"),
                       l_e = c.find_last_not_of(" \t");
                if (l_s != std::string_view::npos)
                  cells.push_back(c.substr(l_s, l_e - l_s + 1));
                else
                  cells.push_back("");
                if (n == std::string_view::npos)
                  break;
                p = n + 1;
              }
            };
            inline_split(rel, header);
            inline_split(la, sep);

            table_aligns.clear();
            for (const auto &s : sep) {
              bool l = !s.empty() && s[0] == ':';
              bool r = !s.empty() && s[s.length() - 1] == ':';
              table_aligns.push_back(
                  l && r ? "center" : (r ? "right" : (l ? "left" : "")));
            }
            out.append("<table><thead><tr>");
            for (size_t i = 0; i < header.size(); ++i) {
              out.append("<th");
              if (i < table_aligns.size() && !table_aligns[i].empty()) {
                out.append(" style=\"text-align:");
                out.append(table_aligns[i]);
                out.append("\"");
              }
              out.append(">");
              parse_inline(header[i], out);
              out.append("</th>");
            }
            out.append("</tr></thead><tbody>\n");
            in_table = true;
          } else {
            out.append("<p>");
            parse_inline(trimmed, out);
            out.append("</p>\n");
          }
        } else {
          out.append("<p>");
          parse_inline(trimmed, out);
          out.append("</p>\n");
        }
      } else {
        out.append("<tr>");
        size_t s_p = rel.find('|'), e_p = rel.rfind('|');
        size_t start = (s_p != std::string_view::npos) ? s_p + 1 : 0;
        size_t end =
            (e_p != std::string_view::npos && e_p > s_p) ? e_p : rel.length();
        std::string_view content = rel.substr(start, end - start);
        size_t p = 0;
        size_t idx = 0;
        while (true) {
          size_t n = content.find('|', p);
          std::string_view c = content.substr(
              p, (n == std::string_view::npos ? content.length() : n) - p);
          size_t c_s = c.find_first_not_of(" \t"),
                 c_e = c.find_last_not_of(" \t");
          std::string_view cell = (c_s != std::string_view::npos)
                                      ? c.substr(c_s, c_e - c_s + 1)
                                      : "";

          out.append("<td");
          if (idx < table_aligns.size() && !table_aligns[idx].empty()) {
            out.append(" style=\"text-align:");
            out.append(table_aligns[idx]);
            out.append("\"");
          }
          out.append(">");
          parse_inline(cell, out);
          out.append("</td>");
          idx++;
          if (n == std::string_view::npos)
            break;
          p = n + 1;
        }
        out.append("</tr>\n");
      }
    } else {
      if (in_table) {
        out.append("</tbody></table>\n");
        in_table = false;
      }
      out.append("<p>");
      parse_inline(trimmed, out);
      out.append("</p>\n");
    }
  }
};

int main() {
  OctoMark om;
  std::string output;
  output.reserve(120 * 1024 * 1024); // Pre-reserve for expected output

  std::cout << "--- Streaming Mode Benchmark ---" << std::endl;
  std::cout << "Generating 100MB of data..." << std::endl;

  std::string line1 = "# Title for testing purposes\n";
  std::string line2 = "- Item list with some **bold** and `code` text\n";
  std::string line3 =
      "Regular paragraph line that should be parsed as p tags correctly.\n";
  std::string full_data;
  full_data.reserve(105 * 1024 * 1024);
  for (int i = 0; i < 750000; ++i) {
    full_data += line1;
    full_data += line2;
    full_data += line3;
  }

  const size_t chunk_size = 64 * 1024; // 64KB chunks
  size_t total_size = full_data.size();

  std::cout << "Starting streaming parse of " << total_size / (1024.0 * 1024.0)
            << " MB..." << std::endl;

  auto t1 = std::chrono::high_resolution_clock::now();

  for (size_t i = 0; i < total_size; i += chunk_size) {
    size_t current_chunk = std::min(chunk_size, total_size - i);
    om.feed(std::string_view(full_data.data() + i, current_chunk), output);
  }
  om.finish(output);

  auto t2 = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double, std::milli> ms = t2 - t1;

  double gb_per_sec =
      (double)total_size / (ms.count() / 1000.0) / (1024.0 * 1024.0 * 1024.0);

  std::cout << "------------------------------------------" << std::endl;
  std::cout << "Time:       " << ms.count() << " ms" << std::endl;
  std::cout << "Throughput: " << gb_per_sec << " GB/s" << std::endl;
  std::cout << "------------------------------------------" << std::endl;

  return 0;
}
