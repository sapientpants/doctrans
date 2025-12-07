defmodule DoctransWeb.Plugs.SetLocale do
  @moduledoc """
  Plug to set the locale based on query parameter, session, or browser's Accept-Language header.

  The locale is determined in the following order:
  1. `lang` query parameter (for testing purposes) - persists to session
  2. Browser's Accept-Language header (when no lang param)
  3. Default locale (en)

  When a `lang` query parameter is provided, it is stored in the session.
  When navigating without a `lang` parameter, any stored session locale is cleared.

  Note: LiveView processes use the on_mount hook (DoctransWeb.Live.Hooks.SetLocale)
  to read the locale from the session, since Gettext.put_locale is process-specific.
  """
  import Plug.Conn

  @supported_locales ~w(da de en es fr it nl no pl pt sv)
  @default_locale "en"
  @session_key "locale"

  def init(opts), do: opts

  def call(conn, _opts) do
    {locale, conn} = determine_locale(conn)

    Gettext.put_locale(DoctransWeb.Gettext, locale)
    conn
  end

  defp determine_locale(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["lang"] do
      lang when lang in @supported_locales ->
        # Store in session for LiveView to read via on_mount hook
        {lang, put_session(conn, @session_key, lang)}

      _ ->
        # No lang param - clear session and use browser detection
        locale = get_locale_from_header(conn) || @default_locale
        {locale, delete_session(conn, @session_key)}
    end
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
