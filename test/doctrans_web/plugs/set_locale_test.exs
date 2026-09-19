defmodule DoctransWeb.Plugs.SetLocaleTest do
  use DoctransWeb.ConnCase, async: true

  # The Gettext locale lives in the process dictionary, so a locale set by the
  # plug here stays inside this test's own process and cannot leak into other
  # async tests.

  alias DoctransWeb.Locale
  alias DoctransWeb.Plugs.SetLocale

  @german "de-DE,de;q=0.9,en-US;q=0.8"

  describe "lang query parameter" do
    test "a supported value is used, assigned, and stored as an explicit choice" do
      conn = run("/?lang=fr")

      assert conn.assigns.locale == "fr"
      assert stored(conn) == {"fr", "fr"}
      assert Gettext.get_locale(DoctransWeb.Gettext) == "fr"
    end

    test "a supported value outranks both a stored choice and the browser header" do
      conn =
        run("/?lang=es", session: %{"locale" => "fr", "locale_choice" => "fr"}, header: @german)

      assert conn.assigns.locale == "es"
      assert stored(conn) == {"es", "es"}
    end

    test "an unsupported value never clears a stored explicit choice" do
      conn = run("/?lang=zz", session: %{"locale" => "fr", "locale_choice" => "fr"})

      assert conn.assigns.locale == "fr"
      assert stored(conn) == {"fr", "fr"}
    end

    test "an unsupported value still lets browser detection win over the default" do
      conn = run("/?lang=zz", header: @german)

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", nil}
    end

    test "an unsupported value is stored nowhere" do
      conn = run("/?lang=zz")

      assert conn.assigns.locale == Locale.default()
      assert stored(conn) == {Locale.default(), nil}
    end
  end

  describe "lang=auto" do
    test "it clears a stored choice and hands the language back to the browser" do
      conn =
        run("/?lang=auto", session: %{"locale" => "fr", "locale_choice" => "fr"}, header: @german)

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", nil}
    end

    test "it falls back to the default when the browser asks for nothing supported" do
      conn = run("/?lang=auto", session: %{"locale" => "fr", "locale_choice" => "fr"})

      assert conn.assigns.locale == Locale.default()
      assert stored(conn) == {Locale.default(), nil}
    end

    test "it is harmless when no choice is stored" do
      conn = run("/?lang=auto", header: @german)

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", nil}
    end
  end

  describe "Accept-Language detection" do
    test "the region is stripped and the detected locale is persisted for the LiveView mount" do
      conn = run("/", header: @german)

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", nil}
      assert Gettext.get_locale(DoctransWeb.Gettext) == "de"
    end

    test "a regional tag with no bare fallback is still matched" do
      conn = run("/", header: "de-AT")

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", nil}
    end

    test "the first supported tag wins over earlier unsupported ones" do
      conn = run("/", header: "zz-ZZ,ja;q=0.9,fr-CA;q=0.8,de;q=0.7")

      assert conn.assigns.locale == "fr"
      assert stored(conn) == {"fr", nil}
    end

    test "tags are taken in the order sent, not by q weight" do
      # Pins the documented tradeoff: browsers send tags in preference order, so
      # the weights are not compared. Changing that should fail here on purpose.
      conn = run("/", header: "en;q=0.1,de;q=0.9")

      assert conn.assigns.locale == "en"
    end

    test "the Norwegian tags browsers actually send resolve to the Norwegian translations" do
      for header <- ["nb-NO,nb;q=0.9", "nn-NO", "nb"] do
        conn = run("/", header: header)

        assert conn.assigns.locale == "no", "#{header} did not resolve to Norwegian"
      end
    end

    test "a header with no supported tag falls back to the default" do
      conn = run("/", header: "ja-JP,ja;q=0.9")

      assert conn.assigns.locale == Locale.default()
      assert stored(conn) == {Locale.default(), nil}
    end

    test "detection loses to an explicit stored choice" do
      conn = run("/", session: %{"locale" => "fr", "locale_choice" => "fr"}, header: @german)

      assert conn.assigns.locale == "fr"
    end
  end

  describe "stored session locale" do
    test "an explicit choice is reused, and re-persisted, without a lang parameter" do
      conn = run("/", session: %{"locale" => "fr", "locale_choice" => "fr"})

      assert conn.assigns.locale == "fr"
      assert stored(conn) == {"fr", "fr"}
      assert Gettext.get_locale(DoctransWeb.Gettext) == "fr"
    end

    test "a choice that is not currently supported is remembered, not discarded" do
      # The resolved locale falls back, but the choice itself survives so that
      # restoring the locale restores the user's language.
      conn = run("/", session: %{"locale" => "fr", "locale_choice" => "xx"}, header: @german)

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", "xx"}
    end

    test "a choice that becomes supported again is honoured again" do
      conn = run("/", session: %{"locale" => "de", "locale_choice" => "fr"}, header: @german)

      assert conn.assigns.locale == "fr"
      assert stored(conn) == {"fr", "fr"}
    end

    test "a merely detected locale is re-derived rather than pinned" do
      # Only a stored choice is sticky; a detected locale is recomputed from the
      # header the browser sends on every request.
      conn = run("/", session: %{"locale" => "de"}, header: "fr-FR,fr")

      assert conn.assigns.locale == "fr"
      assert stored(conn) == {"fr", nil}
    end

    test "a detected locale is re-derived to the default when the header disappears" do
      conn = run("/", session: %{"locale" => "de"})

      assert conn.assigns.locale == Locale.default()
      assert stored(conn) == {Locale.default(), nil}
    end
  end

  describe "session writes" do
    # Writing any session key marks the session dirty, which makes Plug.Session
    # re-encrypt and re-send the cookie on the response. A steady session should
    # not pay that on every request.
    test "an unchanged locale does not dirty the session" do
      conn = run("/", session: %{"locale" => "de"}, header: @german)

      assert conn.assigns.locale == "de"
      refute conn.private[:plug_session_info] == :write
    end

    test "an unchanged explicit choice does not dirty the session" do
      conn = run("/?lang=fr", session: %{"locale" => "fr", "locale_choice" => "fr"})

      assert conn.assigns.locale == "fr"
      refute conn.private[:plug_session_info] == :write
    end

    test "a changed locale does dirty the session" do
      conn = run("/", session: %{"locale" => "de"}, header: "fr-FR,fr")

      assert conn.private[:plug_session_info] == :write
    end

    test "lang=auto with nothing stored does not dirty the session" do
      conn = run("/?lang=auto", session: %{"locale" => "de"}, header: @german)

      refute conn.private[:plug_session_info] == :write
    end
  end

  test "a lang value is normalised the same way a header tag is" do
    for value <- ["de-DE", "DE", "de-AT", " de "] do
      conn = run("/?lang=#{URI.encode(value)}")

      assert conn.assigns.locale == "de", "#{value} did not resolve to German"
      assert stored(conn) == {"de", "de"}
    end
  end

  test "a lang parameter that is not a single value is not a choice" do
    for query <- ["lang[]=de", "lang[a]=de"] do
      conn = run("/?#{query}", header: @german)

      # The header still decides; the malformed parameter neither crashes nor
      # counts as an explicit choice.
      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", nil}
    end
  end

  test "with no parameter, no session, and no header the default is used" do
    conn = run("/")

    assert conn.assigns.locale == Locale.default()
    assert conn.assigns.locale == "en"
    assert stored(conn) == {"en", nil}
    assert Gettext.get_locale(DoctransWeb.Gettext) == "en"
  end

  test "every configured locale is reachable through the lang parameter" do
    for locale <- Locale.supported() do
      conn = run("/?lang=#{locale}")

      assert conn.assigns.locale == locale
      assert stored(conn) == {locale, locale}
    end
  end

  defp run(path, opts \\ []) do
    path
    |> build_request(opts)
    |> SetLocale.call(SetLocale.init([]))
  end

  defp build_request(path, opts) do
    # The session is primed by hand because this conn is built outside the
    # endpoint, whose Plug.Session plug would normally fetch it.
    conn =
      :get
      |> build_conn(path)
      |> put_private(:plug_session, %{})
      |> put_private(:plug_session_fetch, :done)

    conn =
      Enum.reduce(Keyword.get(opts, :session, %{}), conn, fn {key, value}, conn ->
        put_session(conn, key, value)
      end)

    # Priming the session above marks it dirty. The key is deleted rather than
    # set to nil because Plug only flags a write with `Map.put_new/3`, so a key
    # that merely exists would suppress the flag the assertions look for.
    conn = update_in(conn.private, &Map.delete(&1, :plug_session_info))

    case Keyword.get(opts, :header) do
      nil -> conn
      header -> put_req_header(conn, "accept-language", header)
    end
  end

  defp stored(conn) do
    {get_session(conn, Locale.session_key()), get_session(conn, Locale.choice_session_key())}
  end
end
