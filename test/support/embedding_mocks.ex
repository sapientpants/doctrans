defmodule Doctrans.Search.EmbeddingMocks do
  @moduledoc """
  Stubs for `Doctrans.Search.EmbeddingMock` beyond the default success.

  Each function installs one complete `generate/2` stub for the running test, so
  the last one installed wins. Every stub answers `nil` and `""` with
  `{:ok, nil}` like `Doctrans.Search.EmbeddingStub` does, and reports to the
  test process where it says it does -- the pid is captured when the stub is
  installed, because Mox runs the stub in whichever process makes the call.
  """

  import Mox

  alias Doctrans.Search.{EmbeddingMock, EmbeddingStub}

  @doc """
  The default stub, reporting every call as `{:embedding_call, text, opts}`.

  A test asserts which inputs were sent, and with which options, instead of
  inferring that from the outcome: the stub answers every call the same way, so
  the result alone cannot tell one call from three, nor a bounded call from one
  that inherited the indexing timeout.
  """
  def observe do
    owner = self()

    stub(EmbeddingMock, :generate, fn text, opts ->
      send(owner, {:embedding_call, text, opts})
      EmbeddingStub.generate(text, opts)
    end)

    :ok
  end

  @doc """
  Restores the default success, for a test that fails embeddings and then recovers.
  """
  def succeed do
    stub_with(EmbeddingMock, EmbeddingStub)
    :ok
  end

  @doc """
  Fails every call that carries text with `reason`.
  """
  def fail(reason \\ :timeout) do
    stub(EmbeddingMock, :generate, fn
      text, opts when text in [nil, ""] -> EmbeddingStub.generate(text, opts)
      _text, _opts -> {:error, reason}
    end)

    :ok
  end

  @doc """
  Fails the inputs `plan` names and lets every other call succeed.

  `plan` is a list of `{matcher, reason}` pairs applied to the text in order,
  where a matcher is a substring, or a list of substrings that must all be
  present. Text that matches nothing succeeds, so a test can fail one chunk of
  a page and leave its neighbours alone -- which is what separates "this page
  failed" from "this chunk failed". A list matcher reaches the page-level call
  specifically: it is the only one that sees the whole page's text at once, and
  so the only one carrying every chunk's marker.

  With `observe: true`, every call is also reported as
  `{:embedding_call, text, opts}`.
  """
  def fail_matching(plan, opts \\ []) when is_list(plan) do
    owner = self()
    observe? = Keyword.get(opts, :observe, false)

    stub(EmbeddingMock, :generate, fn text, call_opts ->
      if observe?, do: send(owner, {:embedding_call, text, call_opts})

      case reason_for(text, plan) do
        :ok -> EmbeddingStub.generate(text, call_opts)
        reason -> {:error, reason}
      end
    end)

    :ok
  end

  @doc """
  Succeeds with a vector of the wrong width.

  The search statement compares the query vector against stored 1024-dimension
  embeddings, so a narrower one makes Postgres reject the comparison. That is
  how a test reaches the statement's failure branch without stubbing out the
  statement it is meant to be checking: the embedding call succeeds, and the
  real query fails for a real reason.
  """
  def wrong_dimension do
    stub(EmbeddingMock, :generate, fn
      text, opts when text in [nil, ""] -> EmbeddingStub.generate(text, opts)
      _text, _opts -> {:ok, Pgvector.new([0.1, 0.2, 0.3])}
    end)

    :ok
  end

  @doc """
  Succeeds with no vector.

  `{:ok, nil}` is a legal result, and it is the one success that cannot be
  ranked against: a NULL vector searches nothing. Retrieval has to treat it as
  a degraded mode rather than as a ranking that ran.
  """
  def nil_vector do
    stub(EmbeddingMock, :generate, fn _text, _opts -> {:ok, nil} end)
    :ok
  end

  @doc """
  Exits instead of returning.

  The exit reason carries the text it was called with, standing in for the
  stacktrace a real crash carries -- an embedding call's frames hold the query
  and its 1024-float vector. That is what lets a test prove the *returned*
  reason keeps none of it.
  """
  def exit_with_text do
    stub(EmbeddingMock, :generate, &exit_generate/2)
    :ok
  end

  # Never returning is the whole point, so the behaviour's success typing cannot
  # be met and dialyzer is right that it never will be.
  @dialyzer {:nowarn_function, exit_generate: 2}
  defp exit_generate(text, _opts) do
    exit({:embedding_crashed, text, List.duplicate(0.1, 1024)})
  end

  @doc """
  Parks every call for exactly `text` until this test releases it.

  Returns the barrier reference. Each held call sends
  `{:embedding_started, barrier, pid}` to the test and waits for
  `{:continue_embedding, barrier}` from it, then answers with `opts[:result]`
  or the default success. Only the selected input waits, so unrelated
  background embeddings keep succeeding at once.

  Holding is the difference between asserting on a search's in-flight state and
  racing it, and it holds a call that will fail just as well: a test observing
  a search that ends in an embedding failure needs the failure held open too.
  The caller is monitored, so an abandoned barrier -- an assertion that failed
  while the call was parked -- stops the held process instead of leaking it.
  """
  def hold(text, opts \\ []) when is_binary(text) do
    owner = self()
    barrier = make_ref()
    result = Keyword.get(opts, :result)

    stub(EmbeddingMock, :generate, fn
      ^text, call_opts ->
        await_release(owner, barrier)
        result || EmbeddingStub.generate(text, call_opts)

      other, call_opts ->
        EmbeddingStub.generate(other, call_opts)
    end)

    barrier
  end

  defp await_release(owner, barrier) do
    monitor = Process.monitor(owner)
    send(owner, {:embedding_started, barrier, self()})

    receive do
      {:continue_embedding, ^barrier} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        exit(:shutdown)
    end
  end

  defp reason_for(text, plan) when is_binary(text) do
    Enum.find_value(plan, :ok, fn {matcher, reason} -> matches?(text, matcher) && reason end)
  end

  defp reason_for(_text, _plan), do: :ok

  defp matches?(text, substrings) when is_list(substrings),
    do: Enum.all?(substrings, &String.contains?(text, &1))

  defp matches?(text, substring), do: String.contains?(text, substring)
end
