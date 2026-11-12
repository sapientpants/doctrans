defmodule Doctrans.Search.IndexerBudgetTest do
  @moduledoc """
  Covers the page budget `Indexer.index_page/3` runs under.

  A page is embedded chunk by chunk, each chunk one call at the configured
  deadline, so the page as a whole had no bound of its own until this budget:
  every call is clamped against what is left of it, and once it is spent the
  page fails cleanly rather than making the next call.
  """
  use Doctrans.DataCase, async: true

  import Doctrans.Fixtures

  alias Doctrans.Config.Embedding
  alias Doctrans.Documents.{Chunk, Page}
  alias Doctrans.Search.{EmbeddingMocks, Indexer}

  @markers ~w(ALPHA BETA GAMMA)

  test "budget_from_now/0 is the configured budget counted from now" do
    before = System.monotonic_time(:millisecond)
    deadline = Indexer.budget_from_now()
    after_call = System.monotonic_time(:millisecond)

    assert deadline >= before + Embedding.job_timeout()
    assert deadline <= after_call + Embedding.job_timeout()
  end

  test "every call is clamped to the smaller of its own deadline and the budget left" do
    EmbeddingMocks.observe()
    page = extracted_page(multi_chunk_markdown())
    budget = 1_000

    assert :ok =
             Indexer.index_page(page.id, nil,
               deadline: System.monotonic_time(:millisecond) + budget
             )

    calls = embedding_calls()
    # Three chunks and the page-level vector.
    assert length(calls) == 4

    for {_text, opts} <- calls do
      deadline = Keyword.fetch!(opts, :deadline)
      assert deadline > 0
      assert deadline <= budget
      assert deadline <= Embedding.deadline()
    end
  end

  test "without a budget each call runs to its own deadline" do
    EmbeddingMocks.observe()
    page = extracted_page("Unbudgeted text")

    assert :ok = Indexer.index_page(page.id)

    for {_text, opts} <- embedding_calls(), do: refute(Keyword.has_key?(opts, :deadline))
  end

  test "a spent budget fails the page cleanly before the next call, and the retry resumes" do
    EmbeddingMocks.observe()
    page = extracted_page(multi_chunk_markdown())

    assert {:error, :inference_deadline_exceeded} =
             Indexer.index_page(page.id, nil, deadline: System.monotonic_time(:millisecond) - 1)

    # Nothing was asked of the endpoint, and the page reads as failed rather
    # than stuck "processing": the reason is retryable, so Oban's schedule
    # decides when to come back.
    assert embedding_calls() == []
    failed = Repo.get!(Page, page.id)
    assert failed.embedding_status == "error"
    assert failed.embedding == nil

    # The retry, under a fresh budget, picks the page up and completes it.
    assert :ok = Indexer.index_page(page.id, nil, deadline: Indexer.budget_from_now())
    assert Repo.get!(Page, page.id).embedding_status == "completed"
    assert Enum.all?(chunks_of(page), &(&1.embedding_status == "completed"))
  end

  test "a page with nothing to embed completes under a spent budget" do
    EmbeddingMocks.observe()
    document = document_fixture()
    page = page_fixture(document, %{extraction_status: "completed", original_markdown: ""})

    assert :ok =
             Indexer.index_page(page.id, nil, deadline: System.monotonic_time(:millisecond) - 1)

    assert Repo.get!(Page, page.id).embedding_status == "completed"
  end

  defp extracted_page(text) do
    document = document_fixture()
    page_fixture(document, %{extraction_status: "completed", original_markdown: text})
  end

  # Three paragraphs of 200 words chunk into three chunks.
  defp multi_chunk_markdown do
    Enum.map_join(@markers, "\n\n", fn marker ->
      marker <> " " <> Enum.map_join(1..200, " ", &"word#{&1}")
    end)
  end

  defp chunks_of(page) do
    Chunk |> where([c], c.page_id == ^page.id) |> order_by([c], c.chunk_index) |> Repo.all()
  end

  defp embedding_calls, do: Enum.reverse(collect_embedding_calls([]))

  defp collect_embedding_calls(acc) do
    receive do
      {:embedding_call, text, opts} -> collect_embedding_calls([{text, opts} | acc])
    after
      0 -> acc
    end
  end
end
