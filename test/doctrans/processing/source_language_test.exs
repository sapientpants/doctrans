defmodule Doctrans.Processing.SourceLanguageTest do
  @moduledoc """
  Covers the per-document source language: where it comes from when the
  uploader did not pick one, and that translation reads it off the document
  being processed rather than off an app-wide default.

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
  import ExUnit.CaptureLog

  alias Doctrans.Documents
  alias Doctrans.Processing.LlmProcessor
  alias Doctrans.Processing.OpenAIProbe
  alias Doctrans.Processing.SourceLanguage
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

  describe "process_page/3 source language detection" do
    test "detects the language of a document that has none and translates from it" do
      TestEnv.put_env(:openai_stub_detected_language, "fr")

      {document, page} = staged_page(%{source_language: nil, target_language: "en"})

      assert :ok = LlmProcessor.process_page(page.id, MapSet.new())

      # The detected language is recorded on the document, so every later page
      # and every retry reads the same answer...
      assert Documents.get_document!(document.id).source_language == "fr"

      # ...and it is the language this page was actually translated from, not
      # merely a value parked on the row.
      assert Documents.get_page!(page.id).translated_markdown =~ "Translated fr to en"
    end

    test "a language the uploader picked is never replaced by a detected one" do
      TestEnv.put_env(:openai_stub_detected_language, "fr")

      {document, page} = staged_page(%{source_language: "nl", target_language: "en"})

      assert :ok = LlmProcessor.process_page(page.id, MapSet.new())

      assert Documents.get_document!(document.id).source_language == "nl"

      translated = Documents.get_page!(page.id).translated_markdown
      assert translated =~ "Translated nl to en"
      refute translated =~ "Translated fr to en"
    end

    test "a document is detected once, and its later pages reuse the recorded answer" do
      TestEnv.put_env(:openai_stub_detected_language, "fr")

      {document, [first, second]} =
        staged_pages(%{source_language: nil, target_language: "en"}, 2)

      assert :ok = LlmProcessor.process_page(first.id, MapSet.new())
      assert Documents.get_document!(document.id).source_language == "fr"
      assert Documents.get_page!(first.id).translated_markdown =~ "Translated fr to en"

      # Swap the recording client in for the second page. It reports every call
      # it receives, so a second detection would show up as a
      # `{:detect_language, _}` message ahead of the translation it precedes --
      # which is what makes "no second call" an assertion rather than a hope.
      TestEnv.put_env(:openai_probe_pid, self())
      TestEnv.put_env(:openai_module, OpenAIProbe)

      assert :ok = LlmProcessor.process_page(second.id, MapSet.new())

      assert_receive {:translate_languages, {"fr", "en"}}, 5_000
      refute_received {:detect_language, _opts}

      assert Documents.get_document!(document.id).source_language == "fr"
    end

    test "a reply that names no one language records the configured fallback" do
      # A distinctive fallback: "de" is both the stub's default reply and the
      # module's built-in last resort, so a test that passed on "de" would not
      # show that configuration was consulted at all.
      TestEnv.put_env(:defaults, source_language: "pl", target_language: "en")

      # "It is de" names two supported codes ("it" and "de") and identifies
      # neither; "xx" is not a language this app translates. Both are worth
      # less than the fallback, and neither may be taken at its word.
      for reply <- ["It is de", "xx"] do
        TestEnv.put_env(:openai_stub_detected_language, reply)

        {document, page} = staged_page(%{source_language: nil, target_language: "en"})

        assert :ok = LlmProcessor.process_page(page.id, MapSet.new())

        stored = Documents.get_document!(document.id).source_language

        assert stored == "pl",
               ~s(the reply #{inspect(reply)} recorded #{inspect(stored)}, not the fallback)

        assert Documents.get_page!(page.id).translated_markdown =~ "Translated pl to en"
      end
    end

    test "a failed detection records the fallback and the page is still translated" do
      TestEnv.put_env(:defaults, source_language: "pl", target_language: "en")
      TestEnv.put_env(:openai_stub_detection_error, :circuit_open)

      {document, page} = staged_page(%{source_language: nil, target_language: "en"})

      # The failure is logged, not raised: a document one cannot detect is
      # still a document the user gets back translated.
      log = capture_log(fn -> assert :ok = LlmProcessor.process_page(page.id, MapSet.new()) end)
      assert log =~ "Language detection failed"

      assert Documents.get_document!(document.id).source_language == "pl"

      translated = Documents.get_page!(page.id)
      assert translated.translation_status == "completed"
      assert translated.translated_markdown =~ "Translated pl to en"
    end
  end

  describe "resolve/2 with nothing to read" do
    test "a page with no text records nothing, leaving a later page to decide" do
      TestEnv.put_env(:defaults, source_language: "pl", target_language: "en")
      TestEnv.put_env(:openai_stub_detected_language, "fr")

      document = document_fixture(%{source_language: nil, target_language: "en"})

      # A page the extractor got only whitespace from. It is answered -- the
      # caller needs a language to hand the translator -- but nothing is
      # written, because nothing was read.
      assert SourceLanguage.resolve(document, "   \n\n  ") == "pl"
      assert Documents.get_document!(document.id).source_language == nil

      # So the next page, which does have text, is still the one that decides.
      # Were the blank page allowed to record the fallback, this would stay "pl"
      # and no page would ever look again.
      assert SourceLanguage.resolve(document, "Bonjour, ceci est un document.") == "fr"
      assert Documents.get_document!(document.id).source_language == "fr"
    end
  end

  # A one-page document staged for a full run: the extraction stage reads a real
  # file from the storage root, so one has to exist before `process_page/3`.
  defp staged_page(attrs) do
    {document, [page]} = staged_pages(attrs, 1)
    {document, page}
  end

  # The same staging for a document of several pages, for the tests that need
  # one page to find what another page left on the document row.
  defp staged_pages(attrs, count) do
    document = document_fixture(Map.merge(%{status: "processing", total_pages: count}, attrs))

    pages =
      for number <- 1..count do
        page =
          page_fixture(document, %{
            page_number: number,
            image_path: "documents/#{document.id}/pages/page_#{number}.png"
          })

        path = Path.join(Documents.uploads_dir(), page.image_path)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "test image")
        on_exit(fn -> File.rm(path) end)

        page
      end

    {document, pages}
  end
end
