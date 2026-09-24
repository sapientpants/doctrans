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
      dockerfile: read("Dockerfile")
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

  defp assert_loopback_ports!(compose) do
    ports = Enum.flat_map(compose["services"], fn {_name, service} -> service["ports"] || [] end)
    assert ports != []
    assert Enum.all?(ports, &(&1["host_ip"] in ["127.0.0.1", "::1"])), inspect(ports)
    ports
  end

  defp assert_named_volumes!(compose) do
    volumes =
      Enum.flat_map(compose["services"], fn {_name, service} -> service["volumes"] || [] end)

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

      assert Enum.any?(app["volumes"], fn volume ->
               volume["type"] == "volume" and volume["source"] == "doctrans_runtime_data" and
                 volume["target"] == @data_dir
             end)

      assert Enum.any?(compose["services"]["db"]["volumes"], fn volume ->
               volume["type"] == "volume" and volume["source"] == "doctrans_runtime_pgdata" and
                 volume["target"] == "/var/lib/postgresql"
             end)
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

      assert Enum.any?(app["volumes"], fn volume ->
               volume["type"] == "bind" and volume["source"] == @root and
                 volume["target"] == "/app"
             end)
    end

    test "does not claim to be a deployment", %{compose: compose} do
      refute inspect(compose["services"]["app"]["command"]) =~ "/app/bin/server"
      refute inspect(compose["services"]["app"]["command"]) =~ "mix release"
    end

    test "states its container binding explicitly", %{compose: compose} do
      # The endpoint has to listen on every interface *inside* the container for
      # the loopback-published port to reach it. Saying so here keeps it out of
      # `config/dev.exs`, where it was once inferred from DATABASE_HOST and so
      # widened a developer's own binding as a side effect of moving Postgres.
      assert compose["services"]["app"]["environment"]["PHX_BIND_IP"] == "0.0.0.0"
    end

    test "publishes every port on loopback only", %{compose: compose} do
      # Both services, and no bare `"4000:4000"`: the container binding above
      # only stays safe while the publication is what limits reachability.
      assert length(assert_loopback_ports!(compose)) == 2
    end
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
