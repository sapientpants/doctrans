defmodule DoctransWeb.Plugs.SetLocale do
  @moduledoc """
  Plug to set the locale based on query parameter, session, or browser's Accept-Language header.

  The locale is determined in the following order:
  1. Supported `lang` query parameter - an explicit choice, persisted to the session
  2. Explicit choice previously persisted to the session
  3. Browser's Accept-Language header - persisted to the session as a detected choice
  4. Default locale (en)

  Step 3 takes the first supported tag in the order the browser sent them; the
  `q` weights are not compared, so a client that lists its tags out of
  preference order is resolved by order rather than by weight.

  Whatever is resolved is written to the session, so LiveView mounts and later
  requests see the same locale. An unsupported `lang` value is ignored rather
  than honoured or stored: resolution continues with the steps below it and any
  explicit choice already stored is kept, so a bad link cannot reset the
  language. A stored locale that is no longer supported is discarded the same
  way. The resolved locale is also assigned to the connection as `:locale` for
  the root layout's `<html lang>` attribute.

  Note: this plug only runs on HTTP requests, so a `lang` parameter carried by a
  live navigation (`<.link navigate=>`/`patch`) never reaches it. A language
  switcher has to issue a real request with `<.link href=>`.

  Note: LiveView processes use the on_mount hook (DoctransWeb.Live.Hooks.SetLocale)
  to read the locale from the session, since Gettext.put_locale is process-specific.
  """
  import Plug.Conn

  alias DoctransWeb.Locale

  def init(opts), do: opts

  def call(conn, _opts) do
    {locale, conn} = determine_locale(conn)

    _previous_locale = Gettext.put_locale(DoctransWeb.Gettext, locale)
    assign(conn, :locale, locale)
  end

  defp determine_locale(conn) do
    conn = fetch_query_params(conn)

    cond do
      locale = requested_locale(conn.query_params["lang"]) ->
        {locale, put_locale_session(conn, locale, true)}

      locale = explicit_session_locale(conn) ->
        {locale, conn}

      true ->
        # Persist the detected locale so the on_mount hook resolves the same one
        locale = get_locale_from_header(conn) || Locale.default()
        {locale, put_locale_session(conn, locale, false)}
    end
  end

  defp put_locale_session(conn, locale, explicit?) do
    conn
    |> put_session(Locale.session_key(), locale)
    |> put_session(Locale.explicit_session_key(), explicit?)
  end

  defp explicit_session_locale(conn) do
    if get_session(conn, Locale.explicit_session_key()) do
      supported_locale(get_session(conn, Locale.session_key()))
    end
  end

  # A `lang` value is normalised exactly like a header tag, so the spelling a
  # browser uses for itself (`de-DE`, `DE`) also works in the URL. Anything that
  # is not a single string - a repeated or bracketed param - is not a choice.
  defp requested_locale(lang) when is_binary(lang), do: supported_locale(extract_locale(lang))
  defp requested_locale(_lang), do: nil

  defp supported_locale(locale) do
    if Locale.supported?(locale), do: locale
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
    |> Enum.find(&Locale.supported?/1)
  end

  defp parse_accept_language([]), do: nil

  # Extracts the language code from an Accept-Language header value.
  # Handles regional codes like "en-US", "de-DE" by taking only the language part.
  defp extract_locale(lang) do
    lang
    |> String.split(";")
    |> hd()
    |> String.trim()
    |> String.split("-")
    |> hd()
    |> String.downcase()
  end
end
