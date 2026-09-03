defmodule Doctrans.Chat.AgentGatherTest do
  # Exercises the bounded gather-until-sufficient loop. async: false because it
  # swaps the global :openai_module to drive the grader deterministically.
  use Doctrans.DataCase, async: false

  alias Doctrans.Chat.Agent
  alias Doctrans.Documents
  alias Doctrans.Repo

  # FakeOpenAI that always grades the context "insufficient" with a refined query,
  # forcing the refine loop to run to its bound; plans normally and streams a reply.
  defmodule FakeOpenAI do
    def chat(messages, _opts) do
      content = messages |> List.last() |> Map.get(:content, "")

      cond do
        String.contains?(content, "Sufficient:") ->
          {:ok, "Sufficient: no\nQuery 1: more detail"}

        String.contains?(content, "Standalone:") ->
          {:ok, "Standalone: #{content}\nQuery 1: a\nQuery 2: b"}

        true ->
          {:ok, "generic"}
      end
    end

    def chat_stream(_messages, on_delta, _opts) do
      on_delta.("Answer.")
      {:ok, "Answer."}
    end
  end

  setup do
    original = Application.get_env(:doctrans, :openai_module)
    Application.put_env(:doctrans, :openai_module, FakeOpenAI)
    on_exit(fn -> Application.put_env(:doctrans, :openai_module, original) end)
    %{document: create_document_with_embeddings()}
  end

  test "terminates (bounded) even when the grader always reports insufficient", %{
    document: document
  } do
    test_pid = self()
    on_event = fn event -> send(test_pid, {:event, event}) end

    assert {:ok, "Answer.", context} =
             Agent.run(document, "assess the balance sheet", [], [], on_event)

    # Single-page fixture → dedup keeps the accumulated context at one chunk
    # despite multiple retrieval rounds; the key assertion is that it terminates.
    assert [_ | _] = context

    stages = for {:event, {:stage, stage}} = _m <- drain(), do: stage
    assert :assessing in stages
    assert :generating in stages
  end

  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp create_document_with_embeddings do
    {:ok, document} =
      Documents.create_document(%{
        title: "Annual Report",
        original_filename: "report.pdf",
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
      original_markdown: "Total assets EUR 120m, equity EUR 45m.",
      translated_markdown: "Bilanzsumme 120 Mio EUR, Eigenkapital 45 Mio EUR.",
      extraction_status: "completed",
      translation_status: "completed",
      embedding_status: "completed",
      embedding: embedding
    })

    document
  end
end
