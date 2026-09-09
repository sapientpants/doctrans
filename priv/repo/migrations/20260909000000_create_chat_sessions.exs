defmodule Doctrans.Repo.Migrations.CreateChatSessions do
  use Ecto.Migration

  def change do
    create table(:chat_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :document_id, references(:documents, type: :uuid, on_delete: :delete_all), null: false
      add :retrieved_context, {:array, :map}, null: false, default: []
    end

    create unique_index(:chat_sessions, [:document_id])

    create table(:messages) do
      add :chat_session_id, references(:chat_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :role, :string, null: false
      add :content, :text, null: false
      add :completed, :boolean, null: false, default: false
    end

    create index(:messages, [:chat_session_id, :id])
  end
end
