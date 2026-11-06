defmodule Doctrans.Documents.LifecycleTest do
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.{Document, Lifecycle, Topics}
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.Run

  @statuses ~w(uploading queued extracting processing completed error cancelled)
  @pre_processing ~w(uploading queued extracting)
  @in_flight @pre_processing ++ ~w(processing)
  @settled ~w(completed error cancelled)
  @progress_reportable ~w(queued extracting processing completed error)

  # Every from-list transition: its legal starting statuses, where it lands,
  # and what it answers from anywhere else. `begin_processing/1` and `settle/1`
  # answer with verdicts rather than refusals and have their own tables below.
  @transitions [
    {:begin_extraction, @in_flight ++ ~w(error), "extracting", :already_settled},
    {:fail, @in_flight ++ ~w(error), "error", :already_settled},
    {:cancel, @in_flight, "cancelled", :not_cancellable},
    {:resume, ~w(processing) ++ @settled, "processing", :already_processing},
    {:requeue, ~w(uploading) ++ @settled, "queued", :already_processing}
  ]

  defp run(:begin_extraction, document), do: Lifecycle.begin_extraction(document)
  defp run(:fail, document), do: Lifecycle.fail(document, :render_failed)
  defp run(:cancel, document), do: Lifecycle.cancel(document)
  defp run(:resume, document), do: Lifecycle.resume(document)
  defp run(:requeue, document), do: Lifecycle.requeue(document, Run.new_attrs())

  defp subscribed_document(status, attrs \\ %{}) do
    document = document_fixture(Map.merge(%{status: status, total_pages: 1}, attrs))
    :ok = Topics.subscribe_document(document.id)
    document
  end

  describe "the transition table" do
    for {transition, legal, to, refusal} <- @transitions do
      test "#{transition} moves #{Enum.join(legal, ", ")} to #{to}" do
        for status <- unquote(legal) do
          document = subscribed_document(status)
          id = document.id

          assert {:ok, %Document{id: ^id, status: unquote(to)}} =
                   run(unquote(transition), document)

          assert Repo.get!(Document, id).status == unquote(to)
          assert_received {:document_updated, %Document{id: ^id, status: unquote(to)}}
        end
      end

      test "#{transition} is refused from #{Enum.join(@statuses -- legal, ", ")} as #{refusal}" do
        for status <- unquote(@statuses -- legal) do
          document = subscribed_document(status)

          assert {:error, unquote(refusal)} = run(unquote(transition), document)
          assert Repo.get!(Document, document.id).status == status
          refute_received {:document_updated, _}
        end
      end
    end

    test "cancelled is terminal: no job-side transition leaves it" do
      document = subscribed_document("cancelled")
      page = page_fixture(document, %{extraction_status: "error"})

      assert {:error, :already_settled} = Lifecycle.begin_extraction(document)
      assert {:error, :already_settled} = Lifecycle.fail(document, :late_failure)
      assert :ok = Lifecycle.begin_processing(page)
      assert :ok = Lifecycle.begin_processing(document)
      assert :cancelled = Lifecycle.settle(page)
      assert :cancelled = Lifecycle.settle(document)
      assert :cancelled = Lifecycle.settle_unguarded(document.id)

      assert Repo.get!(Document, document.id).status == "cancelled"
      refute_received {:document_updated, _}
    end
  end

  describe "the diagnostic column" do
    test "fail/2 records the inspected reason and the next transition clears it" do
      document = document_fixture(%{status: "extracting"})
      reason = {:pdf_extraction_failed, [reason: :invalid_page_count]}

      assert {:ok, failed} = Lifecycle.fail(document, reason)
      assert failed.error_message == inspect(reason)

      assert {:ok, retried} = Lifecycle.begin_extraction(failed)
      assert retried.error_message == nil
    end

    test "fail/2 keeps a textual reason as it is, and may be repeated" do
      document = document_fixture(%{status: "processing"})

      assert {:ok, failed} = Lifecycle.fail(document, "Something went wrong")
      assert failed.error_message == "Something went wrong"

      assert {:ok, failed_again} = Lifecycle.fail(failed, :retry_failed_too)
      assert failed_again.error_message == ":retry_failed_too"
    end

    test "requeue/2 installs the new run and forgets the page count and diagnostic" do
      document = document_fixture(%{status: "error", total_pages: 3, error_message: "old"})
      attrs = Run.new_attrs(extraction_model: "vision-x", translation_model: "text-y")

      assert {:ok, queued} = Lifecycle.requeue(document, attrs)
      assert queued.processing_run_id == attrs.processing_run_id
      assert queued.extraction_model == "vision-x"
      assert queued.translation_model == "text-y"
      assert queued.total_pages == nil
      assert queued.error_message == nil
    end
  end

  describe "the run guard" do
    test "a document that has moved on to another run refuses every transition" do
      document = document_fixture(%{status: "error"})
      {:ok, _requeued} = Lifecycle.requeue(document, Run.new_attrs())

      # `document` still names the replaced run.
      assert {:error, :obsolete_run} = Lifecycle.begin_extraction(document)
      assert {:error, :obsolete_run} = Lifecycle.begin_processing(document)
      assert {:error, :obsolete_run} = Lifecycle.fail(document, :late)
      assert {:error, :obsolete_run} = Lifecycle.cancel(document)
      assert {:error, :obsolete_run} = Lifecycle.resume(document)
      assert {:error, :obsolete_run} = Lifecycle.requeue(document, Run.new_attrs())
      assert {:error, :obsolete_run} = Lifecycle.settle(document)
    end

    test "a page reset since its job was queued can neither restart nor settle the document" do
      document = document_fixture(%{status: "queued", total_pages: 1})
      stale = page_fixture(document)

      # A reset since the job was queued; the job still holds the old page.
      stale
      |> Ecto.Changeset.change(processing_generation: Uniq.UUID.uuid7())
      |> Repo.update!()

      assert {:error, :obsolete_run} = Lifecycle.begin_processing(stale)
      assert {:error, :obsolete_run} = Lifecycle.settle(stale)
      assert Documents.get_document!(document.id).status == "queued"
    end
  end

  describe "begin_processing/1" do
    test "moves a document out of its pre-processing states once, for a page" do
      for status <- @pre_processing do
        document = subscribed_document(status)
        page = page_fixture(document)
        id = document.id

        assert :ok = Lifecycle.begin_processing(page)
        assert Documents.get_document!(id).status == "processing"
        assert_received {:document_updated, %Document{id: ^id, status: "processing"}}

        # A second page starting does not announce a transition that already happened.
        assert :ok = Lifecycle.begin_processing(page)
        refute_received {:document_updated, _}
      end
    end

    test "moves a document out of its pre-processing states once, for the document" do
      for status <- @pre_processing do
        document = subscribed_document(status)
        id = document.id

        assert :ok = Lifecycle.begin_processing(document)
        assert Documents.get_document!(id).status == "processing"
        assert_received {:document_updated, %Document{id: ^id, status: "processing"}}

        assert :ok = Lifecycle.begin_processing(document)
        refute_received {:document_updated, _}
      end
    end

    test "leaves a processing or settled document where it is" do
      for status <- ~w(processing) ++ @settled do
        document = subscribed_document(status)
        page = page_fixture(document)

        assert :ok = Lifecycle.begin_processing(page)
        assert :ok = Lifecycle.begin_processing(document)
        assert Documents.get_document!(document.id).status == status
        refute_received {:document_updated, _}
      end
    end
  end

  describe "settle/1" do
    test "completes a document whose pages all succeeded, from any live status" do
      for status <- @in_flight ++ ~w(error) do
        diagnostic = if status == "error", do: %{error_message: "earlier"}, else: %{}
        document = subscribed_document(status, diagnostic)
        completed_page_fixture(document)
        id = document.id

        assert :completed = Lifecycle.settle(document)

        completed = Repo.get!(Document, id)
        assert completed.status == "completed"
        assert completed.error_message == nil
        assert_received {:document_updated, %Document{id: ^id, status: "completed"}}
      end
    end

    test "fails a document whose pages all settled with a failure, naming the pages" do
      for status <- @in_flight do
        document = subscribed_document(status, %{total_pages: 2})
        page_fixture(document, %{page_number: 1, extraction_status: "error"})
        completed_page_fixture(document, %{page_number: 2})
        id = document.id

        assert :failed = Lifecycle.settle(document)

        settled = Repo.get!(Document, id)
        assert settled.status == "error"
        assert settled.error_message == inspect({:pages_failed, [page_numbers: "1"]})
        assert Documents.failed_page_numbers(id) == [1]
        assert_received {:document_updated, %Document{id: ^id, status: "error"}}
      end
    end

    test "a document already failed keeps its diagnostic and is not announced again" do
      document = subscribed_document("error", %{error_message: "stopped"})
      page_fixture(document, %{extraction_status: "error"})

      assert :failed = Lifecycle.settle(document)
      assert Repo.get!(Document, document.id).error_message == "stopped"
      refute_received {:document_updated, _}
    end

    test "leaves a document with outstanding pages alone" do
      for status <- @in_flight ++ ~w(error) do
        document = subscribed_document(status, %{total_pages: 2})
        page_fixture(document, %{page_number: 1, extraction_status: "processing"})
        completed_page_fixture(document, %{page_number: 2})

        assert :incomplete = Lifecycle.settle(document)
        assert Repo.get!(Document, document.id).status == status
        refute_received {:document_updated, _}
      end
    end

    test "a terminal document answers its verdict without reading its pages" do
      for {status, verdict} <- [{"completed", :completed}, {"cancelled", :cancelled}] do
        document = subscribed_document(status)
        # The pages say failed; the row's verdict stands.
        page = page_fixture(document, %{extraction_status: "error"})

        assert ^verdict = Lifecycle.settle(document)
        assert ^verdict = Lifecycle.settle(page)
        assert Repo.get!(Document, document.id).status == status
        refute_received {:document_updated, _}
      end
    end

    test "a pending retry is not a terminal failure" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      failed = page_fixture(document, %{page_number: 1, extraction_status: "error"})
      completed_page_fixture(document, %{page_number: 2})

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, _job} =
          %{"page_id" => failed.id, "generation" => failed.processing_generation}
          |> LlmProcessingJob.new()
          |> Oban.insert()

        assert :retrying = Lifecycle.settle(document)
        assert :retrying = Lifecycle.settle_unguarded(document.id)
      end)

      assert Documents.get_document!(document.id).status == "processing"
    end

    # The job that hands its page in has finished with it, and Oban still lists
    # that job while `perform/1` runs: waiting on it would never settle a
    # document whose last attempt failed.
    test "the page handed in by its own job is not waited on" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      failed = page_fixture(document, %{page_number: 1, extraction_status: "error"})
      completed_page_fixture(document, %{page_number: 2})

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, _job} =
          %{"page_id" => failed.id, "generation" => failed.processing_generation}
          |> LlmProcessingJob.new()
          |> Oban.insert()

        assert :retrying = Lifecycle.settle(document)
        assert :failed = Lifecycle.settle(failed)
      end)

      assert Documents.get_document!(document.id).status == "error"
    end

    test "a successful retry reconciles a failed document" do
      document = document_fixture(%{status: "processing", total_pages: 2})
      failed = page_fixture(document, %{page_number: 1, extraction_status: "error"})
      completed_page_fixture(document, %{page_number: 2})
      assert :failed = Lifecycle.settle_unguarded(document.id)

      {:ok, failed} =
        Documents.update_page_extraction(failed, %{
          extraction_status: "completed",
          original_markdown: "# Recovered"
        })

      {:ok, _} =
        Documents.update_page_translation(failed, %{
          translation_status: "completed",
          translated_markdown: "# Recovered translation"
        })

      assert :completed = Lifecycle.settle_unguarded(document.id)

      reconciled = Documents.get_document!(document.id)
      assert reconciled.status == "completed"
      assert reconciled.error_message == nil
    end

    test "settle_unguarded/1 reports a missing document as incomplete" do
      assert :incomplete = Lifecycle.settle_unguarded(Ecto.UUID.generate())
    end
  end

  describe "broadcasting" do
    test "a transition inside the caller's transaction is left for the caller to announce" do
      document = subscribed_document("processing")

      assert {:ok, {:ok, cancelled}} =
               Repo.transaction(fn -> Lifecycle.cancel(document) end)

      assert cancelled.status == "cancelled"
      refute_received {:document_updated, _}
    end
  end

  describe "predicates" do
    test "partition the statuses the way the transitions do" do
      for status <- @statuses do
        document = %Document{status: status}

        assert Lifecycle.pre_processing?(document) == status in @pre_processing
        assert Lifecycle.in_flight?(document) == status in @in_flight
        assert Lifecycle.cancellable?(document) == status in @in_flight
        assert Lifecycle.reprocessable?(document) == status in @settled
        assert Lifecycle.progress_reportable?(document) == status in @progress_reportable
        assert Lifecycle.requeueable?(document) == status in ["uploading" | @settled]
        assert Lifecycle.uploading?(document) == (status == "uploading")
        assert Lifecycle.completed?(document) == (status == "completed")
        assert Lifecycle.cancelled?(document) == (status == "cancelled")
        assert Lifecycle.failed?(document) == (status == "error")
      end
    end
  end
end
