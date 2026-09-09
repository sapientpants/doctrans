defmodule Doctrans.Chat.Session do
  @moduledoc "Persisted conversation and bounded retrieval context for one document."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "chat_sessions" do
    field :document_id, :binary_id
    field :retrieved_context, {:array, :map}, default: []
  end
end
