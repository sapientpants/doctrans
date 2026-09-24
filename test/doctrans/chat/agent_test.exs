defmodule Doctrans.Chat.AgentTest do
  # These cases configure the model and embedder for the whole test VM.
  use Doctrans.DataCase, async: false

  alias Doctrans.Chat
  alias Doctrans.Chat.{Agent, ContractProbe}
  alias Doctrans.Documents
  alias Doctrans.Processing.OpenAIProbe
  alias Doctrans.Repo
  alias Doctrans.TestEnv

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
      first_page = Documents.get_page_by_number(document.id, 1)
      second_vector = Pgvector.new(List.duplicate(-0.1, 1024))

      second_page =
        Repo.insert!(%Documents.Page{
          document_id: document.id,
          page_number: 2,
          original_markdown: "Liabilities are 75 million euros.",
          translated_markdown: "Verbindlichkeiten sind 75 Millionen Euro.",
          extraction_status: "completed",
          translation_status: "completed",
          embedding_status: "completed",
          embedding: second_vector
        })

      probe =
        model_probe(
          [
            {:ok, "Standalone: assets"},
            {:ok, "Sufficient: yes"},
            {:ok, "Standalone: liabilities"},
            {:ok, "Sufficient: yes"},
            {:ok, "Standalone: liabilities"},
            {:ok, "Sufficient: yes"}
          ],
          %{"assets" => first_page.embedding, "liabilities" => second_vector}
        )

      noop = fn _ -> :ok end

      assert {:ok, _first, context1} = Agent.run(document, "First question?", [], [], noop)
      assert Enum.map(context1, & &1.page_id) == [first_page.id]
      assert_received {:contract_generation, [%{role: "system", content: first_prompt} | _], _}
      assert first_prompt =~ first_page.translated_markdown
      refute first_prompt =~ second_page.translated_markdown

      # Opposite vectors make the second query retrieve only the second page.
      # The first passage can survive only through the prior-context path.
      assert {:ok, _second, context2} =
               Agent.run(document, "Second question?", [], [retrieved_context: context1], noop)

      expected_ids = Enum.sort([first_page.id, second_page.id])
      assert Enum.sort(Enum.map(context2, & &1.page_id)) == expected_ids
      assert_received {:contract_generation, [%{role: "system", content: second_prompt} | _], _}
      assert second_prompt =~ first_page.translated_markdown
      assert second_prompt =~ second_page.translated_markdown

      assert {:ok, _third, context3} =
               Agent.run(document, "Repeat question?", [], [retrieved_context: context2], noop)

      assert Enum.sort(Enum.map(context3, & &1.page_id)) == expected_ids
      assert ContractProbe.remaining_responses(probe) == []
    end

    test "returns error for an empty question" do
      assert {:error, :empty_question} =
               Agent.run(build_stub_document(), "", [], [], fn _ -> :ok end)

      assert {:error, :empty_question} =
               Agent.run(build_stub_document(), "   ", [], [], fn _ -> :ok end)
    end

    test "drops oversized prior context before returning context for the next turn", %{
      document: document
    } do
      page =
        Repo.insert!(%Documents.Page{
          document_id: document.id,
          page_number: 99,
          extraction_status: "completed",
          original_markdown: "Oversized retained passage " <> String.duplicate("x", 32_001)
        })

      oversized = %{
        page_id: page.id,
        page_number: page.page_number,
        content_revision: page.content_revision,
        chunk_index: nil,
        similarity: 1.0,
        original_markdown: page.original_markdown,
        translated_markdown: nil
      }

      # Establish that freshness filtering cannot satisfy the budget assertion.
      assert Chat.current_context([oversized]) == [oversized]
      model_probe([{:ok, "Standalone: current context"}, {:ok, "Sufficient: yes"}])

      assert {:ok, _answer, context} =
               Agent.run(
                 document,
                 "What is this about?",
                 [],
                 [retrieved_context: [oversized]],
                 fn _ ->
                   :ok
                 end
               )

      assert [_ | _] = context
      refute Enum.any?(context, &(&1.page_id == page.id))
      assert byte_size(Chat.build_context(context)) <= 32_000
      assert_received {:contract_generation, [%{role: "system", content: prompt} | _], _}
      refute prompt =~ "Oversized retained passage"
      assert prompt =~ "Testinhalt für Chat"
    end

    test "surfaces generation errors", %{document: document} do
      TestEnv.put_env(:openai_stub_chat_error, "boom")

      assert {:error, "boom"} =
               Agent.run(document, "What is this about?", [], [], fn _ -> :ok end)
    end

    test "generates the final answer with thinking enabled, planning steps without", %{
      document: document
    } do
      test_pid = self()
      original_module = Application.get_env(:doctrans, :openai_module)

      Application.put_env(:doctrans, :openai_module, OpenAIProbe)
      Application.put_env(:doctrans, :openai_probe_pid, test_pid)

      on_exit(fn ->
        Application.put_env(:doctrans, :openai_module, original_module)
        Application.delete_env(:doctrans, :openai_probe_pid)
      end)

      noop = fn _ -> :ok end

      assert {:ok, "probe stream", _context} =
               Agent.run(document, "What is this about?", [], [], noop)

      calls = collect_probe_calls()
      assert [{:chat, expander_opts}, {:chat, grader_opts}, {:chat_stream, stream_opts}] = calls

      assert Keyword.get(expander_opts, :think) == false
      assert Keyword.get(grader_opts, :think) == false
      assert Keyword.get(stream_opts, :think) == true
    end
  end

  defp model_probe(responses, embeddings \\ nil) do
    state = %{owner: self(), chat_responses: responses, embeddings: embeddings || %{}}
    probe = start_supervised!({ContractProbe, state})
    TestEnv.put_env(:chat_contract_probe, probe)
    TestEnv.put_env(:openai_module, ContractProbe)
    if embeddings, do: TestEnv.put_env(:embedding_module, ContractProbe)
    probe
  end

  # Drains {function, opts} messages queued by OpenAIProbe during Agent.run/5.
  defp collect_probe_calls(acc \\ []) do
    receive do
      {func, opts} when func in [:chat, :chat_stream] ->
        collect_probe_calls([{func, opts} | acc])
    after
      0 -> Enum.reverse(acc)
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
        source_language: "en",
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
