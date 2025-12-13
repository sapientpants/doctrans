defmodule Doctrans.Processing.DocumentConverterBehaviour do
  @moduledoc """
  Behaviour for document format conversion.

  This allows mocking the document conversion in tests.
  """

  @callback convert_to_pdf(source_path :: String.t(), output_dir :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @callback available?() :: boolean()
end
