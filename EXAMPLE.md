# OctoMark Example Syntax

This file demonstrates the Markdown syntax supported by OctoMark, including
mixed and nested constructs.

## Headers

# H1 Title
## H2 Title
### H3 Title
#### H4 Title
##### H5 Title
###### H6 Title

---

## Inline Formatting

Plain text with *italic*, **bold**, ***bold+italic***, and ~~strikethrough~~.
Inline code uses backticks like `printf("hello");`.
Escaped characters: \\ \* \_ \` \[ \] \! \~.

Autolink: https://example.com/path?x=1
Link: [Example Link](https://example.com)
Image: ![Alt text](https://example.com/image.png)

Inline math: $E = mc^2$ and $a^2 + b^2 = c^2$.

## Paragraphs and Hard Line Breaks

This line ends with two spaces.  
So this line is a hard break.

## Lists

- Unordered item one
- Unordered item two
  - Nested unordered item
  - Nested item with **bold** text
    - Deeper nested item with `inline code`
- Unordered item three with a [link](https://example.com)

1. Ordered item one
2. Ordered item two
   1. Nested ordered item
   2. Nested ordered item with *emphasis*
3. Ordered item three

Task list:

- [ ] Open task item
- [x] Completed task item

## Blockquotes

> This is a blockquote.
> It can include **bold** text and [links](https://example.com).
>
> - A list inside a blockquote
> - Another item
>   - Nested item
>
> A paragraph inside the quote.

## Mixed and Nested Syntax

- A list item that contains a blockquote:
  > Quoted line with *italic* and `code`.
  >
  > 1. Quoted ordered item
  > 2. Quoted ordered item with **bold**
- A list item with a nested code block:
  ```
  for (int i = 0; i < 3; i++) {
    printf("i=%d\n", i);
  }
  ```
- A list item with inline math $x = y + 1$ and ~~strike~~.

## Fenced Code Blocks

```
Plain code block with no language.
Line two of code.
```

```c
int add(int a, int b) {
  return a + b;
}
```

## Tables

| Name       | Count | Notes       |
|:-----------|------:|:-----------:|
| Alpha      | 1     | left        |
| Beta       | 20    | centered    |
| Gamma      | 300   | right       |

## Definition Lists

Term One
: Definition for term one.

Term Two
: Definition for term two with **bold** and `code`.

## Math Blocks

$$
\int_0^\infty e^{-x} dx = 1
$$

## HTML (when enabled)

<span class="note">Inline HTML passthrough example.</span>
