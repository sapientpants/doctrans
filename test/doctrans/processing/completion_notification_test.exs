defmodule Doctrans.Processing.CompletionNotificationTest do
  use ExUnit.Case, async: false

  alias Doctrans.{Documents, Repo}
  alias Doctrans.Documents.Topics
  alias Doctrans.Processing.DocumentOrchestrator
  alias DoctransWeb.DocumentLive.Show
  alias Ecto.Adapters.SQL.Sandbox

  test "completion is published after the transaction returns and the viewer reads committed state" do
    {document, page} =
      Sandbox.unboxed_run(Repo, fn ->
        document = Doctrans.Fixtures.document_fixture(%{status: "processing", total_pages: 1})

        page =
          Doctrans.Fixtures.page_fixture(document, %{
            extraction_status: "completed",
            translation_status: "completed"
          })

        {document, page}
      end)

    handler = {__MODULE__, make_ref()}
    :telemetry.attach(handler, [:doctrans, :repo, :query], &__MODULE__.hold_commit/4, self())

    on_exit(fn ->
      :telemetry.detach(handler)
      Sandbox.unboxed_run(Repo, fn -> Documents.delete_document(document) end)
    end)

    Topics.subscribe_document(document.id)

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put(:hold_review_commit, true)
          DocumentOrchestrator.check_document_completion(page)
        end)
      end)

    assert_receive {:commit_waiting, pid}, 5_000
    premature = receive do: ({:document_updated, _} -> true), after: (0 -> false)
    send(pid, :release_commit)
    assert Task.await(task) == :completed
    refute premature, "completion was broadcast before the transaction returned"
    assert_receive {:document_updated, updated}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, document: document, current_page_number: 1}
    }

    {:noreply, socket} =
      Sandbox.unboxed_run(Repo, fn ->
        Show.handle_info({:document_updated, updated}, socket)
      end)

    assert socket.assigns.document.status == "completed"
  end

  def hold_commit(_event, _measurements, metadata, owner) do
    if metadata.query == "commit" && Process.delete(:hold_review_commit) do
      send(owner, {:commit_waiting, self()})

      receive do
        :release_commit -> :ok
      after
        5_000 -> raise "commit was not released"
      end
    end
  end
end
