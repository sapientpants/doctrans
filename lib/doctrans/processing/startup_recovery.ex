defmodule Doctrans.Processing.StartupRecovery do
  @moduledoc """
  Recovers work in batches of at most 50 jobs. Cursors keep each startup pass
  finite, while active Oban jobs are left to Oban's own retry/recovery lifecycle.
  """

  import Ecto.Query

  alias Doctrans.Documents.{Document, Page, Topics}
  alias Doctrans.Jobs.{DocumentExtractionJob, LlmProcessingJob}
  alias Doctrans.Repo

  @batch_size 50
  @active_states ~w(available scheduled executing retryable suspended)

  @doc "Returns the next cursor, or :done when the startup pass is complete."
  def run_batch(cursor \\ {:documents, nil})

  def run_batch({:documents, after_id}) do
    worker = Oban.Worker.to_string(DocumentExtractionJob)

    rows =
      from(d in Document,
        as: :document,
        where: d.status in ["queued", "extracting"],
        where:
          not exists(
            from(j in Oban.Job,
              where: j.worker == ^worker and j.state in ^@active_states,
              where: fragment("?->>'document_id' = ?::text", j.args, parent_as(:document).id),
              select: 1
            )
          ),
        select: %{id: d.id}
      )
      |> fetch_batch(after_id)

    Repo.transact(fn ->
      Enum.each(rows, fn document ->
        case Repo.one(from(d in Document, where: d.id == ^document.id, lock: "FOR UPDATE")) do
          %Document{status: status} when status in ["queued", "extracting"] ->
            %{"document_id" => document.id}
            |> DocumentExtractionJob.new(meta: %{recovered: true})
            |> Oban.insert!()

          _ ->
            :ok
        end
      end)

      {:ok, :queued}
    end)
    |> unwrap!()

    next_cursor(rows, :documents, {:pages, nil})
  end

  def run_batch({:pages, after_id}) do
    worker = Oban.Worker.to_string(LlmProcessingJob)

    rows =
      from(p in Page,
        as: :page,
        join: d in Document,
        on: d.id == p.document_id,
        where: d.status == "processing",
        where: p.extraction_status != "completed" or p.translation_status != "completed",
        where:
          not exists(
            from(j in Oban.Job,
              where: j.worker == ^worker and j.state in ^@active_states,
              where: fragment("?->>'page_id' = ?::text", j.args, parent_as(:page).id),
              select: 1
            )
          ),
        select: %{
          id: p.id,
          document_id: p.document_id
        }
      )
      |> fetch_batch(after_id)

    pages =
      Repo.transact(fn ->
        pages = Enum.flat_map(rows, &recover_page/1)
        {:ok, pages}
      end)
      |> unwrap!()

    Enum.each(pages, &Topics.broadcast_page_update/1)
    next_cursor(rows, :pages, :done)
  end

  defp fetch_batch(query, nil) do
    query |> order_by([row], asc: row.id) |> limit(@batch_size) |> Repo.all()
  end

  defp fetch_batch(query, after_id) do
    query |> where([row], row.id > ^after_id) |> fetch_batch(nil)
  end

  defp recover_page(row) do
    # Lock the parent first so stopping/deleting a document cannot race recovery.
    document =
      from(d in Document, where: d.id == ^row.document_id, lock: "FOR UPDATE")
      |> Repo.one()

    page = from(p in Page, where: p.id == ^row.id, lock: "FOR UPDATE") |> Repo.one()

    case {document, page} do
      {%Document{status: "processing"}, %Page{} = page} -> maybe_recover_page(page)
      _ -> []
    end
  end

  defp maybe_recover_page(%Page{extraction_status: "completed", translation_status: "completed"}),
    do: []

  defp maybe_recover_page(page) do
    # Insert before changing statuses: uniqueness also covers jobs queued since
    # candidate selection. A conflicting job owns this page's processing state.
    job =
      %{"page_id" => page.id, "page_number" => page.page_number}
      |> LlmProcessingJob.new(priority: 2, meta: %{recovered: true})
      |> Oban.insert!()

    if job.conflict? do
      []
    else
      changes = %{
        extraction_status: recovered_status(page.extraction_status),
        translation_status: recovered_status(page.translation_status)
      }

      [page |> Ecto.Changeset.change(changes) |> Repo.update!()]
    end
  end

  defp recovered_status("completed"), do: "completed"
  defp recovered_status(_status), do: "pending"

  defp next_cursor(rows, phase, _fallback) when length(rows) == @batch_size,
    do: {phase, List.last(rows).id}

  defp next_cursor(_rows, _phase, fallback), do: fallback

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: raise("Startup recovery failed: #{inspect(reason)}")
end
