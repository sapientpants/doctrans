defmodule Doctrans.Chat.RetrieveTest do
  # The probe and the failing embedder are installed on the mocks per test; the
  # multi-query branch runs under `Doctrans.TaskSupervisor`, which carries
  # `$callers`, so nothing here is shared with other tests.
  use Doctrans.DataCase, async: true

  import ExUnit.CaptureLog

  alias Doctrans.Chat
  alias Doctrans.Chat.Agent
  alias Doctrans.Chat.RetrievalProbe
  alias Doctrans.Documents
  alias Doctrans.Search.EmbeddingMocks

  import Doctrans.Fixtures, only: [document_fixture: 1, indexed_page_fixture: 2]

  setup do
    RetrievalProbe.install()

    document = document_fixture(%{title: "Annual Report", original_filename: "report.pdf"})
    indexed_page_fixture(document, %{original_markdown: "Total assets EUR 120m."})

    %{document: document}
  end

  test "uses the original question when no query is supplied", %{document: document} do
    assert {:ok, [_]} = Chat.retrieve(document.id, "original question", [], limit: 1)
    assert_receive {:embedded, "original question"}
  end

  test "uses the supplied single query", %{document: document} do
    assert {:ok, [_]} =
             Chat.retrieve(document.id, "original question", ["refined query"], limit: 1)

    assert_receive {:embedded, "refined query"}
    refute_receive {:embedded, _}
  end

  test "fuses results for multiple supplied queries", %{document: document} do
    assert {:ok, [%{rrf_score: score}]} =
             Chat.retrieve(document.id, "original question", ["assets", "equity"], limit: 1)

    assert_receive {:embedded, "assets"}
    assert_receive {:embedded, "equity"}
    assert_in_delta score, 2 / 61, 1.0e-12
  end

  test "retrieved context carries the source page revision", %{document: document} do
    page = Documents.get_page_by_number(document.id, 1)

    assert {:ok, [result]} = Chat.retrieve(document.id, "original question", [], limit: 1)
    assert result.content_revision == page.content_revision
    assert Chat.current_context([result]) == [result]
  end

  test "reports an outage on the no-query branch", %{document: document} do
    fail_embeddings()

    assert {:error, {:retrieval_unavailable, [reason: :circuit_open]}} =
             Chat.retrieve(document.id, "original question", [], limit: 1)
  end

  test "reports an outage on the single-query branch", %{document: document} do
    # The branch that matters most: the planner and the embedder are the same
    # server, so a planner outage collapses the query list to one and lands
    # here. Untagged, this reads to the user as a generic error rather than as
    # retrieval being down.
    fail_embeddings()

    assert {:error, {:retrieval_unavailable, [reason: :circuit_open]}} =
             Chat.retrieve(document.id, "original question", ["refined query"], limit: 1)
  end

  test "reports an outage on the multi-query branch", %{document: document} do
    fail_embeddings()

    capture_log(fn ->
      assert {:error, {:retrieval_unavailable, [reason: :circuit_open]}} =
               Chat.retrieve(document.id, "original question", ["assets", "equity"], limit: 1)
    end)
  end

  test "reports an embedder that returns no vector as an outage on the single-query branch",
       %{document: document} do
    # `{:ok, nil}` is a legal embedding result and the one success nothing can
    # be ranked against. The multi-query branch already read it as an outage;
    # the single-query branch searched on it and reported "nothing matched"
    # for a search that never ran.
    EmbeddingMocks.nil_vector()

    assert {:error, {:retrieval_unavailable, [reason: :embedding_unavailable]}} =
             Chat.retrieve(document.id, "original question", ["refined query"], limit: 1)
  end

  test "leaves a searched-but-empty retrieval as no matches", %{document: document} do
    # Nothing failed, so nothing is an outage: an empty list keeps meaning that
    # the document was searched and held nothing relevant.
    assert {:ok, []} =
             Chat.retrieve(document.id, "original question", [], limit: 1, min_similarity: 2.0)
  end

  test "embeds the grader's single refined query during agent retrieval", %{document: document} do
    assert {:ok, "Answer.", [_]} =
             Agent.run(document, "assess the balance sheet", [], [], fn _ -> :ok end)

    assert_receive {:embedded, "assess the balance sheet"}
    assert_receive {:embedded, "liquidity and cash reserves"}
    assert_receive {:embedded, "liquidity and cash reserves"}
    refute_receive {:embedded, _}
  end

  # Replaces the probe's embedder with one that fails every query; the probe's
  # model stays in place.
  defp fail_embeddings, do: EmbeddingMocks.fail(:circuit_open)
end
