defmodule Doctrans.Processing.DocumentReprocessingRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Doctrans.ProcessProbe, only: [eventually: 2]
  alias Doctrans.{Documents, Repo}
  alias Doctrans.Jobs.DocumentExtractionJob
  alias Doctrans.Processing.{DocumentReprocessing, Run}
  alias Ecto.Adapters.SQL.Sandbox

  test "independent concurrent requests admit exactly one new run" do
    Process.put(:oban_testing, :manual)

    document =
      Sandbox.unboxed_run(Repo, fn ->
        Doctrans.Fixtures.document_fixture(%{status: "completed", total_pages: 1})
      end)

    directory = Documents.document_upload_dir(document.id)
    File.mkdir_p!(directory)
    File.write!(Run.source_path(document), "original")

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        from(j in Oban.Job, where: fragment("?->>'document_id' = ?", j.args, ^document.id))
        |> Repo.delete_all()

        Documents.delete_document(document)
      end)
    end)

    handler = {__MODULE__, make_ref()}
    :telemetry.attach(handler, [:doctrans, :repo, :query], &__MODULE__.hold_lock/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    first = reprocess_task(document, true)
    assert_receive {:ready, first_pid, first_backend}, 5_000
    send(first_pid, :go)
    assert_receive {:document_locked, ^first_pid}, 5_000

    second = reprocess_task(document, false)
    assert_receive {:ready, second_pid, second_backend}, 5_000
    refute first_backend == second_backend
    send(second_pid, :go)

    try do
      # Observe actual PostgreSQL contention, not just two runnable BEAM tasks.
      # Without the document lock, the second request completes instead of
      # waiting behind the first transaction at this boundary.
      eventually(
        fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[blocked?]]} =
              Repo.query!("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [
                first_backend,
                second_backend
              ])

            blocked?
          end)
        end,
        "the second reprocess transaction to wait for the first document lock"
      )
    after
      send(first_pid, :release_reprocess_lock)
    end

    assert [{:ok, admitted}, {:error, :already_processing}] =
             Task.await_many([first, second], 10_000)

    Sandbox.unboxed_run(Repo, fn ->
      worker = Oban.Worker.to_string(DocumentExtractionJob)
      assert Documents.get_document!(document.id).processing_run_id == admitted.processing_run_id

      assert Repo.aggregate(
               from(j in Oban.Job,
                 where:
                   j.worker == ^worker and
                     fragment("?->>'document_id' = ?", j.args, ^document.id)
               ),
               :count
             ) == 1
    end)
  end

  defp reprocess_task(document, hold?) do
    owner = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        Process.put(:hold_reprocess_lock, hold?)
        send(owner, {:ready, self(), backend})

        receive do
          :go ->
            Oban.Testing.with_testing_mode(:manual, fn ->
              DocumentReprocessing.reprocess_document(document.id)
            end)
        after
          10_000 -> raise "reprocess request was not started"
        end
      end)
    end)
  end

  def hold_lock(_event, _measurements, metadata, owner) do
    if Process.get(:hold_reprocess_lock) && String.contains?(metadata.query, "FOR UPDATE") do
      Process.delete(:hold_reprocess_lock)
      send(owner, {:document_locked, self()})

      receive do
        :release_reprocess_lock -> :ok
      after
        10_000 -> raise "document lock was not released"
      end
    end
  end
end
