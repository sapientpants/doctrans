defmodule Doctrans.Chat.Message do
  @moduledoc "A durable chat message; incomplete user messages are excluded from model history."
  use Ecto.Schema

  schema "messages" do
    field :chat_session_id, :binary_id
    field :question_id, :id
    field :role, :string
    field :content, :string
    field :completed, :boolean, default: false
  end

  @type t :: %__MODULE__{}
end
