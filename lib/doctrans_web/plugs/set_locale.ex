defmodule DoctransWeb.Plugs.SetLocale do
  @moduledoc """
  Plug to set the locale based on query parameter, session, or browser's Accept-Language header.

  The locale is determined in the following order:
  1. Supported `lang` query parameter - an explicit choice, persisted to the session
  2. Explicit choice previously persisted to the session
  3. Browser's Accept-Language header
  4. Default locale (en)

  Step 3 takes the first supported tag in the order the browser sent them; the
  `q` weights are not compared, so a client that lists its tags out of
  preference order is resolved by order rather than by weight.

  The resolved locale is written to the session, so a LiveView mounting from
  this request sees the same locale the plug applied. An explicit choice is
  stored separately, as a locale rather than a flag, and is never overwritten by
  detection: a choice that is temporarily unsupported is remembered rather than
  lost, and is honoured again if that locale returns. `?lang=auto` clears it and
  hands the language back to browser detection.

  An unsupported `lang` value is ignored rather than honoured or stored:
  resolution continues with the steps below it and any explicit choice already
  stored is kept, so a bad link cannot reset the language. The resolved locale
  is also assigned to the connection as `:locale` for the root layout's
  `<html lang>` attribute.

  Session keys are only written when their value actually changes, so a steady
  browsing session does not re-emit the session cookie on every response.

  Note: this plug only runs on HTTP requests, so a `lang` parameter carried by a
  live navigation (`<.link navigate=>`/`patch`) never reaches it. A language
  switcher has to issue a real request with `<.link href=>`.

  Note: LiveView processes use the on_mount hook (DoctransWeb.Live.Hooks.SetLocale)
  to read the locale from the session, since Gettext.put_locale is process-specific.
  """
  import Plug.Conn

  alias DoctransWeb.Locale

  # Reserved `lang` value that clears a stored choice. It can never collide with
  # a real locale, which is always a two-letter code.
  @reset_param "auto"

  # Tags that name a supported locale under a different code. Norwegian is the
  # case that matters: browsers send `nb`/`nn`, never the macrolanguage `no`.
  @aliases %{"nb" => "no", "nn" => "no"}

  def init(opts), do: opts

  def call(conn, _opts) do
    {locale, conn} = determine_locale(conn)

    _previous_locale = Gettext.put_locale(DoctransWeb.Gettext, locale)

    conn
    |> put_locale_session(Locale.session_key(), locale)
    |> assign(:locale, locale)
  end

  defp determine_locale(conn) do
    conn = fetch_query_params(conn)
    {choice, conn} = resolve_choice(conn)

    {choice || detected_locale(conn), conn}
  end

  # A `lang` value is normalised exactly like a header tag, so the spelling a
  # browser uses for itself (`de-DE`, `DE`) also works in the URL. Anything that
  # is not a single string - a repeated or bracketed param - is not a choice.
  defp resolve_choice(conn) do
    case conn.query_params["lang"] do
      lang when is_binary(lang) -> requested_choice(conn, extract_locale(lang))
      _ -> {stored_choice(conn), conn}
    end
  end

  defp requested_choice(conn, @reset_param), do: {nil, clear_choice(conn)}

  defp requested_choice(conn, lang) do
    case supported_locale(lang) do
      nil -> {stored_choice(conn), conn}
      locale -> {locale, put_locale_session(conn, Locale.choice_session_key(), locale)}
    end
  end

  # The stored choice is validated on read but deliberately left in place when
  # it is not currently supported, so removing and restoring a locale does not
  # silently discard the user's choice.
  defp stored_choice(conn) do
    conn |> get_session(Locale.choice_session_key()) |> supported_locale()
  end

  defp detected_locale(conn) do
    conn
    |> get_req_header("accept-language")
    |> parse_accept_language()
    |> Kernel.||(Locale.default())
  end

  defp supported_locale(locale) do
    if Locale.supported?(locale), do: locale
  end

  # Writing a session key marks the session dirty, which re-emits the cookie on
  # the response, so only write when the value is actually new.
  defp put_locale_session(conn, key, value) do
    if get_session(conn, key) == value, do: conn, else: put_session(conn, key, value)
  end

  defp clear_choice(conn) do
    key = Locale.choice_session_key()
    if get_session(conn, key) == nil, do: conn, else: delete_session(conn, key)
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
    code =
      lang
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.split("-")
      |> hd()
      |> String.downcase()

    Map.get(@aliases, code, code)
  end
end
