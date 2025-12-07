defmodule DoctransWeb.Plugs.SetLocale do
  @moduledoc """
  Plug to set the locale based on the browser's Accept-Language header.
  """
  import Plug.Conn

  @supported_locales ~w(en de)
  @default_locale "en"

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = get_locale_from_header(conn) || @default_locale
    Gettext.put_locale(DoctransWeb.Gettext, locale)
    conn
  end

  defp get_locale_from_header(conn) do
    conn
    |> get_req_header("accept-language")
    |> parse_accept_language()
  end

  defp parse_accept_language([header | _]) do
    header
    |> String.split(",")
    |> Enum.map(&extract_locale/1)
    |> Enum.find(&(&1 in @supported_locales))
  end

  defp parse_accept_language([]), do: nil

  defp extract_locale(lang) do
    lang |> String.split(";") |> hd() |> String.trim() |> String.slice(0, 2)
  end
end
