defmodule DoctransWeb.DocumentLive.MarkdownSanitizationTest do
  @moduledoc """
  End-to-end proof that the Markdown sanitizer is *wired into* the live render
  path, not merely correct when called directly.

  `markdown_helpers_test.exs` covers the scrubber and the renderer in isolation.
  What it cannot show is that every surface which reaches `raw/1` actually goes
  through them. There are exactly three such surfaces, all fed by content the
  application does not author -- the translated page, the original (OCR'd) page,
  and a chat answer -- so each one is driven here through `DocumentLive.Show`
  with a payload in the stored Markdown, and asserted against the HTML the
  LiveView really sends.

  Two layers stand between that Markdown and the page, and the tests below are
  written to keep both honest:

    * MDEx renders in safe mode, so raw HTML becomes a `<!-- raw HTML omitted -->`
      comment and a link or image target with a dangerous scheme is blanked to
      `""`.
    * `MarkdownScrubber` then scrubs the result, which is also what removes those
      comments.

  Because MDEx alone already defuses most payloads, an assertion that only looks
  for `<script>` would still pass with the scrubber unhooked. Each test therefore
  also asserts that no `raw HTML omitted` comment reaches the page: that artifact
  is produced by MDEx and removed *only* by the scrubber, so it fails the moment
  `sanitize_html/1` stops being called.
  """

  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Chat.Conversations
  alias Doctrans.Documents
  alias Doctrans.Documents.Pages

  # One payload for all three surfaces. The first block is HTML-native -- what
  # the unit tests already cover -- and the second is Markdown-native, which they
  # cannot reach because they start from HTML. The benign lines are load-bearing:
  # a sanitizer that dropped everything would pass the negative assertions alone.
  @payload ~S"""
  # Quarterly Report

  <script>alert('xss')</script>
  <img src="x" onerror="alert('xss')">
  <iframe src="https://evil.test"><iframe srcdoc="<script>alert('xss')</script>"></iframe></iframe>
  <a href="https://example.com" onclick="alert('xss')">handler</a>
  <style>body{display:none}</style>

  The **totals** are below.

  [inline](javascript:alert(1))
  [uppercase](JaVaScRiPt:alert(1))
  ![data image](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)
  [reference][ref]
  ![image reference][imgref]
  <javascript:alert(1)>

  [Safe link](https://example.com/report)

  [ref]: javascript:alert(1)
  [imgref]: data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==
  """

  # Anything that executes, frames, styles, or carries an event handler. Kept in
  # one place so the three surfaces are held to the same bar.
  @executable "script, iframe, frame, object, embed, style, form, input, " <>
                "[onclick], [onerror], [onload], [onmouseover], [srcdoc], [style]"

  @dangerous_schemes ~w(javascript: data: vbscript:)

  describe "translated page content" do
    test "neutralises a payload stored in translated_markdown", %{conn: conn} do
      document = payload_document()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      assert_sanitized(view, "#translated-panel .markdown")
    end
  end

  describe "original page content" do
    test "neutralises a payload stored in original_markdown", %{conn: conn} do
      document = payload_document()

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

      # The OCR'd original is a second render path behind the toggle, fed by the
      # same model output, so it gets the same treatment rather than being
      # assumed to share the translated panel's fate.
      view |> element("#translated-panel input[phx-click='toggle_original']") |> render_click()

      assert_sanitized(view, "#translated-panel .markdown")
    end
  end

  describe "chat answers" do
    test "neutralises a payload streamed back as an assistant message", %{conn: conn} do
      document = completed_document_with_embedding_fixture()
      question = Conversations.start_question(document.id, "What are the totals?")
      {:ok, answer} = Conversations.finish(question, "assistant", @payload, [])

      {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
      view |> element("header button[phx-click='toggle_chat']") |> render_click()

      assert has_element?(view, "#chat_messages-#{answer.id}")

      # The chat renders with `hardbreaks: true`, a different MDEx option set
      # from the viewer's, so the payload is re-asserted against that path too.
      assert_sanitized(view, "#chat_messages-#{answer.id} .markdown")
    end
  end

  # The whole bar one rendered surface has to clear.
  defp assert_sanitized(view, selector) do
    content = subtree(view, selector)

    assert_neutralised(content)
    assert_benign_content_survives(content)
    assert_scrubber_ran(view, selector)
  end

  # Everything dangerous is gone, from both the HTML-native and the
  # Markdown-native halves of the payload.
  defp assert_neutralised(content) do
    assert Enum.empty?(LazyHTML.query(content, @executable))

    # The links and the image survive as elements -- MDEx blanks the target
    # rather than dropping the node -- so assert on the targets that reach the
    # browser, not on the elements being absent.
    hrefs = targets(content, "a", "href")
    srcs = targets(content, "img", "src")

    refute Enum.empty?(hrefs), "no link rendered: the payload's links went missing entirely"
    refute Enum.empty?(srcs), "no image rendered: the payload's images went missing entirely"
    refute Enum.any?(hrefs, &dangerous_scheme?/1)
    refute Enum.any?(srcs, &dangerous_scheme?/1)
  end

  # Benign Markdown still renders: headings, emphasis, and a safe link keep
  # their elements and their targets.
  defp assert_benign_content_survives(content) do
    assert LazyHTML.text(LazyHTML.query(content, "h1")) == "Quarterly Report"
    assert LazyHTML.text(LazyHTML.query(content, "strong")) == "totals"
    assert "https://example.com/report" in targets(content, "a", "href")
  end

  # The one artifact only the scrubber removes. See the moduledoc: without this,
  # every assertion above would still pass with `sanitize_html/1` unhooked,
  # because MDEx's safe mode defuses the payload on its own.
  defp assert_scrubber_ran(view, selector) do
    refute element_html(view, selector) =~ "raw HTML omitted"
  end

  defp subtree(view, selector) do
    subtree = view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector)
    assert Enum.count(subtree) == 1, "expected exactly one #{selector} in the rendered view"
    subtree
  end

  defp targets(content, selector, attribute) do
    content |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute)
  end

  defp dangerous_scheme?(target) do
    trimmed = target |> String.trim() |> String.downcase()
    String.starts_with?(trimmed, @dangerous_schemes)
  end

  defp payload_document do
    document = document_fixture(%{status: "completed", total_pages: 1})
    page = page_fixture(document, %{page_number: 1})

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        original_markdown: @payload
      })

    {:ok, _page} =
      Pages.update_page_translation(page, %{
        translation_status: "completed",
        translated_markdown: @payload
      })

    Documents.get_document_with_pages!(document.id)
  end
end
