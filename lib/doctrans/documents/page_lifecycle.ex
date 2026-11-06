defmodule Doctrans.Documents.PageLifecycle do
  @moduledoc """
  The page stage machine: every status a page's processing stages can hold,
  and the named transitions between them.

  Two of a page's three stages belong here -- extraction and translation; the
  index pipeline moves embedding. `Doctrans.Documents.Lifecycle` does for a
  document's status what this module does for those two: processing moves a
  stage only through a transition named here. The schema's general changeset
  does not cast a stage status, and `Doctrans.Processing.LlmProcessor` names a
  transition rather than a status string. The one write outside this module is
  `Doctrans.Documents.Pages.reset_page_for_reprocessing/1`, which returns a
  page's stages to `pending` for a new run.

  Every transition is fenced by `Doctrans.Documents.Revision.with_page/2`: the
  write lands only while the page still holds the content revision and
  processing generation the caller loaded, and answers `{:error, :obsolete_run}`
  otherwise, logging the refusal as a document transition does. Callers that
  already hold the document lock lose nothing by it, and callers that do not
  never have to take it. A transition announces `page_updated` once the write
  has committed -- right away, or, inside a caller's
  `Doctrans.Repo.safe_transaction/1`, when that transaction commits -- so no
  caller announces a stage change itself.

  ## Statuses

  | status       | meaning                                                |
  |--------------|--------------------------------------------------------|
  | `pending`    | the stage has not started, or was reset for a new run  |
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

  require Logger

  alias Doctrans.Documents.{Page, Revision, Topics}
  alias Doctrans.Repo

  @typedoc "A stage of a page's work."
  @type stage :: :extraction | :translation

  @typedoc """
  What completing a stage stores: the markdown the stage produced and the
  model that produced it.

  `:model` is stored as given, `nil` included, so a caller that completes a
  stage without naming a model clears the one an earlier attempt recorded.
  Leave the key out to keep it.
  """
  @type product :: %{required(:markdown) => String.t(), optional(:model) => String.t() | nil}

  @typedoc "The page fields a stage owns: its status, its markdown and its model."
  @type fields :: %{status: atom(), markdown: atom(), model: atom()}

  @typedoc "The reason a transition was refused."
  @type refusal :: :obsolete_run

  @stages [:extraction, :translation]

  @fields %{
    extraction: %{
      status: :extraction_status,
      markdown: :original_markdown,
      model: :extraction_model
    },
    translation: %{
      status: :translation_status,
      markdown: :translated_markdown,
      model: :translation_model
    }
  }

  @doc "The page fields the stage owns, so no caller spells a column name per stage."
  @spec fields(stage()) :: fields()
  def fields(stage) when stage in @stages, do: Map.fetch!(@fields, stage)

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
    transition(page, :begin, %{fields(stage).status => "processing"})
  end

  @doc """
  Marks the stage `completed` and stores its product in the same write.

  A product without `:markdown` matches no clause: a stage cannot be completed
  with nothing to show for it.
  """
  @spec complete(Page.t(), stage(), product()) :: {:ok, Page.t()} | {:error, refusal()}
  def complete(%Page{} = page, stage, %{markdown: markdown} = product)
      when stage in @stages and is_binary(markdown) do
    fields = fields(stage)

    changes =
      %{fields.status => "completed", fields.markdown => markdown}
      |> put_model(fields, product)

    transition(page, :complete, changes)
  end

  @doc "Marks the stage `error`, keeping whatever an earlier attempt produced."
  @spec fail(Page.t(), stage()) :: {:ok, Page.t()} | {:error, refusal()}
  def fail(%Page{} = page, stage) when stage in @stages do
    transition(page, :fail, %{fields(stage).status => "error"})
  end

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  # One shape for every transition: fence the write behind the revision and
  # generation the caller loaded, then announce the page once it is committed,
  # or say why nothing was written.
  defp transition(page, name, changes) do
    page
    |> Revision.with_page(fn current -> {:ok, write(current, changes)} end)
    |> publish(page, name)
  end

  # The changeset is built from a status this module names and fields it owns,
  # so the only way the update can fail is a lost connection, which raises
  # here as it would anywhere else.
  defp write(page, changes) do
    page
    |> Page.stage_changeset(changes)
    |> Repo.update!()
  end

  # Called after the fence's transaction returns; a caller's enclosing
  # transaction defers the announcement to that commit, so subscribers read
  # committed state. A refusal is logged and passed through unannounced.
  defp publish({:ok, page} = result, _page, _name) do
    Repo.after_commit(fn -> Topics.broadcast_page_updated(page) end)
    result
  end

  defp publish({:error, refusal} = result, page, name) do
    Logger.info("Refused #{name} for page #{page.id}: #{refusal}")
    result
  end

  defp status(page, stage), do: Map.fetch!(page, fields(stage).status)

  defp put_model(changes, fields, %{model: model}), do: Map.put(changes, fields.model, model)
  defp put_model(changes, _fields, _product), do: changes
end
