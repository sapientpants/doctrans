defmodule Doctrans.Chat.Message do
  @moduledoc """
  A durable chat message; incomplete user messages are excluded from model history.

  `changeset/1` is the one way a row is written, so the size of `content` is
  bounded at the row and not only at the chat panel: a question is held to
  `Doctrans.Validation.max_chat_question_bytes/0`, the bound the panel applies
  before it ever gets here, and an answer or error message to a ceiling well
  above anything the completion budget can produce.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Doctrans.Validation

  @roles ~w(user assistant error)

  # An answer is bounded by the completion's `max_tokens` (8192 at most), and a
  # token is a handful of bytes even in a multibyte script, so this is headroom,
  # not a limit anything legitimate approaches.
  @max_content_bytes 100_000

  schema "messages" do
    field :chat_session_id, :binary_id
    field :question_id, :id
    field :role, :string
    field :content, :string
    field :completed, :boolean, default: false
  end

  @type t :: %__MODULE__{}

  @doc "The most bytes any message's `content` may hold."
  @spec max_content_bytes() :: pos_integer()
  def max_content_bytes, do: @max_content_bytes

  @fields [:chat_session_id, :question_id, :role, :content, :completed]

  @doc """
  Validates a message struct about to be inserted.

  Takes the struct rather than params: every field is set by the application,
  none comes from a form, so there is nothing to cast. The fields are moved
  into the changeset's changes, though, because `validate_length/3` and
  `validate_inclusion/3` only look at changes, and a bare struct has none.
  """
  @spec changeset(t()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = message) do
    %__MODULE__{}
    |> change(message |> Map.from_struct() |> Map.take(@fields))
    |> validate_required([:chat_session_id, :role, :content])
    |> validate_inclusion(:role, @roles)
    |> validate_length(:content, max: content_bound(message.role), count: :bytes)
  end

  defp content_bound("user"), do: Validation.max_chat_question_bytes()
  defp content_bound(_role), do: @max_content_bytes
end
