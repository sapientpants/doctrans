defmodule Doctrans.Processing.MissingConverterStub do
  @moduledoc """
  A `DocumentConverter` that reports LibreOffice as not installed.

  Lets a test reach the branch a machine without LibreOffice takes, without
  depending on whether the machine running the suite happens to have it.
  """

  def available?, do: false

  def convert_to_pdf(_source_path, _output_dir), do: {:error, :soffice_not_found}
end
