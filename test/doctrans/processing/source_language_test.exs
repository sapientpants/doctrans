defmodule Doctrans.Processing.SourceLanguageTest do
  @moduledoc """
  Covers the per-document source language: translation reads the language off
  the document being processed, not off an app-wide default.

  The translator `config/test.exs` installs, `Doctrans.Processing.OpenAIStub`,
  echoes the pair it was called with into the markdown it returns, so the
  language a page was actually translated *from* survives on that page's row.
  Asserting on the persisted `translated_markdown` keys the evidence to the page
  rather than to the order two concurrent runs happen to report in.

  `async: false`: the translator is selected through global application env, and
  the retry test overrides `:defaults` the same way.
  """

  use Doctrans.DataCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Processing.LlmProcessor
  alias Doctrans.TestEnv

  describe "process_page/3 source language" do
    test "two documents processing concurrently each translate from their own source language" do
      {_german, german_page} = staged_page(%{source_language: "de", target_language: "en"})
      {_french, french_page} = staged_page(%{source_language: "fr", target_language: "en"})

      owner = self()

      tasks =
        for page <- [german_page, french_page] do
          Task.async(fn ->
            send(owner, {:ready, self()})

            receive do
              :go -> LlmProcessor.process_page(page.id, MapSet.new())
            end
          end)
        end

      # Park both runs at the barrier and release them together, so the two
      # translations are genuinely in flight at once rather than queued.
      pids =
        for _ <- tasks do
          assert_receive {:ready, pid}, 5_000
          pid
        end

      Enum.each(pids, &send(&1, :go))

      assert Task.await_many(tasks, 30_000) == [:ok, :ok]

      german = Documents.get_page!(german_page.id)
      french = Documents.get_page!(french_page.id)

      assert german.translation_status == "completed"
      assert french.translation_status == "completed"

      assert german.translated_markdown =~ "Translated de to en"
      assert french.translated_markdown =~ "Translated fr to en"

      # Neither run picked up the other's choice, and the French document was
      # not translated from the app-wide default ("de") either.
      refute german.translated_markdown =~ "Translated fr to en"
      refute french.translated_markdown =~ "Translated de to en"
    end

    test "a retry re-reads the document's own language and ignores a changed app default" do
      {document, page} = staged_page(%{source_language: "fr", target_language: "en"})

      assert :ok = LlmProcessor.process_page(page.id, MapSet.new())
      assert Documents.get_page!(page.id).translated_markdown =~ "Translated fr to en"

      # Move the app-wide default out from under the document. A retry that
      # consulted configuration instead of the row would now translate from
      # "it" -- the regression this guards.
      TestEnv.put_env(:defaults, source_language: "it", target_language: "en")

      # Stage the page the way a rescued or retried job finds it: extraction
      # done, translation to redo.
      {:ok, _page} =
        page.id
        |> Documents.get_page!()
        |> Documents.update_page_translation(%{
          translation_status: "error",
          translated_markdown: nil
        })

      assert :ok = LlmProcessor.process_page(page.id, MapSet.new())

      retried = Documents.get_page!(page.id)
      assert retried.translation_status == "completed"
      assert retried.translated_markdown =~ "Translated fr to en"
      refute retried.translated_markdown =~ "Translated it to en"

      # The document's own choice is what stayed stable across the two attempts.
      assert Documents.get_document!(document.id).source_language == "fr"
    end
  end

  # A one-page document staged for a full run: the extraction stage reads a real
  # file from the storage root, so one has to exist before `process_page/3`.
  defp staged_page(attrs) do
    document = document_fixture(Map.merge(%{status: "processing", total_pages: 1}, attrs))
    page = page_fixture(document)

    path = Path.join(Documents.uploads_dir(), page.image_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "test image")
    on_exit(fn -> File.rm(path) end)

    {document, page}
  end
end
