defmodule Doctrans.FixturesTest do
  @moduledoc """
  The document fixture is every test's starting state, so what it produces is
  pinned here: a status reached through the lifecycle's own transitions, under
  a run, announcing nothing.
  """
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Documents.Topics

  test "reaches every status through the transitions, under a run" do
    for status <- ~w(queued extracting processing completed error cancelled) do
      document = document_fixture(%{status: status, total_pages: 2})

      assert document.status == status
      assert is_binary(document.processing_run_id)
      assert document.total_pages == 2
      assert document.error_message == nil
    end

    fresh = document_fixture()
    assert fresh.status == "uploading"
    assert fresh.processing_run_id == nil
  end

  test "a failed document carries the diagnostic it was given, and nothing else may" do
    failed = document_fixture(%{status: "error", error_message: "render failed"})
    assert failed.error_message == "render failed"

    assert_raise ArgumentError, fn ->
      document_fixture(%{status: "processing", error_message: "render failed"})
    end
  end

  test "the walk announces nothing beyond the document's creation" do
    :ok = Topics.subscribe_documents()

    document = document_fixture(%{status: "completed", total_pages: 1})
    id = document.id

    # The collection topic is shared with every other test's documents, so
    # only this document's messages count.
    assert_received {:document_created, %{id: ^id}}
    refute_received {:document_updated, %{id: ^id}}
  end

  test "a legacy document has a status past uploading and no run" do
    legacy = legacy_document_fixture(%{status: "processing", total_pages: 3})

    assert legacy.status == "processing"
    assert legacy.processing_run_id == nil
    assert legacy.total_pages == 3
  end
end
