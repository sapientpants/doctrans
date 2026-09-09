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
        %{"document_id" => document.id}
        |> DocumentExtractionJob.new(meta: %{recovered: true})
        |> Oban.insert!()
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
          page_number: p.page_number,
          extraction_status: p.extraction_status,
          translation_status: p.translation_status
        }
      )
      |> fetch_batch(after_id)

    pages =
      Repo.transact(fn ->
        pages = Enum.map(rows, &recover_page/1)
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
    changes = %{
      extraction_status: recovered_status(row.extraction_status),
      translation_status: recovered_status(row.translation_status)
    }

    page = struct!(Page, row) |> Ecto.Changeset.change(changes) |> Repo.update!()

    _job =
      %{"page_id" => row.id, "page_number" => row.page_number}
      |> LlmProcessingJob.new(priority: 2, meta: %{recovered: true})
      |> Oban.insert!()

    # Fetch the complete page for the same progress event used by normal processing.
    Repo.get!(Page, page.id)
  end

  defp recovered_status("completed"), do: "completed"
  defp recovered_status(_status), do: "pending"

  defp next_cursor(rows, phase, _fallback) when length(rows) == @batch_size,
    do: {phase, List.last(rows).id}

  defp next_cursor(_rows, _phase, fallback), do: fallback

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: raise("Startup recovery failed: #{inspect(reason)}")
end
