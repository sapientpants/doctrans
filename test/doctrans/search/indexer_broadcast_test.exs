defmodule Doctrans.Search.IndexerBroadcastTest do
  @moduledoc """
  Covers the announcement of an indexing run's outcome.

  Until B03 no view read `embedding_status`, so the indexer wrote it silently and
  nothing was wrong with that. Now the document viewer renders an indexing row,
  and a run that finishes without saying so leaves that row asserting whatever it
  last computed -- "queued", most visibly, for a page that has since been indexed.
  These drive both terminal writes and pin the one write that stays silent.
  """
  use Doctrans.DataCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Documents.{Page, Topics}
  alias Doctrans.Search.{EmbeddingErrorStub, EmbeddingMock, Indexer}
  alias Doctrans.TestEnv

  @moduletag :postgres

  test "a completed run announces the page it indexed" do
    page = extracted_page("Indexed and announced")
    :ok = Topics.subscribe_document(page.document_id)

    assert :ok = Indexer.index_page(page.id)

    assert_received {:page_updated, %Page{id: id, embedding_status: "completed"}}
    assert id == page.id
  end

  test "a failed run announces the failure it recorded" do
    page = extracted_page("Failed and announced")
    TestEnv.put_env(:embedding_module, EmbeddingErrorStub)
    TestEnv.put_env(:embedding_error_reason, {:http_error, 400})
    :ok = Topics.subscribe_document(page.document_id)

    assert {:cancel, _reason} = Indexer.index_page(page.id)

    assert_received {:page_updated, %Page{id: id, embedding_status: "error"}}
    assert id == page.id
  end

  test "the run announces its outcome once, not its start" do
    page = extracted_page("Announced once")
    :ok = Topics.subscribe_document(page.document_id)

    assert :ok = Indexer.index_page(page.id)

    # A running job is already visible through its Oban row, so the
    # `"processing"` write has nothing to add and must not spend a broadcast.
    assert_received {:page_updated, %Page{embedding_status: "completed"}}
    refute_received {:page_updated, %Page{embedding_status: "processing"}}
    refute_received {:page_updated, _page}
  end

  test "a superseded run announces nothing, having written nothing" do
    page = extracted_page("Superseded before it finished")
    :ok = Topics.subscribe_document(page.document_id)

    # A re-extraction advances `content_revision` through the database trigger,
    # which is what every write in the run is fenced against. The job still
    # carries the revision it was queued for.
    Page
    |> where([p], p.id == ^page.id)
    |> Repo.update_all(set: [original_markdown: "Rewritten underneath the run"])

    assert {:cancel, {:obsolete_revision, _bindings}} =
             Indexer.index_page(page.id, page.content_revision)

    refute_received {:page_updated, _page}
  end

  defp extracted_page(text) do
    TestEnv.put_env(:embedding_module, EmbeddingMock)
    document = document_fixture()
    page_fixture(document, %{extraction_status: "completed", original_markdown: text})
  end
end
