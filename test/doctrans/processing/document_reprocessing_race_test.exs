defmodule Doctrans.Processing.DocumentReprocessingRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
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

    owner = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Oban.Testing.with_testing_mode(:manual, fn ->
              send(owner, {:ready, self()})

              receive do
                :go -> DocumentReprocessing.reprocess_document(document.id)
              end
            end)
          end)
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, pid}, 5_000
      send(pid, :go)
    end

    results = Task.await_many(tasks, 10_000)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_processing})) == 1

    Sandbox.unboxed_run(Repo, fn ->
      worker = Oban.Worker.to_string(DocumentExtractionJob)

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
end
