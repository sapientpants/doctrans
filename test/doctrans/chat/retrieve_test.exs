defmodule Doctrans.Chat.RetrieveTest do
  use Doctrans.DataCase, async: false

  alias Doctrans.Chat
  alias Doctrans.Chat.Agent
  alias Doctrans.Chat.RetrievalProbe
  alias Doctrans.Documents

  setup do
    original_embedding = Application.get_env(:doctrans, :embedding_module)
    original_openai = Application.get_env(:doctrans, :openai_module)
    Application.put_env(:doctrans, :embedding_module, RetrievalProbe)
    Application.put_env(:doctrans, :openai_module, RetrievalProbe)
    Application.put_env(:doctrans, :retrieval_probe_pid, self())

    on_exit(fn ->
      Application.put_env(:doctrans, :embedding_module, original_embedding)
      Application.put_env(:doctrans, :openai_module, original_openai)
      Application.delete_env(:doctrans, :retrieval_probe_pid)
    end)

    {:ok, document} =
      Documents.create_document(%{
        title: "Annual Report",
        original_filename: "report.pdf",
        target_language: "de"
      })

    Repo.insert!(%Documents.Page{
      document_id: document.id,
      page_number: 1,
      original_markdown: "Total assets EUR 120m.",
      extraction_status: "completed",
      embedding_status: "completed",
      embedding: Pgvector.new(List.duplicate(0.1, 1024))
    })

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

  test "embeds the grader's single refined query during agent retrieval", %{document: document} do
    assert {:ok, "Answer.", [_]} =
             Agent.run(document, "assess the balance sheet", [], [], fn _ -> :ok end)

    assert_receive {:embedded, "assess the balance sheet"}
    assert_receive {:embedded, "liquidity and cash reserves"}
    assert_receive {:embedded, "liquidity and cash reserves"}
    refute_receive {:embedded, _}
  end
end
