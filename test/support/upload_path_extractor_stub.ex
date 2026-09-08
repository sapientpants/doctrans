defmodule Doctrans.UploadPathExtractorStub do
  @moduledoc false

  # Keep the uploaded original on disk for containment assertions.
  def get_page_count(_path), do: {:error, :invalid_pdf}
end
