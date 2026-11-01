defmodule Doctrans.Processing.JobQuery do
  @moduledoc """
  The Oban job predicates of the processing pipeline, stated once.

  A document owns two shapes of job: extraction and cleanup jobs keyed on the
  document id, and LLM processing and indexing jobs keyed on a page id. Every
  module that asks "which jobs belong to this document or page, and are they
  still live?" builds its query here, so the state lists and the argument
  lookups cannot drift apart. They did once: the cancel path left `suspended`
  jobs standing while every other predicate counted them as active, so a
  suspended job blocked reprocessing and survived cancellation.

  ## States

  `active_states/0` are the states a job can still run from — Oban's own
  "incomplete" set. `waiting_states/0` are the active states other than
  `executing`: the jobs cancellation can still stop, since a job already
  executing is out of reach and runs to completion.

  ## Selectors

  The first argument of `document_jobs_query/2` and `page_jobs_query/2` is a
  *selector* for the id held in the job's args: one id, a list of ids, a query
  selecting ids as text (compared with `IN (subquery)`), or an
  `Ecto.Query.dynamic/2` expression, which is how a caller correlates the jobs
  with an enclosing query through `parent_as/1` inside an `exists/1`.

  ## Compile-time use

  Call this module from function bodies only. The job modules reach `Run` and
  `JobStates` at runtime and both reach this module, so a module attribute
  reading a list from here would close a compile-connected cycle. Guards and
  attributes that need a state list should restate what the query already
  guarantees instead.
  """

  import Ecto.Query

  alias Doctrans.Documents.Page
  alias Doctrans.Jobs.{DocumentExtractionJob, Keys}

  @active ~w(available scheduled executing retryable suspended)
  @waiting @active -- ~w(executing)

  # Read from `Keys` rather than written out: the argument key is one fact, and
  # a literal here would drift silently from the job that writes it.
  @document_id_arg "?->>'#{Keys.document_id()}'"
  @page_id_arg "?->>'#{Keys.page_id()}'"
  @revision_arg "?->>'#{Keys.revision()}'"

  @typedoc "Which ids a job must hold: one, several, a query of them, or a correlated expression."
  @type selector ::
          Ecto.UUID.t() | [Ecto.UUID.t()] | Ecto.Query.t() | Ecto.Query.dynamic_expr()

  @typedoc """
  `:worker` restricts to the given job module(s); `:states` replaces the default
  `active_states/0`; `:revision` also requires the `EmbeddingJob` revision
  argument to match the given text or correlated expression.
  """
  @type option ::
          {:worker, module() | [module()]}
          | {:states, [String.t()]}
          | {:revision, String.t() | Ecto.Query.dynamic_expr()}

  @doc "The states a job can still run from."
  @spec active_states() :: [String.t()]
  def active_states, do: @active

  @doc "The active states short of `executing`: jobs that can still be stopped."
  @spec waiting_states() :: [String.t()]
  def waiting_states, do: @waiting

  @doc "Jobs whose args hold a document id matched by `selector`."
  @spec document_jobs_query(selector(), [option()]) :: Ecto.Query.t()
  def document_jobs_query(selector, opts \\ []) do
    opts |> jobs() |> where(^matches(document_id_arg(), selector))
  end

  @doc "Jobs whose args hold a page id matched by `selector`."
  @spec page_jobs_query(selector(), [option()]) :: Ecto.Query.t()
  def page_jobs_query(selector, opts \\ []) do
    opts |> jobs() |> where(^matches(page_id_arg(), selector))
  end

  @doc """
  The active jobs working on a document: its extraction jobs, and the jobs of
  `page_workers` keyed on any of its pages.

  One query for both shapes, because the callers read the result as a single
  instant — whether anything is active, or what state each pipeline is in.
  """
  @spec document_work_query(Ecto.UUID.t(), [module()]) :: Ecto.Query.t()
  def document_work_query(document_id, page_workers) do
    page_ids = from p in Page, where: p.document_id == ^document_id, select: type(p.id, :string)

    extraction =
      dynamic(
        [j],
        j.worker == ^worker_name(DocumentExtractionJob) and
          ^matches(document_id_arg(), document_id)
      )

    pages =
      dynamic(
        [j],
        j.worker in ^worker_names(page_workers) and ^matches(page_id_arg(), page_ids)
      )

    [] |> jobs() |> where(^dynamic(^extraction or ^pages))
  end

  defp jobs(opts) do
    states = Keyword.get(opts, :states, @active)

    from(j in Oban.Job, where: j.state in ^states)
    |> with_option(opts, :worker, fn query, workers ->
      where(query, [j], j.worker in ^worker_names(workers))
    end)
    |> with_option(opts, :revision, fn query, revision ->
      where(query, ^matches(revision_arg(), revision))
    end)
  end

  defp with_option(query, opts, key, fun) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> fun.(query, value)
      :error -> query
    end
  end

  # Every argument is read as text: ids and revisions are cast to text where
  # they are selected, and a correlated expression must do the same.
  defp document_id_arg, do: dynamic([j], fragment(@document_id_arg, j.args))
  defp page_id_arg, do: dynamic([j], fragment(@page_id_arg, j.args))
  defp revision_arg, do: dynamic([j], fragment(@revision_arg, j.args))

  defp matches(arg, ids) when is_list(ids), do: dynamic(^arg in ^ids)
  defp matches(arg, %Ecto.Query{} = ids), do: dynamic(^arg in subquery(ids))
  defp matches(arg, %Ecto.Query.DynamicExpr{} = id), do: dynamic(^arg == ^id)
  defp matches(arg, id) when is_binary(id), do: dynamic(^arg == ^id)

  defp worker_names(workers), do: workers |> List.wrap() |> Enum.map(&worker_name/1)
  defp worker_name(module), do: Oban.Worker.to_string(module)
end
