defmodule Doctrans.Processing.LlmProcessorRetryTest do
  # `async: false`: the retry telemetry and the `[:oban, :job, :stop]` event
  # this file listens to are VM-global, so a concurrent test's retries and job
  # completions would reach the handlers attached here.
  use Doctrans.DataCase, async: false
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Pages, Topics}
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.{LlmProcessor, OpenAIMock, OpenAIStub}
  alias Doctrans.Resilience.ErrorClassifier

  # The processor owns no retry loop: a stage calls the model once per run and
  # reports the failure for the job to schedule, so a page costs at most one
  # model call per Oban attempt.
  @max_attempts Ecto.Changeset.get_field(LlmProcessingJob.new(%{}), :max_attempts)

  setup do
    document = document_fixture(%{status: "processing", total_pages: 1})
    page = page_fixture(document)

    path = Path.join(Documents.uploads_dir(), page.image_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "test image")
    on_exit(fn -> File.rm(path) end)

    observe_model_calls()
    attach_retry_telemetry()
    Topics.subscribe_document(document.id)

    %{document: document, page: page}
  end

  describe "extraction failures" do
    test "a transient failure is reported for the job to retry after one model call", context do
      fail_extraction(:timeout)

      assert {:error, {:page_extraction_failed, bindings}} =
               LlmProcessor.process_page(context.page.id, MapSet.new())

      assert bindings[:page_number] == context.page.page_number
      assert bindings[:reason] == :timeout
      # The run asks for a retry because the classifier called the failure
      # transient, not because it ignores the classification.
      assert ErrorClassifier.classify(bindings[:reason]) == :retryable

      # One call, then the run settles: the wait before the next one is Oban's
      # backoff, not a sleep that holds the queue's slot.
      assert_calls(extract_markdown: 1)
      refute_received {:retry_event, _, _}

      # Nothing is half-written: no markdown, no translation attempt, no indexing.
      saved = Documents.get_page!(context.page.id)
      assert saved.extraction_status == "error"
      assert saved.original_markdown == nil
      assert saved.translation_status == "pending"
      assert saved.embedding_status == "pending"

      assert_received {:page_updated, %{id: page_id, extraction_status: "error"}}
      assert page_id == context.page.id

      assert Documents.get_document!(context.document.id).status != "completed"
    end

    test "the next attempt resumes the errored stage and completes the page", context do
      fail_extraction(:timeout)
      assert {:error, _} = LlmProcessor.process_page(context.page.id, MapSet.new())
      recover(:extract_markdown)

      assert :ok = LlmProcessor.process_page(context.page.id, MapSet.new())

      # The attempt that ran after the failure is the one whose markdown lands
      # on the page.
      saved = Documents.get_page!(context.page.id)
      assert saved.extraction_status == "completed"
      assert saved.original_markdown =~ "Extracted Test Content"
      assert saved.translation_status == "completed"
      assert saved.translated_markdown =~ saved.original_markdown

      # Indexing is queued off the successful extraction, and Oban runs the job
      # inline in tests, so a queued page is an indexed one.
      assert saved.embedding_status == "completed"

      assert Documents.get_document!(context.document.id).status == "completed"
    end

    test "a permanent failure is cancelled rather than retried", context do
      reason = "HTTP 404: Model not found"
      assert ErrorClassifier.classify(reason) == :permanent
      fail_extraction(reason)

      assert {:cancel, {:page_extraction_failed, bindings}} =
               LlmProcessor.process_page(context.page.id, MapSet.new())

      assert bindings[:page_number] == context.page.page_number
      assert bindings[:reason] == reason
      assert_calls(extract_markdown: 1)

      saved = Documents.get_page!(context.page.id)
      assert saved.extraction_status == "error"
      assert saved.original_markdown == nil
    end

    test "an unrecognised failure is retried rather than given up on", context do
      reason = {:error, :something_new}
      assert ErrorClassifier.classify(reason) == :unknown
      fail_extraction(reason)

      assert {:error, {:page_extraction_failed, bindings}} =
               LlmProcessor.process_page(context.page.id, MapSet.new())

      assert bindings[:reason] == reason
      assert Documents.get_page!(context.page.id).extraction_status == "error"
    end

    test "an open circuit breaker is left to the job's backoff", context do
      fail_extraction(:circuit_open)

      # The breaker closes on its own; the backoff before the next attempt is
      # the wait for it, which is why this is a retry and not a cancel.
      assert {:error, {:page_extraction_failed, bindings}} =
               LlmProcessor.process_page(context.page.id, MapSet.new())

      assert bindings[:reason] == :circuit_open
      assert_calls(extract_markdown: 1)
    end
  end

  describe "translation failures" do
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

    test "a transient failure is reported for the job to retry after one model call", context do
      fail_translation(:timeout)

      assert {:error, {:page_translation_failed, bindings}} =
               LlmProcessor.process_page(context.page.id, MapSet.new())

      assert bindings[:page_number] == context.page.page_number
      assert bindings[:reason] == :timeout
      assert_calls(translate: 1)
      refute_received {:retry_event, _, _}

      # The extraction the translation was built on survives the failure.
      saved = Documents.get_page!(context.page.id)
      assert saved.translation_status == "error"
      assert saved.translated_markdown == nil
      assert saved.extraction_status == "completed"
      assert saved.original_markdown == "Source text"

      assert_received {:page_updated, %{id: page_id, translation_status: "error"}}
      assert page_id == context.page.id

      assert Documents.get_document!(context.document.id).status != "completed"
    end

    test "the next attempt resumes at translation without paying for the image again",
         context do
      fail_translation(:timeout)
      assert {:error, _} = LlmProcessor.process_page(context.page.id, MapSet.new())
      recover(:translate)

      assert :ok = LlmProcessor.process_page(context.page.id, MapSet.new())

      # The retry repeats the same request: the source text and the document's
      # target language both survive into the attempt that succeeds.
      saved = Documents.get_page!(context.page.id)
      assert saved.translation_status == "completed"
      assert saved.translated_markdown =~ "Source text"
      assert saved.translated_markdown =~ context.document.target_language

      assert_calls(translate: 2)
      refute_received {:model_call, :extract_markdown}

      assert Documents.get_document!(context.document.id).status == "completed"
    end

    test "a permanent failure is cancelled rather than retried", context do
      reason = "HTTP 400: Invalid request"
      assert ErrorClassifier.classify(reason) == :permanent
      fail_translation(reason)

      assert {:cancel, {:page_translation_failed, bindings}} =
               LlmProcessor.process_page(context.page.id, MapSet.new())

      assert bindings[:reason] == reason
      assert_calls(translate: 1)

      saved = Documents.get_page!(context.page.id)
      assert saved.translation_status == "error"
      assert saved.original_markdown == "Source text"
    end
  end

  # The job is the layer that owns the schedule, so it is the job that reports
  # each retry and that decides when a failure is final for the document.
  describe "the job's retry schedule" do
    test "a transient failure before the last attempt is a retry", context do
      fail_extraction(:timeout)

      assert {:error, _} = perform_page_job(context.page, attempt: 1)

      assert_received {:retry_event, [:doctrans, :retry, :attempt],
                       %{type: :extraction, page_id: page_id, attempt: 1}}

      assert page_id == context.page.id
      refute_received {:retry_event, [:doctrans, :retry, :exhausted], _}

      # The document waits for the attempts still to come.
      assert Documents.get_document!(context.document.id).status == "processing"
    end

    test "a transient failure on the last attempt exhausts the retries and fails the document",
         context do
      fail_extraction(:timeout)

      assert {:error, _} = perform_page_job(context.page, attempt: @max_attempts)

      assert_received {:retry_event, [:doctrans, :retry, :exhausted],
                       %{type: :extraction, page_id: page_id}}

      assert page_id == context.page.id
      refute_received {:retry_event, [:doctrans, :retry, :attempt], _}

      assert Documents.get_document!(context.document.id).status == "error"
    end

    test "a translation failure is reported under its own stage", context do
      {:ok, page} =
        Documents.update_page_extraction(context.page, %{
          extraction_status: "completed",
          original_markdown: "Source text"
        })

      fail_translation(:timeout)

      assert {:error, _} = perform_page_job(page, attempt: @max_attempts)

      assert_received {:retry_event, [:doctrans, :retry, :exhausted], %{type: :translation}}
    end

    test "a permanent failure cancels the job and fails the document at once", context do
      fail_extraction("HTTP 404: Model not found")

      assert {:cancel, _} = perform_page_job(context.page, attempt: 1)

      # A cancel is not a retry, so neither series counts it.
      refute_received {:retry_event, _, _}

      assert Documents.get_document!(context.document.id).status == "error"
    end
  end

  describe "runs interrupted mid-flight" do
    test "a page reset between attempts is left to the generation that replaced it", context do
      fail_extraction(:timeout)
      stale_generation = context.page.processing_generation

      assert {:error, _} =
               LlmProcessor.process_page(context.page.id, MapSet.new(),
                 generation: stale_generation
               )

      {:ok, reset} = Pages.reset_page_for_reprocessing(Documents.get_page!(context.page.id))
      recover(:extract_markdown)

      # The replayed attempt belongs to the generation the reset superseded, and
      # the job reports success rather than running: Oban must not retry work a
      # newer generation owns.
      assert :ok =
               LlmProcessor.process_page(context.page.id, MapSet.new(),
                 generation: stale_generation
               )

      assert_calls(extract_markdown: 1)

      saved = Documents.get_page!(context.page.id)
      assert saved.processing_generation == reset.processing_generation
      assert saved.extraction_status == "pending"
      assert saved.original_markdown == nil
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

  # The stub answers every call the same way, so the result alone cannot tell
  # one model call from three. Each extraction and translation call is reported
  # to the test as `{:model_call, function}` before it is answered, whether the
  # answer is the default stub's or a stubbed failure.
  defp observe_model_calls do
    stub_extraction(&OpenAIStub.extract_markdown/2)
    stub_translation(&OpenAIStub.translate/4)
  end

  defp fail_extraction(reason), do: stub_extraction(fn _image, _opts -> {:error, reason} end)

  defp fail_translation(reason),
    do: stub_translation(fn _markdown, _source, _target, _opts -> {:error, reason} end)

  # Clears a stubbed failure so the next call sees a healthy model.
  defp recover(:extract_markdown), do: stub_extraction(&OpenAIStub.extract_markdown/2)
  defp recover(:translate), do: stub_translation(&OpenAIStub.translate/4)

  defp stub_extraction(implementation) do
    owner = self()

    Mox.stub(OpenAIMock, :extract_markdown, fn image_path, opts ->
      send(owner, {:model_call, :extract_markdown})
      implementation.(image_path, opts)
    end)
  end

  defp stub_translation(implementation) do
    owner = self()

    Mox.stub(OpenAIMock, :translate, fn markdown, source, target, opts ->
      send(owner, {:model_call, :translate})
      implementation.(markdown, source, target, opts)
    end)
  end

  defp perform_page_job(page, opts) do
    args = LlmProcessingJob.page_args(page, page.processing_generation, %{})
    perform_job(LlmProcessingJob, args, opts)
  end

  defp delete_document_after_indexing(document) do
    handler = "llm-processor-delete-#{inspect(self())}"

    :ok =
      :telemetry.attach(
        handler,
        [:oban, :job, :stop],
        fn _event, _measurements, _metadata, _config ->
          :telemetry.detach(handler)
          {:ok, _} = Documents.delete_document(document)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Asserts exactly `count` calls of `function` reached the model.
  defp assert_calls([{function, count}]) do
    for _ <- 1..count, do: assert_received({:model_call, ^function})
    refute_received {:model_call, ^function}
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
