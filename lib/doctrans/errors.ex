defmodule Doctrans.Errors do
  @moduledoc "Locale-independent error reasons at domain boundaries."

  @type reason :: atom() | {atom(), keyword()}

  @doc "Normalizes dependency failures without turning them into user-facing text."
  @spec normalize(term()) :: reason()
  def normalize(%Ecto.Changeset{} = changeset), do: {:validation_failed, [changeset: changeset]}
  def normalize(%Req.TransportError{reason: reason}), do: {:transport_error, [reason: reason]}

  def normalize({:http_error, status}) when is_integer(status),
    do: {:http_error, [status: status]}

  def normalize(reason) when is_atom(reason), do: reason
  def normalize({code, bindings}) when is_atom(code) and is_list(bindings), do: {code, bindings}
  def normalize(reason), do: {:operation_failed, [reason: reason]}

  @doc "Normalizes an error result, preserving successful results."
  def result({:error, reason}), do: {:error, normalize(reason)}
  def result(result), do: result

  @doc "Keeps the legacy status text column diagnostic, without calling Gettext."
  def diagnostic(nil), do: nil
  def diagnostic(reason) when is_binary(reason), do: reason
  def diagnostic(reason), do: inspect(reason)
end
