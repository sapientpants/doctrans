defmodule Doctrans.Schema do
  @moduledoc """
  Shared schema configuration for Doctrans.

  Provides UUIDv7 primary keys for all schemas, giving us time-ordered,
  sortable unique identifiers.

  ## Usage

      defmodule Doctrans.Documents.Document do
        use Doctrans.Schema

        schema "documents" do
          field :title, :string
          timestamps()
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7}
      @foreign_key_type Uniq.UUID
    end
  end
end
