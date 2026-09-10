defmodule DoctransWeb.Plugs.UploadImages do
  @moduledoc "Serves only generated page PNGs from the shared upload directory."
  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Static.init(opts)

  @impl true
  def call(conn, opts) do
    if image_path?(Enum.map(conn.path_info, &URI.decode/1)),
      do: Plug.Static.call(conn, opts),
      else: conn
  end

  defp image_path?(["uploads", "documents", document_id, "pages", filename]),
    do: uuid?(document_id) && page_image?(filename)

  defp image_path?(["uploads", "documents", document_id, "runs", run_id, "pages", filename]),
    do: uuid?(document_id) && uuid?(run_id) && page_image?(filename)

  defp image_path?(_segments), do: false

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp page_image?(filename), do: Regex.match?(~r/\Apage-[0-9]+\.png\z/, filename)
end
