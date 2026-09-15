defmodule DoctransWeb.DocumentLive.ModelProvenanceTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents.Pages

  # Each identifier gets its own element, so each claim is checked through its
  # own selector: reading the whole panel instead lets the extraction model
  # satisfy an assertion meant for the translation model.
  @section "#page-processing-models"
  @extraction "#page-extraction-model"
  @translation "#page-translation-model"
  @caveat "#page-processing-models-caveat"
  @progress "#document-processing-progress"

  # A page whose run recorded which models actually produced its content.
  defp page_with_models(document, models) do
    page = page_fixture(document)

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        extraction_model: models.extraction,
        original_markdown: "# Original"
      })

    {:ok, page} =
      Pages.update_page_translation(page, %{
        translation_status: "completed",
        translation_model: models.translation,
        translated_markdown: "# Translated"
      })

    page
  end

  defp open(conn, document) do
    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")
    view
  end

  test "names the models recorded for a finished page, after progress is gone", %{conn: conn} do
    document = document_fixture(%{status: "completed", total_pages: 1})
    page_with_models(document, %{extraction: "qwen3-vl:8b", translation: "qwen3:14b"})

    view = open(conn, document)

    # The regression: provenance used to live inside the progress section, so
    # finishing the document took the model names away with the progress bar.
    refute has_element?(view, @progress)
    assert has_element?(view, "section#page-processing-models[aria-label]")
    assert element_html(view, @extraction) =~ "qwen3-vl:8b"
    assert element_html(view, @translation) =~ "qwen3:14b"
    refute element_html(view, @extraction) =~ "qwen3:14b"
  end

  test "says nothing is recorded yet while the page is still being processed", %{conn: conn} do
    document = document_fixture(%{status: "processing", total_pages: 1})

    page_fixture(document, %{
      extraction_status: "processing",
      translation_status: "pending"
    })

    view = open(conn, document)

    # An unfinished stage has no model yet, which must not be reported as a
    # model the run failed to record -- nor filled in from configuration.
    assert element_html(view, @extraction) =~ "not recorded yet"
    assert element_html(view, @translation) =~ "not recorded yet"
    refute element_html(view, @section) =~ "unknown"
  end

  test "keeps a recorded extraction model while translation is still pending", %{conn: conn} do
    document = document_fixture(%{status: "processing", total_pages: 1})
    page = page_fixture(document)

    {:ok, _page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        extraction_model: "extractor-x",
        original_markdown: "# Original"
      })

    view = open(conn, document)

    # The two-way distinction earns its keep here: one stage has a real record
    # while the other genuinely has nothing to report yet.
    assert element_html(view, @extraction) =~ "extractor-x"
    assert element_html(view, @translation) =~ "not recorded yet"
  end

  test "reports a legacy page finished without recorded models as unknown", %{conn: conn} do
    document = document_fixture(%{status: "completed", total_pages: 1})
    # Predates provenance recording: finished, but both model columns are null.
    completed_page_fixture(document)

    view = open(conn, document)

    assert element_html(view, @extraction) =~ "unknown"
    assert element_html(view, @translation) =~ "unknown"
    refute element_html(view, @section) =~ "not recorded yet"
  end

  test "distinguishes a failed run from a page that predates provenance", %{conn: conn} do
    document = document_fixture(%{status: "error", total_pages: 1})

    page_fixture(document, %{
      extraction_status: "error",
      translation_status: "pending"
    })

    view = open(conn, document)

    # Extraction ran and failed; translation never started and never will, so
    # neither stage may claim a record is merely still on its way.
    assert element_html(view, @extraction) =~ "run failed"
    assert element_html(view, @translation) =~ "did not run"
    refute element_html(view, @section) =~ "not recorded yet"
  end

  test "reports a failed translation as a failed run", %{conn: conn} do
    document = document_fixture(%{status: "error", total_pages: 1})
    page = page_fixture(document)

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        extraction_model: "extractor-x",
        original_markdown: "# Original"
      })

    {:ok, _page} = Pages.update_page_translation(page, %{translation_status: "error"})

    view = open(conn, document)

    assert element_html(view, @extraction) =~ "extractor-x"
    assert element_html(view, @translation) =~ "run failed"
  end

  test "reports a page with no extracted text as needing no translation", %{conn: conn} do
    document = document_fixture(%{status: "completed", total_pages: 1})
    page = page_fixture(document)

    {:ok, page} =
      Pages.update_page_extraction(page, %{
        extraction_status: "completed",
        extraction_model: "extractor-x",
        original_markdown: ""
      })

    # `LlmProcessor` completes an empty page without calling a translation
    # model, so the null column is accurate rather than a missing record.
    {:ok, _page} = Pages.update_page_translation(page, %{translation_status: "completed"})

    view = open(conn, document)

    assert element_html(view, @translation) =~ "no content to translate"
    refute element_html(view, @translation) =~ "unknown"
  end

  test "carries the caveat that an alias does not identify the weights", %{conn: conn} do
    document = document_fixture(%{status: "completed", total_pages: 1})
    page_with_models(document, %{extraction: "gpt-4o", translation: "gpt-4o"})

    view = open(conn, document)

    assert element_html(view, @caveat) =~ "may not identify the exact weights used"
  end

  test "drops the alias caveat when no model name is on screen", %{conn: conn} do
    document = document_fixture(%{status: "completed", total_pages: 1})
    completed_page_fixture(document)

    view = open(conn, document)

    # Nothing on the line is an alias, so the caveat has nothing to qualify.
    assert has_element?(view, @section)
    refute has_element?(view, @caveat)
  end

  test "renders nothing for a document whose pages do not exist yet", %{conn: conn} do
    document = document_fixture(%{status: "extracting", total_pages: 2})

    view = open(conn, document)

    refute has_element?(view, @section)
  end
end
