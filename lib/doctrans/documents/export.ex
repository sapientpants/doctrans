defmodule Doctrans.Documents.Export do
  @moduledoc """
  Renders a document and its pages as a single Markdown artifact.

  Pure rendering: nothing here queries or writes. Callers hand over a document
  whose `:pages` are already loaded and get a string back, which is what lets
  the export be tested without a database and served without a transaction.

  ## Why the artifact is always English

  Every heading, label and status note below is fixed English, independent of
  the interface locale. The export is a document, not interface chrome: two
  people downloading the same document must get byte-identical files, and the
  file outlives the session that produced it -- once it is attached to an email
  nothing explains which locale rendered it. Only the download *button* in the
  UI is translated. A domain module also has no business reaching into
  `DoctransWeb.Gettext`.

  ## What the file carries out of the app

  Page content is model-extracted text, copied verbatim. In the viewer that same
  text is rendered through `DoctransWeb.DocumentLive.MarkdownScrubber`, which is
  the app's only layer in front of it; an export has no such layer and is not
  meant to grow one, because stripping HTML out of a Markdown artifact would
  corrupt legitimate content to defend a renderer this app does not own. The
  export is a data file: whatever opens it afterwards is responsible for how it
  chooses to render raw HTML, exactly as it would be for any other Markdown file.

  ## Why incomplete pages are still rendered

  The export mirrors the whole document rather than the subset that happened to
  succeed. A page that failed, or that has not been translated yet, keeps its
  `## Page N` heading and states *both* stage statuses, so a reader can tell a
  page that is missing from one that was blank to begin with, and an extraction
  failure from a translation failure. The header counts are derived from the
  same classification as the per-page notes, so the summary can never drift
  from the body.
  """

  alias Doctrans.Documents.{Document, Page}
  alias Doctrans.Validation

  # The stem ends up in a `Content-Disposition` header, so it is capped: 100
  # characters still leaves the extension inside every filesystem's 255-byte
  # name limit even where each character costs several bytes.
  @max_stem_length 100
  @fallback_stem "document"
  @unknown "unknown"
  @untitled "Untitled document"

  @preamble "Each `## Page N` heading below marks a page boundary in the original document.\n" <>
              "Model names are the aliases reported during processing and may not identify the\n" <>
              "exact weights used."

  @doc """
  Renders `document` and its loaded pages as Markdown.

  The document's `:pages` must be loaded; an unloaded association raises rather
  than silently exporting a document with no pages.

  Pages are rendered in `page_number` order and headed with their own page
  number, because reprocessing and partial imports can leave gaps: the heading
  has to point at the page in the original PDF, not at its position in the list.
  """
  @spec markdown(Document.t()) :: String.t()
  def markdown(%Document{pages: pages} = document) when is_list(pages) do
    classified =
      pages
      |> Enum.sort_by(& &1.page_number)
      |> Enum.map(&{&1, classify(&1)})

    chunks = header(document, classified) ++ body(classified)

    # Chunks are paragraphs: one blank line between them, one newline at the end.
    Enum.join(chunks, "\n\n") <> "\n"
  end

  @doc """
  Derives the download filename for `document` from its title.

  The result is served in a `Content-Disposition` header, so the title goes
  through `Doctrans.Validation.sanitize_filename_string/1` (path separators,
  `..`, quotes and null bytes), then loses whatever control characters that
  sanitizer maps rather than removes. A title that survives none of this falls
  back to a fixed stem instead of producing a nameless download.
  """
  @spec filename(Document.t()) :: String.t()
  def filename(%Document{} = document) do
    stem =
      document.title
      |> Validation.sanitize_filename_string()
      |> String.replace(~r/[[:cntrl:]]/, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      # Slicing by graphemes keeps the cut off a codepoint boundary, so a long
      # title cannot end in half a character; the trim after it drops the space
      # the cut may have left dangling.
      |> String.slice(0, @max_stem_length)
      |> String.trim()

    case stem do
      "" -> @fallback_stem <> ".md"
      name -> name <> ".md"
    end
  end

  # Every page lands in exactly one class, which is what keeps the header counts
  # and the page notes in agreement.
  defp classify(page) do
    cond do
      translated?(page) -> :translated
      page.translation_status == "completed" -> :empty
      # Failure is `Page.failed_status?/1` and nothing else: the database, the
      # dashboard and this export must not disagree about what failed.
      Page.failed_status?(page) -> :failed
      true -> :pending
    end
  end

  defp translated?(page) do
    page.translation_status == "completed" and present(page.translated_markdown) != nil
  end

  defp header(document, classified) do
    [
      "# " <> present_or(document.title, @untitled),
      metadata(document, classified),
      @preamble
    ]
  end

  defp metadata(document, classified) do
    Enum.join(
      [
        "- **Source file:** #{present_or(document.original_filename, @unknown)}",
        "- **Translation:** #{present_or(document.source_language, @unknown)} → " <>
          present_or(document.target_language, @unknown),
        "- **Pages:** #{page_counts(classified)}",
        "- **Exported:** #{exported_at()}"
      ],
      "\n"
    )
  end

  defp page_counts(classified) do
    total = length(classified)
    translated = count(classified, :translated)
    failed = count(classified, :failed)

    # A page that completed with no content counts as untranslated rather than
    # as translated: the export has nothing of it to show. Deriving the last
    # bucket by subtraction keeps the four numbers adding up whatever classes
    # are added later.
    untranslated = total - translated - failed

    "#{total} total · #{translated} translated · #{failed} failed · " <>
      "#{untranslated} not yet translated"
  end

  defp count(classified, kind), do: Enum.count(classified, fn {_page, class} -> class == kind end)

  # The separator still renders, so an empty document looks like a document
  # with the pages missing rather than like a truncated file.
  defp body([]), do: ["---", "_This document has no pages._"]
  defp body(classified), do: Enum.flat_map(classified, &page_chunks/1)

  defp page_chunks({page, class}) do
    ["---", "## Page #{page.page_number}"] ++ page_body(page, class)
  end

  defp page_body(page, :translated), do: [content(page)] ++ provenance(page)

  defp page_body(_page, :empty), do: ["> **Translated as empty.** This page produced no content."]

  defp page_body(page, :failed), do: [note("Not translated: this page failed.", page)]

  defp page_body(page, :pending), do: [note("Not translated yet.", page)]

  defp note(headline, page) do
    "> **#{headline}** Extraction: #{page.extraction_status}. " <>
      "Translation: #{page.translation_status}."
  end

  # Verbatim but for line endings and the blank lines around it: the model's
  # markdown is the payload, while a stray CR would show up as a literal escape
  # in strict Markdown renderers.
  defp content(page) do
    page.translated_markdown
    |> String.replace(~r/\r\n?/, "\n")
    |> String.trim()
  end

  # Only the models actually recorded are named; an omitted line is honest about
  # provenance the run never captured, where "unknown" would read as a claim.
  defp provenance(page) do
    case {present(page.extraction_model), present(page.translation_model)} do
      {nil, nil} ->
        []

      {extraction, nil} ->
        ["_Extracted with `#{extraction}`._"]

      {nil, translation} ->
        ["_Translated with `#{translation}`._"]

      {extraction, translation} ->
        ["_Extracted with `#{extraction}`; translated with `#{translation}`._"]
    end
  end

  defp exported_at do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp present_or(value, default), do: present(value) || default
end
