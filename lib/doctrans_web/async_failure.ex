defmodule DoctransWeb.AsyncFailure do
  @moduledoc "Safe classification for application warnings about failed LiveView tasks."

  # Exception messages, request arguments and arbitrary exit terms can contain
  # credentials. Inspection limits truncate them; they do not redact them.
  # This covers our warning only, not OTP's independent task crash report.
  def summary({%{__exception__: true, __struct__: module}, _stacktrace}) when is_atom(module) do
    inspect(module)
  end

  def summary(reason) when reason in [:normal, :shutdown, :killed, :timeout, :noproc],
    do: Atom.to_string(reason)

  def summary({:shutdown, _reason}), do: "shutdown"
  def summary(_reason), do: "unexpected task failure"
end
