defmodule Doctrans.Search.ReindexTransactionTest do
  # A surrounding sandbox transaction would hide whether independent page jobs
  # committed. This one case uses real transactions and cleans up its own rows.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Doctrans.Repo

  import Doctrans.Fixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Doctrans.{Documents, Repo}
  alias Doctrans.Documents.Page
  alias Doctrans.Jobs.EmbeddingJob
  alias Doctrans.Search.Reindex
  alias Ecto.Adapters.SQL.Sandbox

  @tag :postgres
  test "a rejected page preserves committed jobs and does not prevent later pages from queuing" do
    document =
      Sandbox.unboxed_run(Repo, fn -> document_fixture(%{status: "completed", total_pages: 3}) end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DROP TRIGGER IF EXISTS reindex_contract_reject ON oban_jobs")
        Repo.query!("DROP FUNCTION IF EXISTS reindex_contract_reject()")

        page_ids =
          Repo.all(
            from(p in Page, where: p.document_id == ^document.id, select: type(p.id, :string))
          )

        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'page_id'", j.args) in ^page_ids)
        )

        Documents.delete_document(document)
      end)
    end)

    Sandbox.unboxed_run(Repo, fn ->
      Oban.Testing.with_testing_mode(:manual, fn ->
        [first, rejected, last] =
          for number <- 1..3 do
            document
            |> completed_page_fixture(%{page_number: number})
            |> Ecto.Changeset.change(embedding_status: "error")
            |> Repo.update!()
          end

        before = content_of([first, rejected, last])
        reject_jobs_for(rejected.id)

        log = capture_log(fn -> assert {:ok, 2} = Reindex.retry_document(document.id) end)
        assert log =~ rejected.id

        page_ids = [first.id, rejected.id, last.id]

        jobs =
          all_enqueued(worker: EmbeddingJob) |> Enum.filter(&(&1.args["page_id"] in page_ids))

        assert Enum.sort(Enum.map(jobs, &{&1.args["page_id"], &1.args["revision"]})) ==
                 Enum.sort([{first.id, first.content_revision}, {last.id, last.content_revision}])

        assert Repo.get!(Page, first.id).embedding_status == "pending"
        assert Repo.get!(Page, rejected.id).embedding_status == "error"
        assert Repo.get!(Page, last.id).embedding_status == "pending"
        assert content_of([first, rejected, last]) == before
      end)
    end)
  end

  defp content_of(pages) do
    for page <- pages do
      page = Repo.get!(Page, page.id)

      {page.id, page.original_markdown, page.translated_markdown, page.translation_status,
       page.content_revision, page.processing_generation}
    end
  end

  defp reject_jobs_for(page_id) do
    Repo.query!("""
    CREATE FUNCTION reindex_contract_reject() RETURNS trigger AS $$
    BEGIN
      IF NEW.args->>'page_id' = '#{page_id}' THEN
        RAISE EXCEPTION 'indexing job rejected by test';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    Repo.query!("""
    CREATE TRIGGER reindex_contract_reject BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION reindex_contract_reject()
    """)
  end
end
