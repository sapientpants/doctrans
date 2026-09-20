defmodule DoctransWeb.DocumentLive.MarkdownHelpersTest do
  use ExUnit.Case, async: true

  alias DoctransWeb.DocumentLive.MarkdownHelpers

  # Shape of a table an OCR pass produces from an invoice-like page: a header
  # row, a delimiter row carrying per-column alignment, and numeric body rows.
  @ocr_table """
  | Item    | Qty | Unit Price | Total |
  | ------- | ---:|   :---:    | ---:  |
  | Widget  | 12  | 3.50       | 42.00 |
  | Gadget  | 7   | 12.00      | 84.00 |
  | Sprocket| 103 | 0.25       | 25.75 |
  """

  defp document(html), do: LazyHTML.from_document(html)

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.text/1)
  end

  defp count(document, selector) do
    document |> LazyHTML.query(selector) |> Enum.count()
  end

  describe "sanitize_html/1" do
    test "removes executable elements, including nested frames, and preserves safe formatting" do
      html = """
      <p><strong>Keep this</strong></p>
      <script>alert('x')</script>
      <iframe src="https://example.com"><iframe srcdoc="<script>alert('x')</script>"></iframe></iframe>
      """

      document = html |> MarkdownHelpers.sanitize_html() |> LazyHTML.from_document()

      assert LazyHTML.text(LazyHTML.query(document, "strong")) == "Keep this"
      assert Enum.empty?(LazyHTML.query(document, "script, iframe"))
    end

    test "strips image event handlers and javascript links while keeping safe links" do
      html = """
      <img src="missing.png" onerror="alert('x')">
      <a href="javascript:alert('x')" onclick="alert('x')">Unsafe</a>
      <a href="https://example.com">Safe</a>
      """

      document = html |> MarkdownHelpers.sanitize_html() |> LazyHTML.from_document()

      assert Enum.empty?(LazyHTML.query(document, "[onerror], [onclick], a[href^='javascript:']"))
      assert LazyHTML.text(LazyHTML.query(document, "a[href='https://example.com']")) == "Safe"
    end

    test "scrubs scripts, handlers, frames, and styles out of table cells" do
      html = """
      <table><tbody>
      <tr><td><script>alert('x')</script>cell one</td></tr>
      <tr><td onclick="alert('x')">cell two</td></tr>
      <tr><td><a href="javascript:alert('x')">cell three</a></td></tr>
      <tr><td><iframe src="https://evil.test"></iframe>cell four</td></tr>
      <tr><td><style>td{display:none}</style>cell five</td></tr>
      </tbody></table>
      """

      document = html |> MarkdownHelpers.sanitize_html() |> document()

      assert Enum.empty?(
               LazyHTML.query(
                 document,
                 "script, iframe, style, [onclick], a[href^='javascript:']"
               )
             )

      assert count(document, "td") == 5

      # Script and style bodies survive only as inert text, as they do for
      # basic_html/1 everywhere else; what matters is that no element remains.
      assert texts(document, "td") == [
               "alert('x')cell one",
               "cell two",
               "cell three",
               "cell four",
               "td{display:none}cell five"
             ]
    end

    test "keeps only the alignment values a Markdown delimiter row can produce" do
      html = """
      <table><tbody><tr>
      <td align="right">kept</td>
      <td align="justify">dropped</td>
      <td align="expression(alert('x'))">dropped</td>
      <td align="RIGHT">dropped</td>
      </tr></tbody></table>
      """

      document = html |> MarkdownHelpers.sanitize_html() |> document()

      assert count(document, "td") == 4
      assert texts(document, "td[align]") == ["kept"]
    end

    test "matches the alignment value, not the attribute spelling" do
      # The parser lowercases attribute names and decodes entities before the
      # value match runs, so these reach the page as align="right". Recorded
      # because the test above could otherwise read as if the name were checked
      # too — it is not, and it does not need to be: align carries no payload.
      html = """
      <table><tbody><tr>
      <td ALIGN="right">upper</td>
      <td align="&#114;ight">entity</td>
      <td align="right" onload="alert('x')">handler</td>
      <td align=" right">padded</td>
      </tr></tbody></table>
      """

      document = html |> MarkdownHelpers.sanitize_html() |> document()

      assert texts(document, "td[align='right']") == ["upper", "entity", "handler"]
      assert texts(document, "td[align]") == ["upper", "entity", "handler"]
      assert count(document, "td[onload]") == 0
    end

    test "allows nothing beyond basic_html apart from table cell alignment" do
      samples = [
        ~S|<b>b</b><blockquote>q</blockquote><br><code>c</code><del>d</del><em>e</em>|,
        ~S|<h1>1</h1><h2>2</h2><h3>3</h3><h4>4</h4><h5>5</h5><h6>6</h6><hr><i>i</i>|,
        ~S|<li>l</li><ol>o</ol><p>p</p><pre>pre</pre><span>s</span><strong>x</strong>|,
        ~S|<table><thead><tr><th>h</th></tr></thead><tbody><tr><td>t</td></tr></tbody></table>|,
        ~S|<u>u</u><ul>ul</ul><a name="n" title="t" href="mailto:a@b.c">a</a>|,
        ~S|<img src="https://example.com/y.png" width="1" height="2" title="t" alt="a">|,
        ~S|<p onclick="x" class="y" style="color: red" align="right">p</p>|,
        ~S|<div>d</div><video src="v">inner</video><form><input name="n"></form>|,
        ~S|<td colspan="2" rowspan="3" class="c" width="4" title="t">x</td>|,
        ~S|<th scope="col" abbr="a" onmouseover="alert('x')">h</th>|,
        ~S|<table align="right"><tr align="center"><td>x</td></tr></table>|
      ]

      for sample <- samples do
        assert MarkdownHelpers.sanitize_html(sample) == HtmlSanitizeEx.basic_html(sample),
               "scrubber diverged from basic_html for: #{sample}"
      end
    end

    # The test above is relative: it would still pass if a future html_sanitize_ex
    # started allowing extra table-cell attributes, because both sides would gain
    # them together. MarkdownScrubber's moduledoc asserts that `align` is the only
    # attribute surviving on a cell, so pin that absolutely.
    test "keeps align as the only attribute on a table cell" do
      html =
        MarkdownHelpers.sanitize_html("""
        <table><tbody><tr>
        <td align="right" colspan="2" rowspan="3" class="c" style="color:red"
            width="4" title="t" id="i" role="cell" onclick="alert('x')">x</td>
        </tr></tbody></table>
        """)

      document = document(html)

      assert count(document, "td[align='right']") == 1

      assert Enum.empty?(
               LazyHTML.query(
                 document,
                 "td[colspan], td[rowspan], td[class], td[style], td[width], td[title], td[id], td[role], td[onclick]"
               )
             )
    end
  end

  describe "render_markdown/2" do
    test "returns empty string for nil and empty input" do
      assert MarkdownHelpers.render_markdown(nil) == ""
      assert MarkdownHelpers.render_markdown("") == ""
    end

    test "renders basic markdown" do
      assert MarkdownHelpers.render_markdown("**bold**") =~ "<strong>bold</strong>"
    end

    test "collapses single newlines by default (CommonMark soft breaks)" do
      html = MarkdownHelpers.render_markdown("line one\nline two")
      refute html =~ "<br"
    end

    test "renders single newlines as hard breaks when :hardbreaks is set" do
      html = MarkdownHelpers.render_markdown("line one\nline two", hardbreaks: true)
      assert html =~ "<br"
    end

    test "sanitizes dangerous html" do
      html = MarkdownHelpers.render_markdown("<script>alert('x')</script>")
      refute html =~ "<script"
    end
  end

  # Every `sanitize_html/1` test above starts from HTML, so none of them reaches
  # a link or image whose target is written as *Markdown*. Those never arrive at
  # the scrubber as an attribute at all: MDEx renders in safe mode and blanks a
  # dangerous destination to `""` while producing the HTML, so the scrubber only
  # ever sees `href=""`.
  #
  # That makes this block the only thing standing between the model and a live
  # `javascript:` link, and it is one option away from being needed: `unsafe:
  # true` in `mdex_options/1` would hand every vector below straight to the page.
  # Asserted on the rendered anchor rather than as `refute html =~ "javascript:"`,
  # which would also pass if rendering stopped emitting the link entirely.
  describe "render_markdown/2 link and image targets" do
    test "blanks a dangerous link destination, whatever its spelling" do
      for markdown <- [
            "[x](javascript:alert(1))",
            "[x](JaVaScRiPt:alert(1))",
            "[x](java&#115;cript:alert(1))",
            "[x](&#106;avascript:alert(1))",
            "[x](<  javascript:alert(1)>)",
            "[x]( javascript:alert(1) )",
            "[x](vbscript:msgbox(1))",
            "[x](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)"
          ] do
        document = markdown |> MarkdownHelpers.render_markdown() |> document()

        assert texts(document, "a") == ["x"], "link was not rendered for: #{markdown}"
        assert count(document, "a[href='']") == 1, "destination survived: #{markdown}"
      end
    end

    test "blanks a dangerous image source" do
      for markdown <- [
            "![](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)",
            "![alt](javascript:alert(1))",
            "![alt](DATA:text/html,<script>alert(1)</script>)"
          ] do
        document = markdown |> MarkdownHelpers.render_markdown() |> document()

        assert count(document, "img") == 1, "image was not rendered for: #{markdown}"
        assert count(document, "img[src='']") == 1, "source survived: #{markdown}"
      end
    end

    test "blanks a dangerous reference-style link and image too" do
      # A reference definition is resolved after the inline pass, which is the
      # reason to assert it separately from the inline spelling above.
      markdown = """
      [link][ref] and ![image][imgref]

      [ref]: javascript:alert(1)
      [imgref]: data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==
      """

      document = markdown |> MarkdownHelpers.render_markdown() |> document()

      assert texts(document, "a") == ["link"]
      assert count(document, "a[href='']") == 1
      assert count(document, "img[src='']") == 1
      assert LazyHTML.attribute(LazyHTML.query(document, "img"), "alt") == ["image"]
    end

    test "blanks an autolink, leaving the scheme as inert text" do
      document = "<javascript:alert(1)>" |> MarkdownHelpers.render_markdown() |> document()

      # The scheme still appears, but only as the anchor's *text*. Recorded so a
      # reader does not mistake it for a surviving payload.
      assert texts(document, "a") == ["javascript:alert(1)"]
      assert count(document, "a[href='']") == 1
    end

    test "cannot break out of the title attribute a link destination carries" do
      markdown = ~S{[x](https://example.com "a\" onmouseover=alert(1) x=\"")}

      html = MarkdownHelpers.render_markdown(markdown)
      document = document(html)

      assert LazyHTML.attribute(LazyHTML.query(document, "a"), "href") ==
               ["https://example.com"]

      assert count(document, "a[onmouseover]") == 0
      assert count(document, "[onmouseover]") == 0
    end

    test "keeps the link and image targets a document legitimately uses" do
      markdown = """
      [https](https://example.com/a?b=1#c), [mail](mailto:a@b.c),
      [relative](/documents/1), [anchor](#section) and
      ![figure](https://example.com/figure.png)
      """

      document = markdown |> MarkdownHelpers.render_markdown() |> document()

      assert LazyHTML.attribute(LazyHTML.query(document, "a"), "href") == [
               "https://example.com/a?b=1#c",
               "mailto:a@b.c",
               "/documents/1",
               "#section"
             ]

      assert LazyHTML.attribute(LazyHTML.query(document, "img"), "src") ==
               ["https://example.com/figure.png"]
    end

    test "blanks the same destinations through the hardbreaks chat path" do
      # The chat renders with a different MDEx option set, so the safe-mode
      # behaviour is re-asserted there rather than assumed to carry over.
      markdown = "[a](javascript:alert(1))\n![b](data:text/html;base64,PHN2Zz4=)"

      document =
        markdown |> MarkdownHelpers.render_markdown(hardbreaks: true) |> document()

      assert count(document, "a[href='']") == 1
      assert count(document, "img[src='']") == 1
      assert count(document, "br") == 1
    end
  end

  describe "render_markdown/2 tables" do
    test "renders an OCR-style table as table elements with the right cell contents" do
      document = @ocr_table |> MarkdownHelpers.render_markdown() |> document()

      assert count(document, "table") == 1
      assert count(document, "table > thead") == 1
      assert count(document, "table > tbody") == 1
      assert count(document, "thead > tr") == 1
      assert count(document, "tbody > tr") == 3
      assert count(document, "thead th") == 4
      assert count(document, "tbody td") == 12
      assert Enum.empty?(LazyHTML.query(document, "thead td, tbody th"))

      assert texts(document, "thead th") == ["Item", "Qty", "Unit Price", "Total"]

      assert texts(document, "tbody tr:first-child td") == ["Widget", "12", "3.50", "42.00"]
      assert texts(document, "tbody tr:last-child td") == ["Sprocket", "103", "0.25", "25.75"]
    end

    test "renders the same table through the hardbreaks chat path" do
      # The paragraph's single newline must still become a `<br>` while the table
      # rows become table structure. Asserting the `<br>` count outside the table
      # keeps the in-table assertion below from passing vacuously: before the
      # table extension, every one of these lines was one paragraph of `<br>`s.
      answer = "Totals below:\nper the invoice.\n\n" <> @ocr_table

      document = answer |> MarkdownHelpers.render_markdown(hardbreaks: true) |> document()

      assert count(document, "table") == 1
      assert count(document, "thead th") == 4
      assert count(document, "tbody tr") == 3
      assert count(document, "tbody td") == 12
      assert texts(document, "thead th") == ["Item", "Qty", "Unit Price", "Total"]
      assert texts(document, "tbody tr:first-child td") == ["Widget", "12", "3.50", "42.00"]

      assert count(document, "p br") == 1
      assert count(document, "table br") == 0
    end

    test "renders a table emitted mid-answer with single newlines around it" do
      answer = "Here are the totals:\n| A | B |\n| --- | ---: |\n| 1 | 2 |\n\nHope that helps."

      document = answer |> MarkdownHelpers.render_markdown(hardbreaks: true) |> document()

      assert count(document, "table") == 1
      assert texts(document, "thead th") == ["A", "B"]
      assert texts(document, "tbody td") == ["1", "2"]
      assert texts(document, "p") == ["Here are the totals:", "Hope that helps."]
    end

    test "absorbs a line written straight after the last row, as GFM requires" do
      # A GFM table runs until a blank line, so a sentence on the line after the
      # last row becomes another row rather than a paragraph. Recorded rather than
      # worked around: it is the specified behaviour, it is what any GFM renderer
      # does, and the chat path is where it shows — an answer that ends its table
      # without a blank line puts its closing sentence in a cell.
      answer = "| A | B |\n| --- | ---: |\n| 1 | 2 |\nThat is all."

      document = answer |> MarkdownHelpers.render_markdown(hardbreaks: true) |> document()

      assert texts(document, "tbody tr:last-child td") == ["That is all.", ""]
      assert Enum.empty?(LazyHTML.query(document, "p"))
    end

    test "preserves the column alignment declared by the delimiter row" do
      document = @ocr_table |> MarkdownHelpers.render_markdown() |> document()

      assert texts(document, "thead th[align='right']") == ["Qty", "Total"]
      assert texts(document, "thead th[align='center']") == ["Unit Price"]
      assert texts(document, "thead th:not([align])") == ["Item"]

      assert texts(document, "tbody tr:first-child td[align='right']") == ["12", "42.00"]
      assert texts(document, "tbody tr:first-child td[align='center']") == ["3.50"]
      assert texts(document, "tbody tr:first-child td:not([align])") == ["Widget"]
    end

    test "preserves column alignment through the hardbreaks chat path too" do
      document = @ocr_table |> MarkdownHelpers.render_markdown(hardbreaks: true) |> document()

      assert texts(document, "thead th[align='right']") == ["Qty", "Total"]
      assert texts(document, "tbody tr:last-child td[align='right']") == ["103", "25.75"]
    end

    test "keeps left alignment explicitly requested with a leading colon" do
      markdown = "| L | R |\n| :--- | ---: |\n| a | b |\n"

      document = markdown |> MarkdownHelpers.render_markdown() |> document()

      assert texts(document, "th[align='left']") == ["L"]
      assert texts(document, "td[align='left']") == ["a"]
    end

    test "scrubs dangerous cell content while keeping the table structure" do
      markdown = """
      | Payload |
      | ------- |
      | <script>alert('x')</script>one |
      | <span onclick="alert('x')">two</span> |
      | [three](javascript:alert('x')) |
      | <iframe src="https://evil.test"></iframe>four |
      | <style>td{display:none}</style>five |
      """

      html = MarkdownHelpers.render_markdown(markdown)
      document = document(html)

      assert Enum.empty?(
               LazyHTML.query(
                 document,
                 "script, iframe, style, [onclick], a[href^='javascript:']"
               )
             )

      # Belt-and-braces on the serialized output, so a payload that LazyHTML
      # parses into a shape the selectors above miss still fails the test.
      refute html =~ "<script"
      refute html =~ "onclick"

      # `javascript:` never reaches the scrubber: MDEx blanks a non-http(s) link
      # target itself. Asserted on the anchor rather than as `refute html =~
      # "javascript:"`, which would pass even if the scrubber stopped running.
      assert texts(document, "tbody a") == ["three"]
      assert count(document, "tbody a[href='']") == 1

      assert count(document, "tbody td") == 5

      # MDEx escapes the raw HTML and the scrubber drops the resulting comments,
      # so only inert text is left in the cells.
      assert texts(document, "tbody td") == [
               "alert('x')one",
               "two",
               "three",
               "four",
               "td{display:none}five"
             ]
    end

    test "leaves a table without a delimiter row as plain text" do
      markdown = "| Item | Qty |\n| Widget | 12 |\n"

      document = markdown |> MarkdownHelpers.render_markdown() |> document()

      assert Enum.empty?(LazyHTML.query(document, "table"))
      assert count(document, "p") == 1
      assert LazyHTML.text(LazyHTML.query(document, "p")) =~ "Widget"
    end

    test "pads and truncates ragged rows instead of crashing" do
      markdown = "| A | B |\n| --- | --- |\n| 1 |\n| 2 | 3 | 4 |\n"

      document = markdown |> MarkdownHelpers.render_markdown() |> document()

      assert count(document, "table") == 1
      assert count(document, "tbody tr") == 2
      assert texts(document, "tbody tr:first-child td") == ["1", ""]
      assert texts(document, "tbody tr:last-child td") == ["2", "3"]
    end

    test "renders headings and lists alongside a table in one document" do
      markdown = """
      # Invoice

      - first
      - second

      | A | B |
      | --- | --- |
      | 1 | 2 |
      """

      document = markdown |> MarkdownHelpers.render_markdown() |> document()

      assert LazyHTML.text(LazyHTML.query(document, "h1")) == "Invoice"
      assert texts(document, "ul > li") == ["first", "second"]
      assert count(document, "table") == 1
    end
  end
end
