defmodule Doctrans.Processing.DocumentConverterMocks do
  @moduledoc """
  Stubs for `Doctrans.Processing.DocumentConverterMock` beyond the real converter.

  The default stub is `Doctrans.Processing.DocumentConverter` itself, which
  needs LibreOffice; these replace it for the running test.
  """

  import Mox

  alias Doctrans.Processing.DocumentConverterMock

  @doc """
  A converter whose outcome the converting process controls.

  It reads the source file -- so a retry fails if an earlier attempt deleted
  the input -- and then consults `:conversion_result` in its own process
  dictionary: `:ok` (the default) writes the content to `original.pdf` in the
  output directory and returns its path; any other value is returned as is.
  Inline Oban jobs convert in the test process, so a test sets the result with
  `Process.put(:conversion_result, {:error, :conversion_timeout})`.
  """
  def retry do
    stub(DocumentConverterMock, :convert_to_pdf, &convert_or_fail/2)
    :ok
  end

  defp convert_or_fail(source_path, output_dir) do
    with {:ok, content} <- File.read(source_path) do
      case Process.get(:conversion_result, :ok) do
        :ok ->
          pdf_path = Path.join(output_dir, "original.pdf")
          File.write!(pdf_path, content)
          {:ok, pdf_path}

        error ->
          error
      end
    end
  end

  @doc """
  A converter that reports LibreOffice as not installed.

  Lets a test reach the branch a machine without LibreOffice takes, without
  depending on whether the machine running the suite happens to have it.
  """
  def missing do
    stub(DocumentConverterMock, :available?, fn -> false end)

    stub(DocumentConverterMock, :convert_to_pdf, fn _source_path, _output_dir ->
      {:error, :soffice_not_found}
    end)

    :ok
  end
end
