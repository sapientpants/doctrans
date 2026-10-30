defmodule Doctrans.Processing.CompletionTest do
  use Doctrans.DataCase

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Documents.Topics
  alias Doctrans.Jobs.LlmProcessingJob
  alias Doctrans.Processing.Completion

  describe "check_document_completion/1" do
    setup do
      document = document_fixture(%{status: "processing", total_pages: 2})
      failed = page_fixture(document, %{page_number: 1, extraction_status: "error"})

      %{document: document, failed: failed}
    end

    test "a failed page never completes the document", %{document: document, failed: failed} do
      completed_page_fixture(document, %{page_number: 2})

      assert Completion.check_document_completion(document.id) == :failed

      settled = Documents.get_document!(document.id)
      assert settled.status == "error"
      assert settled.error_message == inspect({:pages_failed, [page_numbers: "1"]})
      assert Documents.failed_page_numbers(document.id) == [failed.page_number]
    end

    test "a pending retry is not a terminal failure", %{document: document, failed: failed} do
      completed_page_fixture(document, %{page_number: 2})

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, _job} =
          %{"page_id" => failed.id, "generation" => failed.processing_generation}
          |> LlmProcessingJob.new()
          |> Oban.insert()

        assert Completion.check_document_completion(document.id) == :retrying
      end)

      assert Documents.get_document!(document.id).status == "processing"
    end

    test "a successful retry reconciles a failed document", %{
      document: document,
      failed: failed
    } do
      completed_page_fixture(document, %{page_number: 2})
      assert Completion.check_document_completion(document.id) == :failed

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

      assert Completion.check_document_completion(document.id) == :completed

      reconciled = Documents.get_document!(document.id)
      assert reconciled.status == "completed"
      assert reconciled.error_message == nil
    end

    test "unfinished pages leave the document alone", %{document: document} do
      page_fixture(document, %{page_number: 2, extraction_status: "processing"})

      assert Completion.check_document_completion(document.id) == :incomplete
      assert Documents.get_document!(document.id).status == "processing"
    end
  end

  describe "update_document_status_to_processing/1" do
    test "moves a document out of its pre-processing states once" do
      for status <- ~w(uploading extracting queued) do
        document = document_fixture(%{status: status})
        :ok = Topics.subscribe_document(document.id)

        assert :ok = Completion.update_document_status_to_processing(document.id)
        assert Documents.get_document!(document.id).status == "processing"
        assert_receive {:document_updated, %{id: id, status: "processing"}} when id == document.id

        # A second page starting does not announce a transition that already happened.
        assert :ok = Completion.update_document_status_to_processing(document.id)
        refute_receive {:document_updated, _}
      end
    end

    test "leaves settled and cancelled documents where they are" do
      for status <- ~w(completed error cancelled) do
        document = document_fixture(%{status: status})

        assert :ok = Completion.update_document_status_to_processing(document.id)
        assert Documents.get_document!(document.id).status == status
      end
    end

    test "a page from an earlier generation cannot restart the document" do
      document = document_fixture(%{status: "queued", total_pages: 1})
      stale = page_fixture(document)

      # A reset since the job was queued; the job still holds the old page.
      stale
      |> Ecto.Changeset.change(processing_generation: Uniq.UUID.uuid7())
      |> Repo.update!()

      assert {:error, :obsolete_run} = Completion.update_document_status_to_processing(stale)
      assert Documents.get_document!(document.id).status == "queued"
    end
  end
end
