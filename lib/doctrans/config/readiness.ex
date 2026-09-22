defmodule Doctrans.Config.Readiness do
  @moduledoc """
  Answers, before a user commits documents to the pipeline, whether the
  configured model servers can actually do the work.

  Every failure this reports is a *settings* failure: a model server that is not
  running, a model name that no server offers, an embedding model whose vectors
  are narrower than the column they have to fit. They are invisible until a
  document is halfway through processing, and by then the user has already
  waited. Asking the servers directly costs two HTTP calls and turns a silent
  failure hours later into a specific remediation now.

  It is a report, not a gate. Queued work survives a model server that is down —
  startup recovery, Oban retries and the circuit breakers all exist to resume it
  — so refusing an upload would throw away work the pipeline can recover, while a
  check that is merely wrong about a working server would lock the user out of
  their own application. The one thing this changes is what the user is told.

  Only the two models the upload pipeline runs are checked: extraction
  (`Doctrans.Config.OpenAI.vision_model/0`) and translation
  (`translation_model/0`). The chat model is not upload readiness — a document
  uploads, translates and indexes without anyone ever opening the chat panel.

  ## Credentials

  Nothing here may leak a credential, and the endpoint settings are exactly
  where credentials hide: an operator may write `http://user:secret@host`, or a
  gateway URL carrying its key in the query string. So this module never
  composes, parses or inspects a URL itself. Every destination it names comes
  out of `Doctrans.Config.Inference`, which redacts before it returns, and the
  API keys are never read at all.

  ## Bounds

  Each probe gets a five-second receive window: `list_models/0` carries its own,
  and the embedding probe is given the same explicitly, because
  `Doctrans.Config.Embedding.timeout/0` defaults to a minute — a fine budget for
  a background indexing job and a terrible one for a modal someone is sitting in
  front of.

  That window bounds one attempt, not the whole call. Both requests run under
  `Doctrans.Processing.RequestBounds` with the inherited deadline, so a server
  failing transiently is retried and a drip-feeding one can hold the check open
  for far longer than the window suggests. Nothing waits on it — the dialog
  stays usable and the upload is never gated — so what that costs is a
  "checking" line that lingers. Bounding the total would mean threading a
  deadline through `Doctrans.Processing.OpenAI.embed/2` and `list_models/0`,
  which no other caller has asked for.

  `check/0` is total for the `{:error, _}` results its collaborators are
  specified to return, and deliberately does not trap anything else. A genuine
  crash in an HTTP client is not a readiness finding, and the caller runs this
  in a supervised task precisely so it can tell the two apart.
  """

  alias Doctrans.Config.Embedding
  alias Doctrans.Config.Inference
  alias Doctrans.Config.OpenAI

  @typedoc """
  What the configured inference setup can and cannot do right now.

  `:problems` is empty exactly when `:ready?` is true; it is ordered
  deterministically — inference and model problems first, in role order, then
  the single embedding problem — so callers can render it without sorting and
  tests can pin it. `:local?` and `:destination` mirror
  `Doctrans.Config.Inference`: `:destination` is `""` when every path is local,
  and credential-free in every other case.
  """
  @type report :: %{
          ready?: boolean(),
          local?: boolean(),
          destination: String.t(),
          problems: [Doctrans.Errors.reason()]
        }

  # A short, cheap input: the probe exists to learn whether the server answers
  # and how wide its vectors are, and neither depends on what was embedded.
  @probe_text "readiness"

  # Matches the budget `Doctrans.Processing.OpenAI.list_models/0` gives itself,
  # for the same reason: someone is waiting in a modal.
  @probe_timeout 5_000

  @doc """
  Probes the configured model servers and reports what is wrong, if anything.

  Makes two network calls — a model listing and a one-word embedding — so this
  belongs off the process a user is waiting on.
  """
  @spec check() :: report()
  def check do
    endpoints = Inference.endpoints()
    chat = endpoint(endpoints, :chat)
    embedding = endpoint(endpoints, :embedding)
    models = list_models()

    problems = model_problems(models, chat) ++ embedding_problems(models, chat, embedding)

    %{
      ready?: problems == [],
      local?: Inference.local?(),
      destination: Inference.destination_label(),
      problems: problems
    }
  end

  defp endpoint(endpoints, path), do: Enum.find(endpoints, &(&1.path == path))

  # The host names the server a user would go and start; the redacted base URL
  # stands in when the host is unreadable, which is the case that most needs
  # pointing at a setting. This is `Inference`'s own fallback rule, applied to
  # the endpoint it already handed us rather than re-derived from a raw URL.
  defp destination(%{host: host, base_url: base_url}), do: host || base_url

  # A malformed success is indistinguishable from a failure for our purposes:
  # either way there is no list to check model names against.
  defp list_models do
    case openai_module().list_models() do
      {:ok, names} when is_list(names) -> {:ok, names}
      _other -> :error
    end
  end

  # With no list fetched there is nothing to say about model names, and saying
  # it anyway would blame the models for the server being down. The single
  # unreachable-server problem is the whole finding.
  defp model_problems(:error, chat),
    do: [{:inference_unavailable, [destination: destination(chat)]}]

  defp model_problems({:ok, names}, chat) do
    destination = destination(chat)

    [
      {:extraction_model_unavailable, OpenAI.vision_model()},
      {:translation_model_unavailable, OpenAI.translation_model()}
    ]
    |> Enum.reject(fn {_code, model} -> model in names end)
    # The two settings fall back to each other — `translation_model/0` to
    # `chat_model/0` to `vision_model/0` — so one misspelled name routinely
    # arrives under both roles. Reporting the same missing model twice reads as
    # two independent faults; the earlier role in this list speaks for it.
    |> Enum.uniq_by(fn {_code, model} -> model end)
    |> Enum.map(fn {code, model} -> {code, [model: model, destination: destination]} end)
  end

  # One embedding call establishes availability and dimensional compatibility at
  # once: `Doctrans.Processing.OpenAI.embed/2` truncates a wider Matryoshka
  # vector down to the stored width and rejects a narrower one, so a server that
  # answers with a usable vector has proved both.
  defp embedding_problems(models, chat, embedding) do
    case embedding_module().generate(@probe_text, timeout: @probe_timeout) do
      {:ok, nil} ->
        [unreachable_problem(models, chat, embedding)]

      {:ok, _vector} ->
        []

      {:error, {:embedding_too_short, bindings}} when is_list(bindings) ->
        [narrow_problem(bindings)]

      {:error, _reason} ->
        [unreachable_problem(models, chat, embedding)]
    end
  end

  # The widths come from the failure itself rather than from a constant here, so
  # the message cannot drift away from the truncation rule that produced it.
  defp narrow_problem(bindings) do
    {:embedding_dimensions_too_small,
     [
       model: Embedding.model(),
       expected: Keyword.get(bindings, :expected),
       actual: Keyword.get(bindings, :actual)
     ]}
  end

  # A failed probe says the embedding path does not work, not why. When the
  # embedding endpoint is the chat endpoint we already hold the list that would
  # name the cause, and "this server does not offer that model" is a fixable
  # instruction where "the server did not answer" is not.
  defp unreachable_problem({:ok, names}, chat, embedding) do
    model = Embedding.model()

    if chat.base_url == embedding.base_url and model not in names do
      {:embedding_model_unavailable, [model: model, destination: destination(embedding)]}
    else
      {:embedding_unavailable, [destination: destination(embedding)]}
    end
  end

  # A separately hosted embedding server does not appear in the chat server's
  # listing, so its absence there means nothing and the probe is the only
  # witness. Same when no listing was fetched at all.
  defp unreachable_problem(:error, _chat, embedding),
    do: {:embedding_unavailable, [destination: destination(embedding)]}

  defp openai_module,
    do: Application.get_env(:doctrans, :openai_module, Doctrans.Processing.OpenAI)

  defp embedding_module,
    do: Application.get_env(:doctrans, :embedding_module, Doctrans.Search.Embedding)
end
