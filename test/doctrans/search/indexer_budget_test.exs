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
  alias Doctrans.Documents.Page
  alias Doctrans.Search.{EmbeddingMocks, Indexer}

  test "budget_from_now/0 is the configured budget counted from now" do
    before = System.monotonic_time(:millisecond)
    deadline = Indexer.budget_from_now()
    after_call = System.monotonic_time(:millisecond)

    assert deadline >= before + Embedding.job_timeout()
    assert deadline <= after_call + Embedding.job_timeout()
  end

  test "every call is clamped to the smaller of its own deadline and the budget left" do
    EmbeddingMocks.observe()
    page = extracted_page_fixture(multi_chunk_markdown())
    budget = 1_000

    assert :ok =
             Indexer.index_page(page.id, nil,
               deadline: System.monotonic_time(:millisecond) + budget
             )

    calls = EmbeddingMocks.calls()
    # Three chunks and the page-level vector.
    assert length(calls) == 4

    for {_text, opts} <- calls do
      deadline = Keyword.fetch!(opts, :deadline)
      assert deadline > 0
      assert deadline <= budget
      assert deadline <= Embedding.deadline()
    end
  end

  test "a call without a budget starts one now, as the job would" do
    EmbeddingMocks.observe()
    page = extracted_page_fixture("Unbudgeted text")

    assert :ok = Indexer.index_page(page.id)

    # No caller indexes a page unbounded: a test, a rebuild, or a job are all
    # held to the configured budget.
    for {_text, opts} <- EmbeddingMocks.calls() do
      deadline = Keyword.fetch!(opts, :deadline)
      assert deadline > 0
      assert deadline <= Embedding.job_timeout()
    end
  end

  test "a spent budget fails the page cleanly before the next call" do
    EmbeddingMocks.observe()
    page = extracted_page_fixture(multi_chunk_markdown())

    assert {:error, :inference_deadline_exceeded} = index_under_spent_budget(page)

    # Nothing was asked of the endpoint, and the page reads as failed rather
    # than stuck "processing": the reason is retryable, so Oban's schedule
    # decides when to come back.
    assert EmbeddingMocks.calls() == []
    failed = Repo.get!(Page, page.id)
    assert failed.embedding_status == "error"
    assert failed.embedding == nil
  end

  test "the retry under a fresh budget resumes a page the budget failed" do
    EmbeddingMocks.observe()
    page = extracted_page_fixture(multi_chunk_markdown())
    assert {:error, :inference_deadline_exceeded} = index_under_spent_budget(page)

    assert :ok = Indexer.index_page(page.id, nil, deadline: Indexer.budget_from_now())

    assert Repo.get!(Page, page.id).embedding_status == "completed"
    assert Enum.all?(page_chunks(page), &(&1.embedding_status == "completed"))
  end

  test "a page with nothing to embed completes under a spent budget" do
    EmbeddingMocks.observe()
    document = document_fixture()
    page = page_fixture(document, %{extraction_status: "completed", original_markdown: ""})

    assert :ok = index_under_spent_budget(page)

    assert Repo.get!(Page, page.id).embedding_status == "completed"
  end

  defp index_under_spent_budget(page),
    do: Indexer.index_page(page.id, nil, deadline: System.monotonic_time(:millisecond) - 1)
end
