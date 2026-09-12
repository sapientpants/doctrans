#!/usr/bin/env elixir
# Toolchain Pin Checker
# `mise.toml` is the single source of truth for the Elixir/OTP versions. CI reads it
# directly (`erlef/setup-beam` with `version-file: mise.toml`), but a Docker `FROM`
# line cannot, so `Dockerfile.dev` restates the version and this check keeps that
# restatement honest. It also requires the base image to stay pinned by digest: the
# tag is the readable half of the reference, but only the digest is immutable, and a
# bump that drops it would otherwise pass unnoticed.
#
# Usage: elixir scripts/check_toolchain_pins.exs
#
# Exit code: 1 if any pin disagrees with mise.toml, 0 otherwise

defmodule ToolchainPinChecker do
  @mise_file "mise.toml"
  @dockerfile "Dockerfile.dev"

  def run do
    {elixir_version, otp_version} = read_mise_pins()

    case check_dockerfile(elixir_version, otp_version) do
      :ok ->
        IO.puts(
          IO.ANSI.green() <>
            "Toolchain pins agree with #{@mise_file} (elixir #{elixir_version}, erlang #{otp_version})." <>
            IO.ANSI.reset()
        )

        System.halt(0)

      {:error, message} ->
        IO.puts(IO.ANSI.red() <> "Toolchain pin mismatch:" <> IO.ANSI.reset())
        IO.puts("")
        IO.puts("  " <> message)
        IO.puts("")

        IO.puts(
          IO.ANSI.yellow() <>
            "#{@mise_file} is authoritative. Update the other pin to match it." <>
            IO.ANSI.reset()
        )

        System.halt(1)
    end
  end

  # Reads the `[tools]` entries, e.g. `elixir = "1.20.4-otp-29"` and `erlang = "29.0.6"`.
  defp read_mise_pins do
    contents = read_file!(@mise_file)

    {
      extract!(contents, ~r/^\s*elixir\s*=\s*"([^"]+)"/m, "elixir"),
      extract!(contents, ~r/^\s*erlang\s*=\s*"([^"]+)"/m, "erlang")
    }
  end

  # The reference is `elixir:<tag>@sha256:<digest>`. The tag can only express the OTP
  # major (`-otp-29`), so the Elixir version is compared exactly and OTP only on its
  # major; the digest is checked for presence and shape, since verifying which image
  # it names needs a registry and this hook stays offline.
  defp check_dockerfile(elixir_version, otp_version) do
    reference = extract!(read_file!(@dockerfile), ~r/^FROM\s+elixir:(\S+)/m, "FROM elixir:")
    expected = expected_docker_tag(elixir_version, otp_version)

    case String.split(reference, "@", parts: 2) do
      [^expected, digest] ->
        check_digest(digest)

      [^expected] ->
        {:error, "#{@dockerfile} pins `elixir:#{expected}` by tag only; add an @sha256 digest"}

      [tag | _] ->
        {:error, "#{@dockerfile} pins `elixir:#{tag}`, expected `elixir:#{expected}`"}
    end
  end

  defp check_digest(digest) do
    if Regex.match?(~r/^sha256:[0-9a-f]{64}$/, digest) do
      :ok
    else
      {:error, "#{@dockerfile} pins digest `#{digest}`, which is not a sha256:<64 hex> reference"}
    end
  end

  defp expected_docker_tag(elixir_version, otp_version) do
    elixir_version
    |> String.replace(~r/-otp-\d+$/, "")
    |> Kernel.<>("-otp-#{major(otp_version)}")
  end

  defp major(version), do: version |> String.split(".") |> hd()

  defp read_file!(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, reason} -> abort("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp extract!(contents, regex, label) do
    case Regex.run(regex, contents) do
      [_, value] -> value
      nil -> abort("no #{label} pin found")
    end
  end

  defp abort(message) do
    IO.puts(IO.ANSI.red() <> "Toolchain pin check failed: #{message}" <> IO.ANSI.reset())
    System.halt(1)
  end
end

ToolchainPinChecker.run()
