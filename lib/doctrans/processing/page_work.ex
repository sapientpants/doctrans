defmodule Doctrans.Processing.PageWork do
  @moduledoc """
  One Page's content work, from the queue to the Settle of its Document.

  `queue/3` puts the work in the queue; `attempt/2` is one run of it.
  `Doctrans.Jobs.LlmProcessingJob` is the adapter between the two: it is the
  row `queue/3` inserts and the `perform/1` that calls `attempt/2`, and it
  decides nothing about the page itself.

  ## Queueing

  Page work is queued from three places -- Extraction as each page is
  rendered, a Reprocess or Retry failed pages when the user asks, Recovery
  when a boot finds pages still owed -- and the three used to agree only by
  restating the job's shape, priority and uniqueness semantics. `queue/3` is
  the one statement of them: the caller says what kind of work this is, and
  the kind decides the rest.

  | kind         | queued by                         | priority             | and then                                       |
  |--------------|-----------------------------------|----------------------|------------------------------------------------|
  | `:fresh`     | Extraction, as a page is rendered | ordinary             | nothing                                        |
  | `:requested` | Reprocess, Retry failed pages     | ahead of fresh pages | nothing: the caller reset the page             |
  | `:recovered` | Recovery, at boot                 | ordinary             | marks the job `recovered` and resumes the page |

  A recovered page was interrupted mid-stage, so once its job is queued the
  content stages that job will redo go back to `pending` through
  `PageLifecycle.resume/1`: the page reads as queued, not as stuck or failed,
  while its retry waits. A requested page needs no such step, because the
  reset that preceded it already returned every stage to `pending`.

  Which models the job carries is one rule for every kind, `Run.page_model_args/2`:
  the models the Page requested, else the Document's, else none, leaving the
  defaults to the attempt. A reset writes the user's choices on the Page, so a
  requested page carries them without the caller encoding them again.

  `queue/3` opens no transaction and takes no lock. Extraction queues under the
  Run fence, a Reprocess, a Retry and Recovery under the Document lock, and the job
  commits with whatever its caller's transaction commits. The generation the
  job carries is the one the Page holds as it is handed in, so the caller
  passes the Page it has just read or written.

  ## The attempt

  An attempt runs the stages the page still owes, in order -- extraction, then
  translation, each one model call -- and then settles the document. It adds
  no retry loop of its own: a transient failure is answered `{:error, _}` for
  Oban to back off and retry, and a failure that retrying cannot fix
  `{:cancel, _}`, so that no attempt is spent repeating it. A stage that fails
  is marked failed on the page, which is what lets the next attempt resume at
  that stage rather than from the start.

  The caller says whether this is the job's last attempt, and the document is
  settled on the page's account whenever the outcome is final: a success, a
  cancel, or an error or crash on the last attempt. The document reaches
  `error` only by settling, once every page has settled, so a page exhausting
  its retries while its siblings still run changes nothing yet, and one
  failing after the user cancelled changes nothing at all.

  Every stage write is a transition of `Doctrans.Documents.PageLifecycle`,
  which fences it and announces it. A page reset, replaced or deleted while
  its run is in flight makes every further write to it answer
  `{:error, :obsolete_run}`; such a run ends as `:ok`, because the generation
  that superseded it now owns the work.
  """

  require Logger

  alias Doctrans.Documents.{Document, Lifecycle, Page, PageLifecycle}
  alias Doctrans.Errors
  alias Doctrans.Jobs.{Keys, LlmProcessingJob}
  alias Doctrans.Processing.PageWork.Stages
  alias Doctrans.Processing.Run
  alias Doctrans.Repo

  @typedoc "Who is asking for the work, which decides how the job is queued."
  @type kind :: :fresh | :requested | :recovered

  @typedoc """
  What became of the request.

  - `:queued` -- the job is in the queue
  - `:owned` -- an active job already holds this page; it is that job's to finish
  - `:not_owed` -- both content stages are complete, so there is nothing to queue
  """
  @type queue_outcome :: {:ok, :queued | :owned | :not_owed} | {:error, Errors.reason()}

  @typedoc """
  What the job should do next: nothing, retry, or stop retrying.

  A stage's outcome is the attempt's: the attempt adds no outcome of its own.
  """
  @type attempt_outcome :: Stages.outcome()

  @doc """
  Queues the Page's content work as the given `kind` of request.

  Uniqueness on the page keeps one job per Page: a request for a Page an
  active job already holds answers `{:ok, :owned}` and changes nothing. What
  that means is the caller's to say -- Extraction carries on, a Reprocess
  refuses, Recovery leaves the page's stages to the job that owns them.
  """
  @spec queue(Page.t(), Document.t(), as: kind()) :: queue_outcome()
  def queue(%Page{} = page, %Document{} = document, as: kind)
      when kind in [:fresh, :requested, :recovered] do
    if owed?(page) do
      Logger.info("Queueing page #{page.page_number} of document #{document.id} (#{kind})")

      page
      |> args(document)
      |> LlmProcessingJob.new(options(kind))
      |> Repo.insert_job()
      |> case do
        {:ok, %Oban.Job{}} -> follow_up(kind, page)
        {:conflict, %Oban.Job{}} -> {:ok, :owned}
        {:error, _reason} = error -> Errors.result(error)
      end
    else
      {:ok, :not_owed}
    end
  end

  # Queue first, then resume: uniqueness also covers a job queued since the
  # page was selected, and a job that already owns the page owns its stages.
  defp follow_up(:recovered, page) do
    with {:ok, _resumed} <- PageLifecycle.resume(page), do: {:ok, :queued}
  end

  defp follow_up(_kind, _page), do: {:ok, :queued}

  # A page is owed work until both of its content stages have completed; the
  # embedding stage is the index pipeline's and queued separately.
  defp owed?(page) do
    not (PageLifecycle.done?(page, :extraction) and PageLifecycle.done?(page, :translation))
  end

  # Retries and resets go ahead of the pages of a fresh upload: the user is
  # waiting on them, and a fresh run's pages are already a queue of their own.
  defp options(:fresh), do: [priority: 2]
  defp options(:requested), do: [priority: 1]
  defp options(:recovered), do: [priority: 2, meta: %{recovered: true}]

  # The argument map `Doctrans.Jobs.LlmProcessingJob.perform/1` destructures.
  defp args(page, document) do
    Map.merge(
      %{
        Keys.page_id() => page.id,
        "page_number" => page.page_number,
        "generation" => page.processing_generation
      },
      Run.page_model_args(page, document)
    )
  end

  @doc """
  Runs one attempt at the page's content work and settles its document when
  the outcome is final.

  Returns `:ok`, `{:error, reason}` when the failed stage is worth another
  attempt, or `{:cancel, reason}` when it is not -- a permanent model error,
  or a page that no longer exists. A crash is re-raised after the document
  has been settled, when this was the last attempt.

  ## Options

  - `:generation` -- the page generation this run was queued for; a page that
    has moved on is skipped, and one without the option acts for whatever
    the page holds now
  - `:last_attempt?` -- whether the job will not run again after this
    attempt; an error then settles the document (default `false`)
  - `:extraction_model`, `:translation_model` -- the run's model choices,
    defaulting to the configured models
  """
  @spec attempt(Ecto.UUID.t(), keyword()) :: attempt_outcome()
  def attempt(page_id, opts \\ []) do
    {last?, opts} = Keyword.pop(opts, :last_attempt?, false)
    generation = Keyword.fetch(opts, :generation)

    try do
      process_page(page_id, generation, opts)
    catch
      # A crash returns no outcome. The stage it interrupted was marked failed
      # on the way out (`Stages`), so the page has settled and the document can
      # settle on it; re-raising leaves Oban to decide whether to try again.
      kind, reason ->
        if last?, do: settle_failed(page_id, generation)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      {:cancel, _reason} = outcome ->
        settle_failed(page_id, generation)
        outcome

      {:error, _reason} = outcome when last? ->
        settle_failed(page_id, generation)
        outcome

      outcome ->
        outcome
    end
  end

  # `generation` is the `:generation` option as fetched -- `{:ok, _}` or
  # `:error` -- so that an attempt made without it is told apart from one made
  # for a page that holds none.
  defp process_page(page_id, generation, opts) do
    opts = Map.to_list(Run.choices(opts))

    case Repo.get(Page, page_id) do
      nil ->
        {:cancel, :page_not_found}

      page ->
        if current_generation?(page, generation) do
          page |> do_process_page(opts) |> concede_obsolete_run(page)
        else
          Logger.info("Page #{page_id} has moved on to a newer generation, skipping it")
          :ok
        end
    end
  end

  # An attempt that names no generation acts for whatever the page holds now;
  # a page that is gone is nobody's.
  defp current_generation?(nil, _generation), do: false
  defp current_generation?(_page, :error), do: true

  defp current_generation?(page, {:ok, generation}),
    do: Run.current?(page, generation: generation)

  # Every page write is a `PageLifecycle` transition, which answers
  # `{:error, :obsolete_run}` once the page has been reset, replaced or deleted
  # under this run. The work belongs to the generation that superseded it, so
  # the run concedes it and ends as a success rather than as a retry of work it
  # no longer owns. This is not a Settle: the document is left to that
  # generation's attempt.
  defp concede_obsolete_run({:error, :obsolete_run}, page) do
    Logger.info("Page #{page.id} changed mid-run, leaving it to its current generation")
    :ok
  end

  defp concede_obsolete_run(outcome, _page), do: outcome

  defp do_process_page(page, opts) do
    with :ok <- maybe_extract(page, opts),
         {:ok, extracted} <- reload_page(page),
         :ok <- maybe_translate(extracted, opts) do
      settle_succeeded(extracted)
    end
  end

  # The row can be gone between stages: indexing is the last thing extraction
  # does, and a deletion that lands there takes the page with it.
  defp reload_page(page) do
    case Repo.get(Page, page.id) do
      nil -> {:error, :obsolete_run}
      current -> {:ok, current}
    end
  end

  # A retried or rescued Oban job may have left a stage processing or failed;
  # a stage is owed until it has completed.
  defp maybe_extract(page, opts) do
    if PageLifecycle.owed?(page, :extraction) do
      Stages.extract(page, opts)
    else
      Logger.debug("Skipping extraction for page #{page.page_number}, already completed")
      :ok
    end
  end

  defp maybe_translate(page, opts) do
    cond do
      not (PageLifecycle.done?(page, :extraction) and PageLifecycle.owed?(page, :translation)) ->
        :ok

      is_binary(page.original_markdown) and page.original_markdown != "" ->
        Stages.translate(page, opts)

      true ->
        # No content to translate: the stage completes with an empty translation.
        Logger.warning(
          "Page #{page.page_number} has no content to translate, marking as completed"
        )

        with {:ok, _page} <- PageLifecycle.complete(page, :translation, %{markdown: ""}),
             do: :ok
    end
  end

  # The final page write and the document's completion are separate
  # transactions, so a crash between them leaves a processing document whose
  # pages are all saved. A replay skips both stages and would return `:ok`
  # without ever revisiting the document, which is why the check belongs to
  # every successful attempt rather than to the one that happened to save the
  # last translation. Resolving it costs no model call.
  #
  # Hand over the page this attempt already read rather than a fresh copy. The
  # lifecycle fences the check against that page's revision and generation,
  # and a row re-read here would only ever be compared against itself. The
  # translation writes in between cannot invalidate it: `content_revision`
  # advances on an `original_markdown` change or an extraction leaving
  # "completed", and `processing_generation` only on a reprocess.
  defp settle_succeeded(page) do
    _ = Lifecycle.settle(page)
    :ok
  end

  # A failure settles from a fresh row, unlike a success: the extraction this
  # attempt may have saved before its translation failed moved the revision
  # on, and the lifecycle would refuse the page read at the start as obsolete.
  # A page whose generation has moved on is not this attempt's to settle, by
  # the same reading of the option the run check made.
  defp settle_failed(page_id, generation) do
    page = Repo.get(Page, page_id)
    _ = if current_generation?(page, generation), do: Lifecycle.settle(page)
    :ok
  end
end
