defmodule Doctrans.Repo.Row do
  @moduledoc """
  Reads one row of a `Doctrans.Repo.query/2` answer as the maps Library search
  and Retrieval return.

  Postgrex answers with column names beside rows of positional values, UUIDs
  as 16-byte binaries and numerics as `Decimal`s. Both result formatters want
  the row keyed by column, UUIDs in their string form and scores as floats.
  """

  @doc "A Postgrex row keyed by its column names."
  @spec to_map([term()], [String.t()]) :: %{String.t() => term()}
  def to_map(row, columns), do: columns |> Enum.zip(row) |> Map.new()

  @doc """
  A UUID column in its string form.

  A 16-byte binary is loaded; a string is already in that form; `nil` stays
  `nil`, as does a binary that is not a UUID.
  """
  @spec uuid_to_string(binary() | nil) :: Ecto.UUID.t() | nil
  def uuid_to_string(<<_::128>> = binary) do
    case Ecto.UUID.load(binary) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  def uuid_to_string(string) when is_binary(string), do: string
  def uuid_to_string(nil), do: nil

  @doc "A numeric column as a float; `nil` is `0.0`."
  @spec to_float(Decimal.t() | number() | nil) :: float()
  def to_float(nil), do: 0.0
  def to_float(%Decimal{} = d), do: Decimal.to_float(d)
  def to_float(f) when is_float(f), do: f
  def to_float(i) when is_integer(i), do: i / 1
end
