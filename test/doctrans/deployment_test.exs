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

  defp read(name), do: File.read!(Path.join(@root, name))

  # Match every mapping that is only digits, dots and colons — which is the
  # shape of a port entry and not of `host.docker.internal:host-gateway`, nor of
  # a volume, both of which carry letters or slashes. Matching the address
  # separately would miss `"4000:4000"`, the one that publishes on every
  # interface, and that is the regression worth catching.
  #
  # The quotes have to be optional. `- 4000:4000` is valid Compose YAML — with no
  # space after the colon it is a plain scalar, not a mapping — so a regex that
  # required them would skip precisely the entry that publishes on every
  # interface and leave the assertions below passing over it.
  defp published_ports(compose) do
    ~r/^\s*-\s*"?([\d.:]+)"?\s*$/m
    |> Regex.scan(compose, capture: :all_but_first)
    |> List.flatten()
  end

  describe "the runtime deployment" do
    setup do
      %{compose: read("docker-compose.runtime.yml"), dockerfile: read("Dockerfile")}
    end

    test "builds the release Dockerfile, not the development one", %{compose: compose} do
      # The header comment names the development file to contrast with it, so
      # look at the `build:` directive rather than at any mention.
      assert compose =~ ~r/^\s*dockerfile:\s*Dockerfile\s*$/m
      refute compose =~ ~r/^\s*dockerfile:\s*Dockerfile\.dev/m
    end

    test "mounts no source tree", %{compose: compose} do
      # A bind mount is `- <host path>:<container path>`; a named volume's source
      # is a bare identifier. Any host path here would shadow the release.
      refute compose =~ ~r/^\s*-\s*["']?(\.|\/|~|\$\{?PWD)/m
    end

    test "persists the document store at the configured data root", %{compose: compose} do
      assert compose =~ ~r/-\s*doctrans_runtime_data:#{@data_dir}\b/
      assert compose =~ ~r/DOCTRANS_DATA_DIR:\s*#{@data_dir}\b/
    end

    test "names a project and volumes that cannot collide with the development stack",
         %{compose: compose} do
      development = read("docker-compose.yml")

      # Without an explicit project name both files derive `doctrans` from the
      # directory, and `up` would reconcile this file against the dev containers.
      assert compose =~ ~r/^name:\s*doctrans-runtime\s*$/m
      refute development =~ ~r/^name:/m

      for volume <- ~w(doctrans_runtime_pgdata doctrans_runtime_data) do
        assert compose =~ volume
        refute development =~ volume
      end
    end

    test "publishes every port on loopback only", %{compose: compose} do
      published = published_ports(compose)

      assert published != []
      assert Enum.all?(published, &String.starts_with?(&1, "127.0.0.1:"))
    end

    test "refuses to start without a secret key base", %{compose: compose} do
      # `:?` makes Compose abort with the message rather than boot without one.
      assert compose =~ ~r/SECRET_KEY_BASE:\s*\$\{SECRET_KEY_BASE:\?/
    end

    test "runs migrations before the server, and execs it", %{compose: compose} do
      # `exec` is not decoration: without it the wrapping shell stays PID 1 and
      # the BEAM never receives the SIGTERM that a graceful stop depends on.
      assert [[migrate, server]] =
               Regex.scan(~r{/app/bin/(migrate)\s*&&\s*exec\s+/app/bin/(server)}, compose,
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

    test "ships a release from a runtime stage that carries no build toolchain", %{
      dockerfile: dockerfile
    } do
      assert dockerfile =~ "mix release"
      assert dockerfile =~ ~r/^FROM\s+debian:.*AS runtime/mi
      assert dockerfile =~ ~r/^COPY --from=builder/m
      assert dockerfile =~ ~r/^USER doctrans/m
    end
  end

  describe "the development stack" do
    setup do: %{compose: read("docker-compose.yml")}

    test "still bind-mounts the source tree for hot reload", %{compose: compose} do
      assert compose =~ ~r/^\s*-\s*\.:\/app\s*$/m
      assert compose =~ "Dockerfile.dev"
    end

    test "does not claim to be a deployment", %{compose: compose} do
      refute compose =~ "/app/bin/server"
      refute compose =~ "mix release"
    end

    test "states its container binding explicitly", %{compose: compose} do
      # The endpoint has to listen on every interface *inside* the container for
      # the loopback-published port to reach it. Saying so here keeps it out of
      # `config/dev.exs`, where it was once inferred from DATABASE_HOST and so
      # widened a developer's own binding as a side effect of moving Postgres.
      assert compose =~ ~r/^\s*PHX_BIND_IP:\s*"0\.0\.0\.0"\s*$/m
    end

    test "publishes every port on loopback only", %{compose: compose} do
      # Both services, and no bare `"4000:4000"`: the container binding above
      # only stays safe while the publication is what limits reachability.
      published = published_ports(compose)

      assert length(published) == 2
      assert Enum.all?(published, &String.starts_with?(&1, "127.0.0.1:"))
    end
  end
end
