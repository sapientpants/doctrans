defmodule Doctrans.Documents.PageLifecycle do
  @moduledoc """
  The page stage machine: every status a page's processing stages can hold,
  and the named transitions between them.

  Two of a page's three stages belong here -- extraction and translation; the
  index pipeline moves embedding. `Doctrans.Documents.Lifecycle` does for a
  document's status what this module does for those two: nothing else writes
  them. The schema's general changeset does not cast a stage status, and every
  caller -- the processor, cancellation, recovery, reprocessing -- names a
  transition rather than a status string.

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
  | `release/1`  | pending     | every `processing` stage; the rest is kept    |
  | `resume/1`   | pending     | every stage not `completed`; the rest is kept |
  | `reset/2`    | pending     | every stage, a new generation, no content     |

  There is no legal-from table: a retried job may begin a stage from `pending`,
  `processing` or `error` alike, and a stage with nothing to do may complete
  without beginning. The guard that matters is obsolete work -- a page reset,
  replaced or deleted under the caller -- and the fence refuses that in every
  transition. `complete/3` requires the stage's product, so a stage cannot be
  completed without saying what it produced: `original_markdown` for
  extraction, `translated_markdown` for translation. An empty product is legal
  -- a page with nothing on it -- and is stored as `nil`, the column's empty
  value, as the schema casts an empty string.

  `release/1` is the rule for a stage nobody is working on any more: the job
  that held it `processing` is gone with the cancellation, so the stored value
  would show a spinner for work nobody is doing. Only those markers move; a
  stage that finished or failed keeps its verdict and everything it produced,
  so a cancelled document still offers to retry its failed pages. It takes a
  whole document, set-based.

  `resume/1` is the rule for a page whose owed work is queued again under its
  current generation, as recovery does after a restart: every stage that has
  not completed -- interrupted or failed -- goes back to `pending`, so the page
  reads as queued rather than as failed while its retry waits, and a completed
  stage keeps its product. It is to a page what `Lifecycle.resume/1` is to a
  document.

  `reset/2` starts the page over for a reprocess: a new processing generation,
  so work queued under the old one is obsolete; no content, no models, every
  stage `pending`; and the models the user asked for recorded as
  `requested_*`, where the next run reads them.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Doctrans.Documents.{Document, Page, Revision, Topics}
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

  @typedoc "The models a reprocess asks for; either may be absent."
  @type choices :: %{
          optional(:extraction_model) => String.t() | nil,
          optional(:translation_model) => String.t() | nil
        }

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

  # A processing stage goes back to pending; any other value is kept as it is.
  @released "CASE WHEN ? = 'processing' THEN 'pending' ELSE ? END"

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

  @doc """
  Returns every `processing` stage of the document's pages to `pending`,
  keeping everything else, in one statement under the document lock. Answers
  the pages it changed.
  """
  @spec release(Document.t()) :: {:ok, [Page.t()]} | {:error, refusal()}
  def release(%Document{} = document) do
    Revision.with_current(document, fn current ->
      {_count, pages} =
        from(p in Page,
          where: p.document_id == ^current.id,
          where: p.extraction_status == "processing" or p.translation_status == "processing",
          update: [
            set: [
              extraction_status: fragment(@released, p.extraction_status, p.extraction_status),
              translation_status: fragment(@released, p.translation_status, p.translation_status)
            ]
          ],
          select: p
        )
        |> Repo.update_all([])

      {:ok, pages}
    end)
    |> publish_all(document)
  end

  @doc """
  Returns every stage of the page that has not completed to `pending`, from
  the stages it holds once locked -- not the copy the caller read, which a job
  may have finished since.
  """
  @spec resume(Page.t()) :: {:ok, Page.t()} | {:error, refusal()}
  def resume(%Page{} = page) do
    transition(page, :resume, fn current ->
      %{
        extraction_status: resumed(current.extraction_status),
        translation_status: resumed(current.translation_status)
      }
    end)
  end

  @doc """
  Starts the page over under a new processing generation, recording the models
  `choices` ask for as the ones its next run should use.
  """
  @spec reset(Page.t(), choices()) :: {:ok, Page.t()} | {:error, refusal()}
  def reset(%Page{} = page, choices \\ %{}) do
    page
    |> Revision.with_page(fn current ->
      {:ok, current |> Page.reset_changeset(choices) |> Repo.update!()}
    end)
    |> publish(page, :reset)
  end

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  # One shape for every stage transition: fence the write behind the revision
  # and generation the caller loaded, then announce the page once it is
  # committed, or say why nothing was written. `changes` may be a map, or a
  # function of the locked row for a transition that depends on what the page
  # holds now.
  defp transition(page, name, changes) do
    page
    |> Revision.with_page(fn current ->
      changes = if is_function(changes, 1), do: changes.(current), else: changes
      {:ok, write(current, changes)}
    end)
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

  defp publish_all({:ok, pages} = result, _document) do
    Enum.each(pages, &publish({:ok, &1}, &1, :release))
    result
  end

  defp publish_all({:error, refusal} = result, document) do
    Logger.info("Refused release for document #{document.id}: #{refusal}")
    result
  end

  defp resumed("completed"), do: "completed"
  defp resumed(_status), do: "pending"

  defp status(page, stage), do: Map.fetch!(page, fields(stage).status)

  defp put_model(changes, fields, %{model: model}), do: Map.put(changes, fields.model, model)
  defp put_model(changes, _fields, _product), do: changes
end
