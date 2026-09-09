defmodule Doctrans.Processing.RetryDocumentConverterStub do
  @moduledoc false

  def convert_to_pdf(source_path, output_dir) do
    # Reading the input makes a retry fail if an earlier attempt deleted it.
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
end
