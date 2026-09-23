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
      published = Regex.scan(~r/^\s*-\s*"([\d.]+):\d+:\d+"/m, compose, capture: :all_but_first)

      assert published != []
      assert Enum.all?(published, &(&1 == ["127.0.0.1"]))
    end

    test "refuses to start without a secret key base", %{compose: compose} do
      # `:?` makes Compose abort with the message rather than boot without one.
      assert compose =~ ~r/SECRET_KEY_BASE:\s*\$\{SECRET_KEY_BASE:\?/
    end

    test "runs migrations before the server", %{compose: compose} do
      assert [[migrate, server]] =
               Regex.scan(~r{/app/bin/(migrate)\s*&&\s*/app/bin/(server)}, compose,
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
  end
end
