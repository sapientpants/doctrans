defmodule Doctrans.Chat.AgentTest do
  # Each test installs its own model and embedder on the mocks; chat's search
  # tasks run under `Doctrans.TaskSupervisor`, which carries `$callers`.
  use Doctrans.DataCase, async: true

  alias Doctrans.Chat.{Agent, ContractProbe, RetrievalProbe, RetrievedContext}
  alias Doctrans.Documents
  alias Doctrans.Processing.{OpenAIMock, OpenAIProbe}

  import Doctrans.Fixtures

  describe "run/5" do
    setup do
      %{document: completed_document_with_embedding_fixture()}
    end

    test "emits pipeline stages in order, streams deltas, and returns context", %{
      document: document
    } do
      test_pid = self()
      on_event = fn event -> send(test_pid, {:event, event}) end

      assert {:ok, answer, context} = Agent.run(document, "What is this about?", [], [], on_event)
      assert is_binary(answer)
      assert answer != ""
      # The document was searched and the retrieved passage(s) accumulated.
      assert [_ | _] = RetrievedContext.passages(context)

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

      second_page =
        indexed_page_fixture(document, %{
          page_number: 2,
          original_markdown: "Liabilities are 75 million euros.",
          translated_markdown: "Verbindlichkeiten sind 75 Millionen Euro.",
          embedding: fake_embedding(-0.1)
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
          %{"assets" => first_page.embedding, "liabilities" => second_page.embedding}
        )

      noop = fn _ -> :ok end

      assert {:ok, _first, context1} = Agent.run(document, "First question?", [], [], noop)
      assert Enum.map(RetrievedContext.passages(context1), & &1.page_id) == [first_page.id]
      assert_received {:contract_generation, [%{role: "system", content: first_prompt} | _], _}
      assert first_prompt =~ first_page.translated_markdown
      refute first_prompt =~ second_page.translated_markdown

      # Opposite vectors make the second query retrieve only the second page.
      # The first passage can survive only through the prior-context path.
      assert {:ok, _second, context2} =
               Agent.run(document, "Second question?", [], [retrieved_context: context1], noop)

      expected_ids = Enum.sort([first_page.id, second_page.id])

      assert context2 |> RetrievedContext.passages() |> Enum.map(& &1.page_id) |> Enum.sort() ==
               expected_ids

      assert_received {:contract_generation, [%{role: "system", content: second_prompt} | _], _}
      assert second_prompt =~ first_page.translated_markdown
      assert second_prompt =~ second_page.translated_markdown

      assert {:ok, _third, context3} =
               Agent.run(document, "Repeat question?", [], [retrieved_context: context2], noop)

      assert context3 |> RetrievedContext.passages() |> Enum.map(& &1.page_id) |> Enum.sort() ==
               expected_ids

      assert ContractProbe.remaining_responses(probe) == []
    end

    test "returns error for an empty question" do
      assert {:error, :empty_question} =
               Agent.run(build_stub_document(), "", [], [], fn _ -> :ok end)

      assert {:error, :empty_question} =
               Agent.run(build_stub_document(), "   ", [], [], fn _ -> :ok end)
    end

    test "surfaces generation errors", %{document: document} do
      # The planner and grader both fall back on a model error; only the
      # streamed generation surfaces it, so both calls fail here.
      Mox.stub(OpenAIMock, :chat, fn _messages, _opts -> {:error, "boom"} end)
      Mox.stub(OpenAIMock, :chat_stream, fn _messages, _on_delta, _opts -> {:error, "boom"} end)

      assert {:error, "boom"} =
               Agent.run(document, "What is this about?", [], [], fn _ -> :ok end)
    end

    test "generates the final answer with thinking enabled, planning steps without", %{
      document: document
    } do
      OpenAIProbe.install()

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

  describe "retrieval rounds" do
    test "embeds the planned queries and the grader's refined query" do
      document = document_fixture(%{title: "Annual Report", original_filename: "report.pdf"})
      indexed_page_fixture(document, %{original_markdown: "Total assets EUR 120m."})
      RetrievalProbe.install()

      assert {:ok, "Answer.", context} =
               Agent.run(document, "assess the balance sheet", [], [], fn _ -> :ok end)

      assert [_] = RetrievedContext.passages(context)

      assert_receive {:embedded, "assess the balance sheet"}
      assert_receive {:embedded, "liquidity and cash reserves"}
      assert_receive {:embedded, "liquidity and cash reserves"}
      refute_receive {:embedded, _}
    end
  end

  # Scripts the model's replies. With `embeddings`, the probe also answers each
  # query with its vector; without, the default embedding stub stays in place.
  defp model_probe(responses, embeddings) do
    state = %{owner: self(), chat_responses: responses, embeddings: embeddings || %{}}
    probe = start_supervised!({ContractProbe, state})
    ContractProbe.install(probe)
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
end
