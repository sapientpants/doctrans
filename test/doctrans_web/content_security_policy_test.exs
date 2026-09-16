defmodule DoctransWeb.ContentSecurityPolicyTest do
  use DoctransWeb.ConnCase, async: true

  # U13. The policy used to be a literal map written inline in the `:browser`
  # pipeline; it is now rendered from a directive list shared with the dashboard
  # exception. That refactor is only safe if it changed nothing the browser
  # sees, so the expectations below are spelled out in full rather than derived
  # from the module under test: a literal is the only assertion a bug in the
  # renderer cannot satisfy by being wrong in both places at once.

  alias DoctransWeb.ContentSecurityPolicy

  @base "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"

  @dashboard "default-src 'self'; script-src 'self' 'nonce-n0nce'; style-src 'self' 'nonce-n0nce'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"

  describe "base/0" do
    test "is byte for byte the policy the browser pipeline served before the refactor" do
      # Copied from the pre-U13 router literal. If a directive is reordered,
      # renamed, or given a source, this is where that shows up -- it is a
      # change to what every response in the application carries.
      assert ContentSecurityPolicy.base() == @base
    end

    test "admits no inline or evaluated code anywhere" do
      # The whole point of the base policy: `'self'` for executable sources and
      # nothing else. A nonce here would be the dashboard exception leaking out
      # of its scope and onto every page.
      refute ContentSecurityPolicy.base() =~ "unsafe-inline"
      refute ContentSecurityPolicy.base() =~ "unsafe-eval"
      refute ContentSecurityPolicy.base() =~ "nonce-"
      refute ContentSecurityPolicy.base() =~ "*"
    end
  end

  describe "dashboard/1" do
    test "is the base policy plus exactly the three sources LiveDashboard needs" do
      assert ContentSecurityPolicy.dashboard("n0nce") == @dashboard
    end

    test "widens nothing the literal above could not have caught by accident" do
      # The literal is a strong guard but a silent one: read as prose it does
      # not say *which* directives moved. Comparing the two policies directive
      # by directive states the claim the module's docs make -- three added
      # sources, no directive removed, no directive reordered.
      base = directives(ContentSecurityPolicy.base())
      dashboard = directives(ContentSecurityPolicy.dashboard("n0nce"))

      assert Enum.map(base, &elem(&1, 0)) == Enum.map(dashboard, &elem(&1, 0))

      added =
        for {{name, before}, {_name, now}} <- Enum.zip(base, dashboard),
            source <- now -- before,
            do: {name, source}

      assert added == [
               {"script-src", "'nonce-n0nce'"},
               {"style-src", "'nonce-n0nce'"},
               {"font-src", "data:"}
             ]

      # And nothing was taken away to make room: every base source survives.
      for {{_, before}, {_, now}} <- Enum.zip(base, dashboard) do
        assert before -- now == []
      end
    end

    test "still admits no inline or evaluated code" do
      # A nonce in a directive makes browsers ignore `'unsafe-inline'` there, so
      # an `'unsafe-inline'` added alongside one would be dead in modern
      # browsers and live in old ones -- the worst of both.
      policy = ContentSecurityPolicy.dashboard("n0nce")

      refute policy =~ "unsafe-inline"
      refute policy =~ "unsafe-eval"
    end

    test "renders a nonce containing base64 punctuation verbatim" do
      # The minted nonce is `Base.encode64/1` output, so `+` and `/` are
      # ordinary characters in it (18 bytes encode to 24 unpadded characters, so
      # `=` never appears there -- it is included below because the CSP grammar
      # allows it and a future length change would produce it). None of the
      # three may be escaped, stripped, or re-encoded on the way into the header.
      assert ContentSecurityPolicy.dashboard("a+b/c=") =~ "script-src 'self' 'nonce-a+b/c='"
      assert ContentSecurityPolicy.dashboard("a+b/c=") =~ "style-src 'self' 'nonce-a+b/c='"
    end
  end

  describe "headers/0" do
    test "is the map shape put_secure_browser_headers/2 takes" do
      # It is passed straight to a function plug, which has no `init/1`, so a
      # wrong shape is not caught at compile time or at boot: it raises on the
      # first request through the pipeline, i.e. on every page at once. Named
      # explicitly here instead of left to whichever test rendered first.
      headers = ContentSecurityPolicy.headers()

      assert is_map(headers)
      assert Map.keys(headers) == ["content-security-policy"]
      assert headers["content-security-policy"] == ContentSecurityPolicy.base()
    end

    test "is accepted by put_secure_browser_headers/2 and overrides its default policy" do
      # Plug ships its own `content-security-policy` default, and merging is the
      # documented way to replace it. Proving the merge lands means the base
      # policy the rest of this suite asserts is the one actually served.
      conn =
        :get
        |> build_conn("/")
        |> Phoenix.Controller.put_secure_browser_headers(ContentSecurityPolicy.headers())

      assert get_resp_header(conn, "content-security-policy") == [ContentSecurityPolicy.base()]
    end
  end

  # Splits a rendered policy back into `{directive, sources}` pairs, in the
  # order the header states them.
  defp directives(policy) do
    policy
    |> String.split("; ")
    |> Enum.map(fn directive ->
      [name | sources] = String.split(directive, " ")
      {name, sources}
    end)
  end
end
