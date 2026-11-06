defmodule Doctrans.Documents.PageLifecycle do
  @moduledoc """
  The page stage machine: every status a page's stages can hold, and the named
  transitions between them.

  A page has stages of its own -- extraction and translation -- and each stage
  has a status. `Doctrans.Documents.Lifecycle` does for a document's status what
  this module does for a page's stages: nothing else writes them. The schema's
  general changeset does not cast a stage status, and every caller names a
  transition rather than a status string.

  Every transition is fenced by `Doctrans.Documents.Revision.with_page/2`: the
  write lands only while the page still holds the content revision and
  processing generation the caller loaded, and answers `{:error, :obsolete_run}`
  otherwise. Callers that already hold the document lock lose nothing by it, and
  callers that do not never have to take it. A transition announces
  `page_updated` once the write has committed -- right away, or, inside a
  caller's `Doctrans.Repo.safe_transaction/1`, when that transaction commits --
  so no caller announces a stage change itself.

  ## Statuses

  | status       | meaning                                                |
  |--------------|--------------------------------------------------------|
  | `pending`    | the stage has not started, or was released or reset    |
  | `processing` | a job is working on the stage                          |
  | `completed`  | the stage finished and its product is stored           |
  | `error`      | the stage's last attempt failed                        |

  ## Transitions

  | transition   | to          | writes                                        |
  |--------------|-------------|-----------------------------------------------|
  | `begin/2`    | processing  | the status                                    |
  | `complete/3` | completed   | the status and the stage's product            |
  | `fail/2`     | error       | the status                                    |

  There is no legal-from table: a retried job may begin a stage from `pending`,
  `processing` or `error` alike, and a stage with nothing to do may complete
  without beginning. The guard that matters is obsolete work -- a page reset,
  replaced or deleted under the caller -- and the fence refuses that in every
  transition. `complete/3` requires the stage's product, so a stage cannot be
  completed without saying what it produced: `original_markdown` for
  extraction, `translated_markdown` for translation. An empty product is legal
  -- a page with nothing on it -- and is stored as `nil`, the column's empty
  value, as the schema casts an empty string.
  """

  alias Doctrans.Documents.{Page, Revision, Topics}
  alias Doctrans.Repo

  @typedoc "A stage of a page's work."
  @type stage :: :extraction | :translation

  @typedoc """
  What completing a stage stores: the markdown the stage produced and,
  when given, the model that produced it.
  """
  @type product :: %{required(:markdown) => String.t(), optional(:model) => String.t() | nil}

  @typedoc "The reason a transition was refused."
  @type refusal :: :obsolete_run

  @stages [:extraction, :translation]

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  @doc "True once the stage has completed."
  @spec done?(Page.t(), stage()) :: boolean()
  def done?(page, stage) when stage in @stages, do: status(page, stage) == "completed"

  @doc """
  True while the stage still has work to do: it has not started, was left
  `processing` by an interrupted job, or failed.
  """
  @spec owed?(Page.t(), stage()) :: boolean()
  def owed?(page, stage) when stage in @stages, do: not done?(page, stage)

  # ---------------------------------------------------------------------------
  # Transitions
  # ---------------------------------------------------------------------------

  @doc "Marks the stage `processing`."
  @spec begin(Page.t(), stage()) :: {:ok, Page.t()} | {:error, refusal()}
  def begin(%Page{} = page, stage) when stage in @stages do
    transition(page, %{status_field(stage) => "processing"})
  end

  @doc """
  Marks the stage `completed` and stores its product in the same write.

  Raises `ArgumentError` when the product has no `:markdown`: a stage cannot be
  completed with nothing to show for it.
  """
  @spec complete(Page.t(), stage(), product()) :: {:ok, Page.t()} | {:error, refusal()}
  def complete(%Page{} = page, stage, product) when stage in @stages do
    changes =
      %{status_field(stage) => "completed", markdown_field(stage) => markdown!(stage, product)}
      |> put_model(stage, product)

    transition(page, changes)
  end

  @doc "Marks the stage `error`, keeping whatever an earlier attempt produced."
  @spec fail(Page.t(), stage()) :: {:ok, Page.t()} | {:error, refusal()}
  def fail(%Page{} = page, stage) when stage in @stages do
    transition(page, %{status_field(stage) => "error"})
  end

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  # One shape for every transition: fence the write behind the revision and
  # generation the caller loaded, then announce the page once it is committed.
  defp transition(page, changes) do
    page
    |> Revision.with_page(fn current ->
      {:ok, current |> Page.stage_changeset(changes) |> Repo.update!()}
    end)
    |> announce()
  end

  # Called after the fence's transaction returns; a caller's enclosing
  # transaction defers it to that commit, so subscribers read committed state.
  defp announce({:ok, page} = result) do
    Repo.after_commit(fn -> Topics.broadcast_page_updated(page) end)
    result
  end

  defp announce(refusal), do: refusal

  defp status(page, :extraction), do: page.extraction_status
  defp status(page, :translation), do: page.translation_status

  defp status_field(:extraction), do: :extraction_status
  defp status_field(:translation), do: :translation_status

  defp markdown_field(:extraction), do: :original_markdown
  defp markdown_field(:translation), do: :translated_markdown

  defp model_field(:extraction), do: :extraction_model
  defp model_field(:translation), do: :translation_model

  defp markdown!(_stage, %{markdown: markdown}) when is_binary(markdown), do: markdown

  defp markdown!(stage, product) do
    raise ArgumentError,
          "completing #{stage} needs the markdown it produced, got: #{inspect(product)}"
  end

  defp put_model(changes, stage, %{model: model}), do: Map.put(changes, model_field(stage), model)
  defp put_model(changes, _stage, _product), do: changes
end
