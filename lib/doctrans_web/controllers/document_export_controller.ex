defmodule DoctransWeb.DocumentExportController do
  @moduledoc """
  Serves a document's translated work as a Markdown download.

  The rendering lives in `Doctrans.Documents.Export`; this controller only looks
  the document up and frames the response. It calls that module directly rather
  than through a context delegate, the way the document LiveViews already reach
  `Doctrans.Documents.Topics`: naming `Export` from `Doctrans.Documents` would
  have put that module one dependency over Credo's limit, and raising a quality
  threshold to fit a feature in is not a trade this repository makes.

  A missing row and a malformed id are the same answer to the reader -- 404 --
  so the lookup is the nil-returning `get_document_with_pages/1` rather than its
  raising sibling: a hand-typed URL should not surface as a 500.
  """
  use DoctransWeb, :controller

  alias Doctrans.Documents
  alias Doctrans.Documents.Export
  alias DoctransWeb.ErrorHTML

  @doc """
  Sends the document's Markdown export as a file download.
  """
  # The filename comes from `Export.filename/1`, which runs the title through
  # `Doctrans.Validation.sanitize_filename_string/1` and then caps and trims it, so
  # no path separator, quote, or control character reaches the `Content-Disposition`
  # header.
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    case Documents.get_document_with_pages(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: ErrorHTML)
        |> render(:"404")

      document ->
        send_download(conn, {:binary, Export.markdown(document)},
          filename: Export.filename(document),
          content_type: "text/markdown",
          charset: "utf-8"
        )
    end
  end
end
