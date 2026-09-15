defmodule DoctransWeb.DocumentLive.ModelProvenanceTest do
  use DoctransWeb.ConnCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents.Pages

  # Each identifier gets its own element, so each claim is checked through its
  # own selector: reading the whole panel instead lets the extraction model
  # satisfy an assertion meant for the translation model, and a page rendering
  # one model twice would still pass.
  @section "#page-processing-models"
  @extraction "#page-extraction-model"
  @translation "#page-translation-model"
  @caveat "#page-processing-models-caveat"
  @progress "#document-processing-progress"

  defp text(view, selector), do: view |> element(selector) |> render()

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

  test "names the models recorded for a finished page, after progress is gone", %{conn: conn} do
    document = document_fixture(%{status: "completed", total_pages: 1})
    page_with_models(document, %{extraction: "qwen3-vl:8b", translation: "qwen3:14b"})

    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    # The regression: provenance used to live inside the progress section, so
    # finishing the document took the model names away with the progress bar.
    refute has_element?(view, @progress)
    assert has_element?(view, @section)
    assert text(view, @extraction) =~ "qwen3-vl:8b"
    assert text(view, @translation) =~ "qwen3:14b"
  end

  test "keeps each stage's model on its own line", %{conn: conn} do
    document = document_fixture(%{status: "completed", total_pages: 1})
    page_with_models(document, %{extraction: "extractor-only", translation: "translator-only"})

    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    refute text(view, @extraction) =~ "translator-only"
    refute text(view, @translation) =~ "extractor-only"
  end

  test "says nothing is recorded yet while the page is still being processed", %{conn: conn} do
    document = document_fixture(%{status: "processing", total_pages: 1})

    page_fixture(document, %{
      extraction_status: "processing",
      translation_status: "pending"
    })

    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    # An unfinished stage has no model yet, which must not be reported as a
    # model the run failed to record -- nor filled in from configuration.
    assert text(view, @extraction) =~ "not recorded yet"
    assert text(view, @translation) =~ "not recorded yet"
    refute text(view, @section) =~ "Unknown"
  end

  test "reports a legacy page finished without recorded models as unknown", %{conn: conn} do
    document = document_fixture(%{status: "completed", total_pages: 1})
    # Predates provenance recording: finished, but both model columns are null.
    completed_page_fixture(document)

    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    assert text(view, @extraction) =~ "Unknown"
    assert text(view, @translation) =~ "Unknown"
    refute text(view, @section) =~ "not recorded yet"
  end

  test "carries the caveat that an alias does not identify the weights", %{conn: conn} do
    document = document_fixture(%{status: "completed", total_pages: 1})
    page_with_models(document, %{extraction: "gpt-4o", translation: "gpt-4o"})

    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    assert text(view, @caveat) =~ "may not identify the exact weights used"
  end

  test "renders nothing for a document whose pages do not exist yet", %{conn: conn} do
    document = document_fixture(%{status: "extracting", total_pages: 2})

    {:ok, view, _html} = live(conn, ~p"/documents/#{document.id}")

    refute has_element?(view, @section)
  end
end
