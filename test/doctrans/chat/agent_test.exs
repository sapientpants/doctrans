defmodule Doctrans.Chat.AgentTest do
  use Doctrans.DataCase, async: true

  alias Doctrans.Chat.Agent
  alias Doctrans.Documents
  alias Doctrans.Repo

  describe "run/5" do
    setup do
      %{document: create_document_with_embeddings()}
    end

    test "emits pipeline stages in order, streams deltas, and returns context", %{
      document: document
    } do
      test_pid = self()
      on_event = fn event -> send(test_pid, {:event, event}) end

      assert {:ok, answer, context} = Agent.run(document, "What is this about?", [], [], on_event)
      assert is_binary(answer)
      assert answer != ""
      # The document was searched and the retrieved chunk(s) accumulated.
      assert [_ | _] = context

      events = collect_events()

      stages = for {:stage, stage} <- events, do: stage
      assert stages == [:understanding, :retrieving, :assessing, :generating]

      # The streamed deltas should reconstruct the final answer.
      deltas = for {:delta, text} <- events, do: text
      assert deltas != []
      assert IO.iodata_to_binary(deltas) == answer
    end

    test "accumulates and dedups the retrieved context across turns", %{document: document} do
      noop = fn _ -> :ok end

      assert {:ok, _first, context1} = Agent.run(document, "First question?", [], [], noop)
      assert length(context1) == 1

      # Seeding the next turn with the prior context and retrieving the same page
      # again must not duplicate it — dedup by chunk identity.
      assert {:ok, _second, context2} =
               Agent.run(document, "Second question?", [], [retrieved_context: context1], noop)

      assert length(context2) == 1
    end

    test "returns error for an empty question" do
      assert {:error, :empty_question} =
               Agent.run(build_stub_document(), "", [], [], fn _ -> :ok end)

      assert {:error, :empty_question} =
               Agent.run(build_stub_document(), "   ", [], [], fn _ -> :ok end)
    end

    test "surfaces generation errors", %{document: document} do
      Application.put_env(:doctrans, :ollama_stub_chat_error, "boom")
      on_exit(fn -> Application.delete_env(:doctrans, :ollama_stub_chat_error) end)

      assert {:error, "boom"} =
               Agent.run(document, "What is this about?", [], [], fn _ -> :ok end)
    end
  end

  # Drains {:event, _} messages queued during Agent.run/5.
  defp collect_events(acc \\ []) do
    receive do
      {:event, event} -> collect_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp build_stub_document, do: %Documents.Document{id: Ecto.UUID.generate(), title: "Stub"}

  defp create_document_with_embeddings do
    {:ok, document} =
      Documents.create_document(%{
        title: "Test Document",
        original_filename: "test.pdf",
        target_language: "de",
        status: "completed",
        total_pages: 1
      })

    embedding = List.duplicate(0.1, 1024) |> Pgvector.new()

    Repo.insert!(%Documents.Page{
      id: Ecto.UUID.generate(),
      document_id: document.id,
      page_number: 1,
      image_path: "documents/#{document.id}/pages/page_1.png",
      original_markdown: "Test content for chat",
      translated_markdown: "Testinhalt für Chat",
      extraction_status: "completed",
      translation_status: "completed",
      embedding_status: "completed",
      embedding: embedding
    })

    document
  end
end
