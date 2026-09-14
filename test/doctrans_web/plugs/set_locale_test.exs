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
      assert stored(conn) == {"fr", true}
      assert Gettext.get_locale(DoctransWeb.Gettext) == "fr"
    end

    test "a supported value outranks both a stored choice and the browser header" do
      conn =
        run("/?lang=es", session: %{"locale" => "fr", "locale_explicit" => true}, header: @german)

      assert conn.assigns.locale == "es"
      assert stored(conn) == {"es", true}
    end

    test "an unsupported value never clears a stored explicit choice" do
      conn = run("/?lang=zz", session: %{"locale" => "fr", "locale_explicit" => true})

      assert conn.assigns.locale == "fr"
      assert stored(conn) == {"fr", true}
    end

    test "an unsupported value still lets browser detection win over the default" do
      conn = run("/?lang=zz", header: @german)

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", false}
    end

    test "an unsupported value is never stored" do
      conn = run("/?lang=zz")

      assert conn.assigns.locale == Locale.default()
      refute get_session(conn, Locale.session_key()) == "zz"
    end
  end

  describe "Accept-Language detection" do
    test "the region is stripped and the detected locale is persisted for the LiveView mount" do
      conn = run("/", header: @german)

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", false}
      assert Gettext.get_locale(DoctransWeb.Gettext) == "de"
    end

    test "a regional tag with no bare fallback is still matched" do
      conn = run("/", header: "de-AT")

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", false}
    end

    test "the first supported tag wins over earlier unsupported ones" do
      conn = run("/", header: "zz-ZZ,ja;q=0.9,fr-CA;q=0.8,de;q=0.7")

      assert conn.assigns.locale == "fr"
      assert stored(conn) == {"fr", false}
    end

    test "a header with no supported tag falls back to the default" do
      conn = run("/", header: "ja-JP,ja;q=0.9")

      assert conn.assigns.locale == Locale.default()
      assert stored(conn) == {Locale.default(), false}
    end

    test "detection loses to an explicit stored choice" do
      conn = run("/", session: %{"locale" => "fr", "locale_explicit" => true}, header: @german)

      assert conn.assigns.locale == "fr"
    end
  end

  describe "stored session locale" do
    test "an explicit choice is reused without a lang parameter" do
      conn = run("/", session: %{"locale" => "fr", "locale_explicit" => true})

      assert conn.assigns.locale == "fr"
      assert Gettext.get_locale(DoctransWeb.Gettext) == "fr"
    end

    test "a stale explicit choice falls back to browser detection" do
      conn = run("/", session: %{"locale" => "xx", "locale_explicit" => true}, header: @german)

      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", false}
    end

    test "a stale explicit choice with no browser header falls back to the default" do
      conn = run("/", session: %{"locale" => "xx", "locale_explicit" => true})

      assert conn.assigns.locale == Locale.default()
      assert stored(conn) == {Locale.default(), false}
    end

    test "a merely detected locale is re-derived rather than pinned" do
      # The explicit flag is what makes a locale sticky; a detected one is
      # recomputed from the header the browser sends on every request.
      conn =
        run("/", session: %{"locale" => "de", "locale_explicit" => false}, header: "fr-FR,fr")

      assert conn.assigns.locale == "fr"
      assert stored(conn) == {"fr", false}
    end
  end

  test "a lang value is normalised the same way a header tag is" do
    for value <- ["de-DE", "DE", "de-AT", " de "] do
      conn = run("/?lang=#{URI.encode(value)}")

      assert conn.assigns.locale == "de", "#{value} did not resolve to German"
      assert stored(conn) == {"de", true}
    end
  end

  test "a lang parameter that is not a single value is not a choice" do
    for query <- ["lang[]=de", "lang[a]=de"] do
      conn = run("/?#{query}", header: @german)

      # The header still decides; the malformed parameter neither crashes nor
      # counts as an explicit choice.
      assert conn.assigns.locale == "de"
      assert stored(conn) == {"de", false}
    end
  end

  test "with no parameter, no session, and no header the default is used" do
    conn = run("/")

    assert conn.assigns.locale == Locale.default()
    assert conn.assigns.locale == "en"
    assert stored(conn) == {"en", false}
    assert Gettext.get_locale(DoctransWeb.Gettext) == "en"
  end

  test "every configured locale is reachable through the lang parameter" do
    for locale <- Locale.supported() do
      conn = run("/?lang=#{locale}")

      assert conn.assigns.locale == locale
      assert stored(conn) == {locale, true}
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

    case Keyword.get(opts, :header) do
      nil -> conn
      header -> put_req_header(conn, "accept-language", header)
    end
  end

  defp stored(conn) do
    {get_session(conn, Locale.session_key()), get_session(conn, Locale.explicit_session_key())}
  end
end
