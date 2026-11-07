defmodule Doctrans.Chat.RetrievalLogTest do
  # Sync: `capture_info_log/1` raises the VM-wide `Logger` level for the
  # duration of a capture, which a concurrent test would see too. Only the
  # summary line is under test here; what retrieval returns is
  # `Doctrans.Chat.RetrievalTest`'s.
  use Doctrans.DataCase, async: false

  import ExUnit.CaptureLog

  alias Doctrans.Chat.Retrieval
  alias Doctrans.Documents
  alias Doctrans.Search.EmbeddingMocks

  import Doctrans.Fixtures, only: [indexed_page_fixture: 2]

  describe "the summary line" do
    test "counts every query as failed on an outage, not as a quiet empty result" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})
      EmbeddingMocks.fail(:circuit_open)

      log =
        capture_info_log(fn ->
          assert {:error, _outage} = Retrieval.retrieve(document.id, ["firstq", "secondq"])
        end)

      assert log =~ "2 queries, 0 succeeded, 2 failed, 0 results returned"
    end

    test "counts the queries that failed beside the ones that succeeded" do
      document = completed_document()
      indexed_page_fixture(document, %{page_number: 1})
      EmbeddingMocks.fail_matching([{"failingquery", :circuit_open}])

      log =
        capture_info_log(fn ->
          assert {:ok, [_passage]} =
                   Retrieval.retrieve(document.id, ["failingquery", "good query"])
        end)

      assert log =~ "2 queries, 1 succeeded, 1 failed, 1 results returned"
    end
  end

  # The suite runs at :warning, so the summary line is only readable with the
  # level raised for the duration of the capture. A per-process level cannot
  # raise it: it only narrows what the primary level already lets through.
  defp capture_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp completed_document do
    {:ok, document} =
      Documents.create_document(%{
        status: "completed",
        title: "Test Document",
        original_filename: "test.pdf",
        source_language: "en",
        target_language: "de"
      })

    document
  end
end
