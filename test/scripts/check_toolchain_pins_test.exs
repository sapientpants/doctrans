defmodule Scripts.CheckToolchainPinsTest do
  @moduledoc """
  Smoke-tests the pre-commit gate in `scripts/check_toolchain_pins.exs`.

  `mise.toml` is authoritative; the two Dockerfiles restate the Elixir/OTP tag
  and every base image in them must carry a digest. Each case builds the three
  files, breaks one thing, and checks that the gate names it.
  """
  use ExUnit.Case, async: true

  import Doctrans.GateScript, only: [run: 3, write: 3]

  @moduletag :tmp_dir
  @script "check_toolchain_pins.exs"

  @mise ~s([tools]\nelixir = "1.20.4-otp-29"\nerlang = "29.0.6"\n)
  @digest "sha256:" <> String.duplicate("ab", 32)
  @elixir_from "FROM elixir:1.20.4-otp-29@#{@digest}"
  @dev_dockerfile "#{@elixir_from}\nRUN mix local.hex --force\n"
  @release_dockerfile """
  #{@elixir_from} AS builder
  RUN mix release

  FROM debian:bookworm-slim@#{@digest} AS runtime
  COPY --from=builder /app/_build/prod/rel/doctrans /app
  """

  setup %{tmp_dir: dir} do
    write(dir, "mise.toml", @mise)
    write(dir, "Dockerfile.dev", @dev_dockerfile)
    write(dir, "Dockerfile", @release_dockerfile)
    :ok
  end

  test "agreeing, digest-pinned files pass", %{tmp_dir: dir} do
    assert {output, 0} = run(@script, [], dir)
    assert output =~ "Toolchain pins agree with mise.toml (elixir 1.20.4-otp-29, erlang 29.0.6)"
  end

  test "an Elixir tag that disagrees with mise.toml fails, naming the file and the expected tag",
       %{tmp_dir: dir} do
    write(dir, "Dockerfile.dev", "FROM elixir:1.19.0-otp-28@#{@digest}\n")

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "Dockerfile.dev pins `elixir:1.19.0-otp-28`, expected `elixir:1.20.4-otp-29`"
  end

  test "only the OTP major is compared, as that is all the image tag can express",
       %{tmp_dir: dir} do
    write(dir, "mise.toml", ~s([tools]\nelixir = "1.20.4-otp-29"\nerlang = "29.1.2"\n))

    assert {_output, 0} = run(@script, [], dir)
  end

  test "a base image pinned by tag only fails", %{tmp_dir: dir} do
    write(dir, "Dockerfile", "#{@elixir_from} AS builder\nFROM debian:bookworm-slim\n")

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "Dockerfile pins `debian:bookworm-slim` by tag only; add an @sha256 digest"
  end

  test "a digest that is not sha256:<64 hex> fails", %{tmp_dir: dir} do
    write(dir, "Dockerfile.dev", "FROM elixir:1.20.4-otp-29@sha256:abc\n")

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "Dockerfile.dev pins digest `sha256:abc`"
  end

  test "a stage name used as a FROM target needs no digest", %{tmp_dir: dir} do
    write(
      dir,
      "Dockerfile",
      @release_dockerfile <> "\nFROM runtime AS final\nCMD [\"/app/bin/server\"]\n"
    )

    assert {_output, 0} = run(@script, [], dir)
  end

  test "a Dockerfile that stopped using the elixir base fails rather than passing in silence",
       %{tmp_dir: dir} do
    write(dir, "Dockerfile.dev", "FROM debian:bookworm-slim@#{@digest}\n")

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "Dockerfile.dev has no `FROM elixir:` base to check against mise.toml"
  end

  test "a Dockerfile with no FROM at all aborts", %{tmp_dir: dir} do
    write(dir, "Dockerfile.dev", "RUN true\n")

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "no base image FROM instruction found in Dockerfile.dev"
  end

  test "a missing mise.toml aborts", %{tmp_dir: dir} do
    File.rm!(Path.join(dir, "mise.toml"))

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "cannot read mise.toml"
  end

  test "a mise.toml without an erlang pin aborts", %{tmp_dir: dir} do
    write(dir, "mise.toml", ~s([tools]\nelixir = "1.20.4-otp-29"\n))

    assert {output, 1} = run(@script, [], dir)
    assert output =~ "no erlang pin found"
  end
end
