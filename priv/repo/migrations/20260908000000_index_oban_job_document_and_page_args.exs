defmodule Doctrans.Repo.Migrations.IndexObanJobDocumentAndPageArgs do
  use Ecto.Migration

  def change do
    # Keep these persisted keys literal: historical migrations must not depend on
    # application modules. Match Worker's pending-job cancellation predicates.
    create index(:oban_jobs, ["(args->>'document_id')"],
             name: :oban_jobs_pending_document_id_index,
             where: "state IN ('available', 'scheduled', 'retryable')"
           )

    create index(:oban_jobs, ["(args->>'page_id')"],
             name: :oban_jobs_pending_page_id_index,
             where: "state IN ('available', 'scheduled', 'retryable')"
           )
  end
end
