defmodule Doctrans.Chat.AgentGatherTest do
  # Scripted grades and query-dependent vectors make each gathering step visible.
  use Doctrans.DataCase, async: false

  alias Doctrans.Chat.{Agent, ContractProbe}
  alias Doctrans.Documents
  alias Doctrans.Repo
  alias Doctrans.TestEnv

  setup do
    document = Doctrans.Fixtures.document_fixture(%{status: "completed", total_pages: 2})
    assets = indexed_page(document, 1, "Assets are 120 million euros.", 0.1)
    liabilities = indexed_page(document, 2, "Liabilities are 75 million euros.", -0.1)
    %{document: document, assets: assets, liabilities: liabilities}
  end

  for {verdict, retrieval_rounds} <- [{"no", 2}, {"yes", 1}] do
    @verdict verdict
    @retrieval_rounds retrieval_rounds

    test "gathers new context and makes #{@retrieval_rounds} refinements when the second grade is #{@verdict}",
         %{
           document: document,
           assets: assets,
           liabilities: liabilities
         } do
      probe =
        start_supervised!(
          {ContractProbe,
           %{
             owner: self(),
             embeddings: %{"assets" => assets.embedding, "liabilities" => liabilities.embedding},
             chat_responses: [
               {:ok, "Standalone: assets"},
               {:ok, "Sufficient: no\nQuery 1: liabilities"},
               {:ok, "Sufficient: #{@verdict}\nQuery 1: liabilities"}
             ]
           }}
        )

      TestEnv.put_env(:chat_contract_probe, probe)
      TestEnv.put_env(:openai_module, ContractProbe)
      TestEnv.put_env(:embedding_module, ContractProbe)

      assert {:ok, "Answer.", context} =
               Agent.run(document, "assess the balance sheet", [], [], fn _ -> :ok end)

      assert Enum.sort(Enum.map(context, & &1.page_id)) == Enum.sort([assets.id, liabilities.id])
      assert_received {:contract_embedding, "assets"}
      for _ <- 1..@retrieval_rounds, do: assert_received({:contract_embedding, "liabilities"})
      refute_received {:contract_embedding, _}

      assert_received {:contract_chat, _planner_messages, _}
      assert_received {:contract_chat, [%{content: initial_grade}], _}
      assert initial_grade =~ assets.original_markdown
      refute initial_grade =~ liabilities.original_markdown

      assert_received {:contract_chat, [%{content: refined_grade}], _}
      assert refined_grade =~ assets.original_markdown
      assert refined_grade =~ liabilities.original_markdown
      assert ContractProbe.remaining_responses(probe) == []

      assert_received {:contract_generation, [%{role: "system", content: prompt} | _], _}
      assert prompt =~ assets.original_markdown
      assert prompt =~ liabilities.original_markdown
    end
  end

  defp indexed_page(document, number, text, component) do
    Repo.insert!(%Documents.Page{
      document_id: document.id,
      page_number: number,
      original_markdown: text,
      extraction_status: "completed",
      embedding_status: "completed",
      embedding: Pgvector.new(List.duplicate(component, 1024))
    })
  end
end
