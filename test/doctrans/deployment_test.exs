defmodule Doctrans.DeploymentTest do
  @moduledoc """
  Guards the separation between the development stack and the runtime deployment.

  Two Compose files and two Dockerfiles describe deliberately different things:
  `docker-compose.yml` bind-mounts this source tree and runs `mix phx.server`,
  while `docker-compose.runtime.yml` runs an assembled release out of `Dockerfile`
  with its state in named volumes. The regression this exists to catch is the two
  quietly converging — a bind mount added to the runtime file (which would make
  the release read a source tree it cannot use), a data volume dropped (which
  would put documents in the container's writable layer, where a `compose up
  --build` deletes them), a port published beyond loopback in an app that has no
  authentication, or the migration step disappearing from the startup command.

  The development stack has its own guarded posture (#264): it runs the
  converters on uploaded documents with the checkout bind-mounted in, so it
  must not do so as root, must keep the storage root off that mount, and must
  mount the checkout read-only, since a write into it is a step towards
  execution on the next request, boot, checkout or agent session. Its image
  is built from the whole checkout, so `.dockerignore` must keep every local
  env file out of the build context (#273): the encrypted `.env.gpg` was once
  baked into a layer because only the plaintext names were listed.

  The assertions are deliberately semantic and few, so ordinary edits to either
  file — reordering, comments, whitespace — do not break them.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @data_dir "/var/lib/doctrans"

  setup_all do
    %{
      runtime_compose: compose!("docker-compose.runtime.yml"),
      development_compose: compose!("docker-compose.yml"),
      dockerfile: read("Dockerfile"),
      dev_dockerfile: read("Dockerfile.dev"),
      dockerignore: dockerignore!(".dockerignore")
    }
  end

  defp read(name), do: File.read!(Path.join(@root, name))

  # Compose resolves all supported YAML spellings into the same model. This
  # command only parses configuration: it needs the CLI, but never a daemon.
  # Ignore the operator's .env and project overrides while inspecting the files.
  defp compose(path, interpolate? \\ false) do
    flags = if interpolate?, do: [], else: ["--no-interpolate"]

    System.cmd(
      "docker",
      [
        "compose",
        "--env-file",
        "/dev/null",
        "--project-directory",
        @root,
        "-f",
        Path.expand(path, @root),
        "config",
        "--format",
        "json"
      ] ++ flags,
      env: [{"SECRET_KEY_BASE", nil}, {"COMPOSE_PROJECT_NAME", nil}, {"COMPOSE_FILE", nil}],
      stderr_to_stdout: true
    )
  end

  defp compose!(path) do
    {output, status} = compose(path)
    assert status == 0, "Compose could not parse #{path}: #{output}"
    Jason.decode!(output)
  end

  # Whether the service has a mount matching every given field of Compose's
  # resolved volume model (`type`, `source`, `target`, `read_only`).
  defp mount?(service, fields) do
    Enum.any?(service["volumes"] || [], fn volume ->
      Enum.all?(fields, fn {key, value} -> volume[Atom.to_string(key)] == value end)
    end)
  end

  # The rules of a `.dockerignore`, in order, as `{negated?, regex}` pairs. It
  # follows the subset of Docker's syntax the file uses: a pattern matches the
  # whole path from the context root, `*` and `?` stop at a separator, a
  # pattern that names a directory covers everything beneath it, and a leading
  # `!` means "included after all". `**` and `[...]` are refused rather than
  # approximated, so a rule the matcher cannot judge fails loudly here instead
  # of passing silently.
  defp dockerignore!(name) do
    name
    |> read()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&dockerignore_rule!/1)
  end

  defp dockerignore_rule!("!" <> pattern), do: {true, dockerignore_regex!(pattern)}
  defp dockerignore_rule!(pattern), do: {false, dockerignore_regex!(pattern)}

  defp dockerignore_regex!(pattern) do
    if String.contains?(pattern, ["**", "["]) do
      raise ArgumentError, "unsupported .dockerignore pattern: #{inspect(pattern)}"
    end

    source =
      pattern
      |> String.trim_trailing("/")
      |> String.split(~r/[*?]/, include_captures: true)
      |> Enum.map_join(fn
        "*" -> "[^/]*"
        "?" -> "[^/]"
        literal -> Regex.escape(literal)
      end)

    Regex.compile!("^(?:" <> source <> ")(?:/.*)?$")
  end

  # Whether the rules keep a path out of the build context: the last matching
  # rule decides.
  defp dockerignored?(rules, path) do
    Enum.reduce(rules, false, fn {negated?, regex}, ignored? ->
      if Regex.match?(regex, path), do: not negated?, else: ignored?
    end)
  end

  defp assert_loopback_ports!(compose) do
    ports = Enum.flat_map(compose["services"], fn {_name, service} -> service["ports"] || [] end)
    assert ports != []
    assert Enum.all?(ports, &(&1["host_ip"] in ["127.0.0.1", "::1"])), inspect(ports)
    ports
  end

  defp assert_named_volumes!(compose) do
    volumes =
      Enum.flat_map(compose["services"], fn {_name, service} -> service["volumes"] || [] end)

    # Without this, dropping `volumes:` altogether -- the regression that puts
    # documents in the container's writable layer -- satisfies `Enum.all?/2`
    # vacuously. `assert_loopback_ports!/1` guards the same way.
    assert volumes != []
    assert Enum.all?(volumes, &(&1["type"] == "volume")), inspect(volumes)
  end

  defp assert_distinct_volume_names!(runtime, development) do
    runtime_names = Enum.map(runtime["volumes"], fn {_key, volume} -> volume["name"] end)
    development_names = Enum.map(development["volumes"], fn {_key, volume} -> volume["name"] end)
    assert MapSet.disjoint?(MapSet.new(runtime_names), MapSet.new(development_names))
  end

  describe "the runtime deployment" do
    setup %{runtime_compose: compose}, do: %{compose: compose}

    test "builds the release Dockerfile, not the development one", %{compose: compose} do
      assert compose["services"]["app"]["build"]["dockerfile"] == "Dockerfile"
    end

    test "mounts no source tree", %{compose: compose} do
      assert_named_volumes!(compose)
    end

    test "persists the document store at the configured data root", %{compose: compose} do
      app = compose["services"]["app"]
      assert app["environment"]["DOCTRANS_DATA_DIR"] == @data_dir

      assert mount?(app, type: "volume", source: "doctrans_runtime_data", target: @data_dir)

      assert mount?(compose["services"]["db"],
               type: "volume",
               source: "doctrans_runtime_pgdata",
               target: "/var/lib/postgresql"
             )
    end

    test "names a project and volumes that cannot collide with the development stack",
         %{compose: compose} do
      development = compose!("docker-compose.yml")

      # Without an explicit project name both files derive `doctrans` from the
      # directory, and `up` would reconcile this file against the dev containers.
      assert compose["name"] == "doctrans-runtime"
      assert development["name"] != compose["name"]
      assert_distinct_volume_names!(compose, development)

      for volume <- ~w(doctrans_runtime_pgdata doctrans_runtime_data) do
        assert compose["volumes"][volume]["name"] == volume
        refute Map.has_key?(development["volumes"], volume)
      end
    end

    test "publishes every port on loopback only", %{compose: compose} do
      assert length(assert_loopback_ports!(compose)) == 2
    end

    test "refuses to resolve without a secret key base" do
      {output, status} = compose("docker-compose.runtime.yml", true)
      assert status != 0
      assert output =~ "SECRET_KEY_BASE"
    end

    test "runs migrations before the server, and execs it", %{compose: compose} do
      # `exec` is not decoration: without it the wrapping shell stays PID 1 and
      # the BEAM never receives the SIGTERM that a graceful stop depends on.
      assert [[migrate, server]] =
               Regex.scan(
                 ~r{/app/bin/(migrate)\s*&&\s*exec\s+/app/bin/(server)},
                 compose["services"]["app"]["command"],
                 capture: :all_but_first
               )

      assert {migrate, server} == {"migrate", "server"}
    end

    test "ships the operator scripts a release has instead of Mix" do
      # These are `rel/overlays/`, copied into the release verbatim. Losing the
      # executable bit makes them unrunnable in the image, which no assertion on
      # the Compose file would catch.
      for script <- ~w(server migrate verify_restore) do
        path = Path.join([@root, "rel", "overlays", "bin", script])

        assert File.regular?(path)
        assert %File.Stat{mode: mode} = File.stat!(path)
        assert Bitwise.band(mode, 0o111) != 0, "#{script} is not executable"
      end
    end

    test "declares a release runtime stage and an unprivileged user", %{
      dockerfile: dockerfile
    } do
      assert dockerfile =~ "mix release"
      assert dockerfile =~ ~r/^FROM\s+debian:.*AS runtime/mi
      assert dockerfile =~ ~r/^COPY --from=builder/m
      assert dockerfile =~ ~r/^USER doctrans/m
    end
  end

  describe "the development stack" do
    setup %{development_compose: compose}, do: %{compose: compose}

    test "still bind-mounts the source tree for hot reload", %{compose: compose} do
      app = compose["services"]["app"]
      assert app["build"]["dockerfile"] == "Dockerfile.dev"

      assert mount?(app, type: "bind", source: @root, target: "/app")
    end

    test "does not claim to be a deployment", %{compose: compose} do
      refute inspect(compose["services"]["app"]["command"]) =~ "/app/bin/server"
      refute inspect(compose["services"]["app"]["command"]) =~ "mix release"
    end

    test "states its container binding explicitly", %{compose: compose} do
      # The endpoint has to listen on every interface *inside* the container for
      # the loopback-published port to reach it. Saying so here keeps it out of
      # the application's own configuration, where it was once inferred from
      # DATABASE_HOST and so widened a developer's own binding as a side effect
      # of moving Postgres.
      assert compose["services"]["app"]["environment"]["PHX_BIND_IP"] == "0.0.0.0"
    end

    test "publishes every port on loopback only", %{compose: compose} do
      # Both services, and no bare `"4000:4000"`: the container binding above
      # only stays safe while the publication is what limits reachability.
      assert length(assert_loopback_ports!(compose)) == 2
    end

    test "keeps the storage root off the checkout, in a named volume", %{compose: compose} do
      # Converters are handed the storage root as their `--outdir`; on the bind
      # mount that would be a tree the code reloader compiles from.
      app = compose["services"]["app"]
      assert app["environment"]["DOCTRANS_DATA_DIR"] == @data_dir
      assert mount?(app, type: "volume", target: @data_dir)

      # No bind mount, at any depth, may contain the storage root.
      refute Enum.any?(app["volumes"], fn volume ->
               volume["type"] == "bind" and String.starts_with?(@data_dir, volume["target"])
             end)
    end

    test "mounts the checkout read-only, except where the watchers build", %{compose: compose} do
      # A write into the checkout is a step towards execution: `lib/` on the
      # next request, `config/` and `mix.exs` on the next boot, `.git/hooks` on
      # the next checkout, `scripts/`, `.claude/` and `.pi/` in the next agent
      # session, and `.env` in the next `compose up`, which reads `user:` from
      # it. Only `priv/static`, where esbuild and tailwind write, is exempt.
      app = compose["services"]["app"]
      assert mount?(app, type: "bind", target: "/app", read_only: true)

      writable_binds =
        for %{"type" => "bind", "target" => target} = volume <- app["volumes"],
            volume["read_only"] != true,
            do: target

      assert writable_binds == ["/app/priv/static"]
    end

    test "keeps dependencies and build output off the checkout", %{compose: compose} do
      # A mount point cannot be created inside a read-only mount, so `deps/`
      # and `_build/` can no longer be shadowed in place. Mix is pointed at
      # volumes outside `/app` instead; lose either half and the stack cannot
      # compile.
      app = compose["services"]["app"]

      for key <- ~w(MIX_DEPS_PATH MIX_BUILD_ROOT) do
        path = app["environment"][key]
        refute String.starts_with?(path, "/app/"), "#{key} is on the checkout: #{path}"
        assert mount?(app, type: "volume", target: path), "#{key} (#{path}) is not a volume"
      end
    end

    test "runs as an unprivileged user whose ids the image shares", %{dev_dockerfile: dockerfile} do
      # Interpolated, unlike the fixture: `user:` is built from
      # `${DOCTRANS_UID:-1000}` and the resolved ids are what matter. Whatever
      # the environment supplies, neither may be root's.
      {output, 0} = compose("docker-compose.yml", true)
      app = Jason.decode!(output)["services"]["app"]

      assert [uid, gid] = String.split(app["user"], ":")
      assert uid =~ ~r/^[1-9]\d*$/, "uid is #{uid}"
      assert gid =~ ~r/^[1-9]\d*$/, "gid is #{gid}"

      # The image's own user takes the same ids, or the home directory, Hex and
      # the seeded dependency and build volumes belong to someone else.
      assert app["build"]["args"] == %{"UID" => uid, "GID" => gid}
      assert dockerfile =~ ~r/^USER dev/m
    end

    test "keeps every local env file out of the image", %{dockerignore: rules} do
      # `Dockerfile.dev` copies the whole checkout (#273). A developer's
      # `.env`, the Compose-only `.env.local`, the encrypted `.env.gpg` and any
      # future variant would otherwise land in a layer that `docker save` or
      # a stray push carries out of the machine.
      for secret <- [".env", ".env.local", ".env.gpg", ".env.production", ".env.backup"] do
        assert dockerignored?(rules, secret), "#{secret} reaches the build context"
      end
    end

    test "copies the env template in", %{dockerignore: rules} do
      # The template holds no secret and is what the README tells a newcomer
      # to copy, so it stays, and it has to exist for that advice to work.
      refute dockerignored?(rules, ".env.example")
      assert File.exists?(Path.join(@root, ".env.example"))
    end

    test "drops every capability and forbids gaining privileges", %{compose: compose} do
      app = compose["services"]["app"]
      assert app["cap_drop"] == ["ALL"]
      assert "no-new-privileges:true" in app["security_opt"]
    end

    test "gives the converters a private tmpfs /tmp", %{compose: compose} do
      # Compose keeps mount options on the entry (`/tmp:exec`), so match the
      # path alone.
      tmpfs = compose["services"]["app"]["tmpfs"] || []
      assert Enum.any?(tmpfs, &(hd(String.split(&1, ":")) == "/tmp")), inspect(tmpfs)
    end
  end

  test "the ignore matcher agrees with Docker on the rules the file already uses", %{
    dockerignore: rules
  } do
    # The env-file assertions are only as good as the matcher, so it is held
    # to rules whose effect is known: a directory excludes its contents, a
    # root glob does not reach into subdirectories, and an unlisted source
    # file is copied.
    assert dockerignored?(rules, "deps/phoenix/mix.exs")
    assert dockerignored?(rules, "README.md")
    refute dockerignored?(rules, "docs/CONTRIBUTING.md")
    refute dockerignored?(rules, "lib/doctrans/application.ex")
  end

  test "the ignore matcher refuses syntax it does not model" do
    assert_raise ArgumentError, ~r/unsupported/, fn -> dockerignore_rule!("**/.env") end
    assert_raise ArgumentError, ~r/unsupported/, fn -> dockerignore_rule!("*.[ch]") end
  end

  @tag :tmp_dir
  test "the port guard rejects exposed ports in every Compose spelling", %{tmp_dir: dir} do
    for entry <- [
          "4001:4001",
          "'4001:4001'",
          "\"4001:4001/tcp\"",
          "target: 4001\n        published: '4001'\n        host_ip: 0.0.0.0"
        ] do
      path = Path.join(dir, "ports.yml")

      File.write!(path, """
      services:
        app:
          image: busybox
          ports:
            - "127.0.0.1:4000:4000"
            - #{entry}
      """)

      parsed = compose!(path)
      assert length(parsed["services"]["app"]["ports"]) == 2
      assert_raise ExUnit.AssertionError, fn -> assert_loopback_ports!(parsed) end
    end
  end

  @tag :tmp_dir
  test "a different volume key cannot alias the runtime database volume", %{
    tmp_dir: dir,
    runtime_compose: runtime
  } do
    path = Path.join(dir, "volume-collision.yml")

    File.write!(path, """
    services:
      db:
        image: postgres
        volumes:
          - pgdata:/var/lib/postgresql
    volumes:
      pgdata:
        name: doctrans_runtime_pgdata
    """)

    development = compose!(path)

    assert_raise ExUnit.AssertionError, fn ->
      assert_distinct_volume_names!(runtime, development)
    end
  end

  @tag :tmp_dir
  test "the volume guard rejects a long-form bind mount", %{tmp_dir: dir} do
    path = Path.join(dir, "volumes.yml")

    File.write!(path, """
    services:
      app:
        image: busybox
        volumes:
          - type: bind
            source: .
            target: /app
    """)

    parsed = compose!(path)
    assert_raise ExUnit.AssertionError, fn -> assert_named_volumes!(parsed) end
  end
end
