defmodule Doctrans.Processing.LlmProcessorRetryTest do
  use Doctrans.DataCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Page, Topics}
  alias Doctrans.Processing.LlmProcessor
  alias Doctrans.Resilience.ErrorClassifier
  alias Doctrans.TestEnv

  # `config/test.exs` pins the retry budget: a stage calls the model once and
  # then retries up to `max_attempts` times before settling.
  @max_attempts Application.compile_env!(:doctrans, [:retry, :max_attempts])

  setup do
    document = document_fixture(%{status: "processing", total_pages: 1})
    page = page_fixture(document)

    path = Path.join(Documents.uploads_dir(), page.image_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "test image")
    on_exit(fn -> File.rm(path) end)

    attach_retry_telemetry()
    Topics.subscribe_document(document.id)

    %{document: document, page: page}
  end

  describe "extraction retries" do
    test "a transient failure is retried and the next attempt completes the page", context do
      fail_extraction(:timeout)
      recover_after_attempt(:openai_stub_extraction_error)

      assert :ok = LlmProcessor.process_page(context.page.id, MapSet.new())

      # The stage recovers rather than merely stopping: the attempt that ran
      # after the failure is the one whose markdown lands on the page.
      saved = Documents.get_page!(context.page.id)
      assert saved.extraction_status == "completed"
      assert saved.original_markdown =~ "Extracted Test Content"
      assert saved.translation_status == "completed"
      assert saved.translated_markdown =~ saved.original_markdown

      # Indexing is queued off the successful extraction, and Oban runs the job
      # inline in tests, so a queued page is an indexed one.
      assert saved.embedding_status == "completed"

      assert_attempts(:extraction, 1)
      refute_received {:retry_event, [:doctrans, :retry, :exhausted], _}

      assert Documents.get_document!(context.document.id).status == "completed"
    end

    test "retries stop at the configured budget and the page is marked failed", context do
      fail_extraction(:timeout)

      assert {:error, {:page_extraction_failed, bindings}} =
               LlmProcessor.process_page(context.page.id, MapSet.new())

      assert bindings[:page_number] == context.page.page_number
      assert bindings[:reason] == :timeout
      # The stage retried because the classifier called the failure transient,
      # not because it ignores the classification.
      assert ErrorClassifier.classify(bindings[:reason]) == :retryable

      # Nothing is half-written: no markdown, no translation attempt, no indexing.
      saved = Documents.get_page!(context.page.id)
      assert saved.extraction_status == "error"
      assert saved.original_markdown == nil
      assert saved.translation_status == "pending"
      assert saved.embedding_status == "pending"

      # The budget is spent once and then the stage settles, which is what keeps
      # a dead model from holding the job open indefinitely.
      assert_attempts(:extraction, @max_attempts)
      assert_exhausted(:extraction, context.page.id)

      assert_received {:page_updated, %{id: page_id, extraction_status: "error"}}
      assert page_id == context.page.id

      assert Documents.get_document!(context.document.id).status != "completed"
    end

    test "an unrecognised failure is retried rather than settled on its first occurrence",
         context do
      reason = {:error, :something_new}
      assert ErrorClassifier.classify(reason) == :unknown

      fail_extraction(reason)

      assert {:error, {:page_extraction_failed, bindings}} =
               LlmProcessor.process_page(context.page.id, MapSet.new())

      assert bindings[:reason] == reason
      assert_attempts(:extraction, @max_attempts)
      assert_exhausted(:extraction, context.page.id)
      assert Documents.get_page!(context.page.id).extraction_status == "error"
    end
  end

  describe "translation retries" do
    setup context do
      # Translation only runs on an extracted page, and pre-completing the stage
      # keeps the model calls under test to the translation ones.
      {:ok, page} =
        Documents.update_page_extraction(context.page, %{
          extraction_status: "completed",
          original_markdown: "Source text"
        })

      %{page: page}
    end

    test "a transient failure is retried and the next attempt completes the page", context do
      fail_translation(:timeout)
      recover_after_attempt(:openai_stub_translation_error)

      assert :ok = LlmProcessor.process_page(context.page.id, MapSet.new())

      # The retry repeats the same request: the source text and the document's
      # target language both survive into the attempt that succeeds.
      saved = Documents.get_page!(context.page.id)
      assert saved.translation_status == "completed"
      assert saved.translated_markdown =~ "Source text"
      assert saved.translated_markdown =~ context.document.target_language

      assert_attempts(:translation, 1)
      refute_received {:retry_event, [:doctrans, :retry, :exhausted], _}

      assert Documents.get_document!(context.document.id).status == "completed"
    end

    test "retries stop at the configured budget and the page is marked failed", context do
      fail_translation(:timeout)

      assert {:error, {:page_translation_failed, bindings}} =
               LlmProcessor.process_page(context.page.id, MapSet.new())

      assert bindings[:page_number] == context.page.page_number
      assert bindings[:reason] == :timeout

      # The extraction the translation was built on survives the failure, so a
      # later run of the job resumes at the translation stage rather than paying
      # for the image again.
      saved = Documents.get_page!(context.page.id)
      assert saved.translation_status == "error"
      assert saved.translated_markdown == nil
      assert saved.extraction_status == "completed"
      assert saved.original_markdown == "Source text"

      assert_attempts(:translation, @max_attempts)
      assert_exhausted(:translation, context.page.id)

      assert_received {:page_updated, %{id: page_id, translation_status: "error"}}
      assert page_id == context.page.id

      assert Documents.get_document!(context.document.id).status != "completed"
    end
  end

  # A run only ever finds out that it has been superseded — or that its page is
  # gone — partway through, so both tests here need a foothold inside a run.
  describe "runs interrupted mid-flight" do
    test "a page reset between attempts ends the run without failing the page", context do
      fail_extraction(:timeout)
      supersede_page_after_attempt(context.page)

      # The write fences reject the stale run, and the job reports success
      # rather than crashing: Oban must not retry work a newer generation owns.
      assert :ok = LlmProcessor.process_page(context.page.id, MapSet.new())

      # The superseded run leaves the page to the generation that replaced it
      # instead of stamping it failed.
      saved = Documents.get_page!(context.page.id)
      assert saved.extraction_status != "error"
      assert saved.original_markdown == nil

      refute_received {:retry_event, [:doctrans, :retry, :exhausted], _}
      assert Documents.get_document!(context.document.id).status != "error"
    end

    test "a document deleted mid-run ends the run without failing the job", context do
      # Indexing is the last thing extraction does before the run re-reads the
      # page, so a deletion there lands in the window the rescue exists for.
      delete_document_after_indexing(context.document)

      assert :ok = LlmProcessor.process_page(context.page.id, MapSet.new())

      assert Documents.get_document(context.document.id) == nil
      assert Documents.get_page(context.page.id) == nil
    end
  end

  defp fail_extraction(reason), do: TestEnv.put_env(:openai_stub_extraction_error, reason)

  defp fail_translation(reason), do: TestEnv.put_env(:openai_stub_translation_error, reason)

  # Clears the stubbed failure the moment the first retry is recorded. The
  # telemetry call runs inside the failing stage, before it sleeps and calls the
  # model again, so the next attempt sees a healthy model — a deterministic
  # "fails once, then succeeds" without waiting on a clock.
  defp recover_after_attempt(key) do
    attach_once("llm-processor-recover", [:doctrans, :retry, :attempt], fn ->
      Application.delete_env(:doctrans, key)
    end)
  end

  # Bumps the page's content revision the moment the first retry is recorded,
  # which is what a reset or a reprocess does to a page a run is holding.
  defp supersede_page_after_attempt(page) do
    attach_once("llm-processor-supersede", [:doctrans, :retry, :attempt], fn ->
      {1, _} =
        from(p in Page, where: p.id == ^page.id)
        |> Repo.update_all(inc: [content_revision: 1])
    end)
  end

  defp delete_document_after_indexing(document) do
    attach_once("llm-processor-delete", [:oban, :job, :stop], fn ->
      {:ok, _} = Documents.delete_document(document)
    end)
  end

  # Runs `fun` on the first occurrence of `event` and then gets out of the way,
  # so the interruption happens exactly once at a known point in the run.
  defp attach_once(name, event, fun) do
    handler = "#{name}-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, _measurements, _metadata, _config ->
          :telemetry.detach(handler)
          fun.()
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp assert_attempts(type, count) do
    for attempt <- 1..count do
      assert_received {:retry_event, [:doctrans, :retry, :attempt],
                       %{type: ^type, attempt: ^attempt}}
    end

    refute_received {:retry_event, [:doctrans, :retry, :attempt], _}
  end

  defp assert_exhausted(type, page_id) do
    assert_received {:retry_event, [:doctrans, :retry, :exhausted],
                     %{type: ^type, page_id: ^page_id}}
  end

  defp attach_retry_telemetry do
    owner = self()
    handler = "llm-processor-retry-#{inspect(owner)}"
    events = [[:doctrans, :retry, :attempt], [:doctrans, :retry, :exhausted]]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _measurements, metadata, _config ->
          send(owner, {:retry_event, event, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
