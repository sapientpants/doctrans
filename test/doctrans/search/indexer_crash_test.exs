defmodule Doctrans.Search.IndexerCrashTest do
  @moduledoc """
  What an unexpected raise leaves behind.

  `Indexer` marks a page "processing" before it chunks or embeds anything, and
  every failure path below that write marks the page errored on the way back
  out. A raise had no such path: the page kept "processing" through all five of
  `EmbeddingJob`'s attempts, and `StartupRecovery`, which keys on the status,
  re-enqueued it on every boot thereafter.
  """
  use Doctrans.DataCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Documents.Page
  alias Doctrans.Search.Indexer
  alias Doctrans.TestEnv

  defmodule EmbeddingRaiseStub do
    def generate(_content, _opts), do: raise(ArgumentError, "embedding blew up")
  end

  test "a raise below the status write marks the page errored and still propagates" do
    TestEnv.put_env(:embedding_module, EmbeddingRaiseStub)
    page = extracted_page("A page whose embedding call raises partway through")

    assert_raise ArgumentError, fn -> Indexer.index_page(page.id) end

    # Re-raised, so Oban keeps the retry decision -- but the status may not be
    # left claiming the page is still being worked on.
    assert Repo.get!(Page, page.id).embedding_status == "error"
  end

  defp extracted_page(text) do
    document = document_fixture()
    page_fixture(document, %{extraction_status: "completed", original_markdown: text})
  end
end
