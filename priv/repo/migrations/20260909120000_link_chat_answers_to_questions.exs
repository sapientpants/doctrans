defmodule Doctrans.Repo.Migrations.LinkChatAnswersToQuestions do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :question_id, references(:messages, on_delete: :nilify_all)
    end

    create index(:messages, [:question_id])
  end
end
