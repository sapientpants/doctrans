defmodule Mix.Tasks.RechunkDocumentsTest do
  use Doctrans.DataCase, async: true
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures
  import ExUnit.CaptureIO

  alias Doctrans.Documents.{Chunk, Page}
  alias Doctrans.Jobs.EmbeddingJob
  alias Doctrans.Search.Indexer
  alias Mix.Tasks.RechunkDocuments

  test "queues every extracted page for a rebuild and calls no model itself" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      document = document_fixture()
      page = completed_page_fixture(document)
      assert :ok = Indexer.index_page(page.id)
      _unextracted = page_fixture(document, %{page_number: 2})

      # The task must not embed anything: every vector comes from the queued job.
      Mox.stub(Doctrans.Search.EmbeddingMock, :generate, fn _text, _opts ->
        flunk("the task called the embedding model")
      end)

      output = capture_io(fn -> RechunkDocuments.run([]) end)

      assert output =~ "Rebuilding page"
      assert output =~ "queued"
      assert Enum.any?(all_enqueued(worker: EmbeddingJob), &(&1.args["page_id"] == page.id))
      assert Repo.get!(Page, page.id).embedding_status == "pending"
      assert Chunk |> where([c], c.page_id == ^page.id) |> Repo.aggregate(:count) == 0
    end)
  end
end
