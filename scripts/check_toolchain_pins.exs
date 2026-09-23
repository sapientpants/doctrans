#!/usr/bin/env elixir
# Toolchain Pin Checker
# `mise.toml` is the single source of truth for the Elixir/OTP versions. CI reads it
# directly (`erlef/setup-beam` with `version-file: mise.toml`), but a Docker `FROM`
# line cannot, so `Dockerfile.dev` and `Dockerfile` each restate the version and this
# check keeps both restatements honest. It also requires *every* base image in both
# files to stay pinned by digest — the builder and the production runtime base alike:
# the tag is the readable half of the reference, but only the digest is immutable, and
# a bump that drops it would otherwise pass unnoticed. A runtime base that drifts is
# exactly as unreproducible as a builder that does.
#
# Usage: elixir scripts/check_toolchain_pins.exs
#
# Exit code: 1 if any pin disagrees with mise.toml or is missing a digest, 0 otherwise

defmodule ToolchainPinChecker do
  @mise_file "mise.toml"
  @dockerfiles ["Dockerfile.dev", "Dockerfile"]

  def run do
    {elixir_version, otp_version} = read_mise_pins()
    expected = expected_docker_tag(elixir_version, otp_version)

    case Enum.find_value(@dockerfiles, &check_dockerfile(&1, expected)) do
      nil ->
        IO.puts(
          IO.ANSI.green() <>
            "Toolchain pins agree with #{@mise_file} (elixir #{elixir_version}, erlang #{otp_version}), " <>
            "and every base image in #{Enum.join(@dockerfiles, ", ")} is digest-pinned." <>
            IO.ANSI.reset()
        )

        System.halt(0)

      message ->
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

  # Returns the first problem found in `path`, or nil when every `FROM` is acceptable.
  defp check_dockerfile(path, expected) do
    references = base_references!(path)

    # The version check below only fires on an `elixir:` reference, so a file that
    # stopped using that base — a different registry, a different image — would
    # pass in silence, which is the drift this script exists to prevent.
    if Enum.any?(references, &String.starts_with?(&1, "elixir:")) do
      Enum.find_value(references, &check_reference(path, &1, expected))
    else
      "#{path} has no `FROM elixir:` base to check against #{@mise_file}"
    end
  end

  # The references a `FROM` names, minus the ones naming an earlier stage of the same
  # file (`COPY --from=builder`'s counterpart): a stage name has no registry digest to
  # pin and requiring one would be a false positive.
  defp base_references!(path) do
    contents = read_file!(path)

    stages =
      ~r/^FROM\s+\S+\s+AS\s+(\S+)/mi
      |> Regex.scan(contents, capture: :all_but_first)
      |> List.flatten()

    references =
      ~r/^FROM\s+(\S+)/mi
      |> Regex.scan(contents, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&(&1 in stages))

    if references == [], do: abort("no base image FROM instruction found in #{path}")

    references
  end

  # A reference is `<image>:<tag>@sha256:<digest>`. The tag can only express the OTP
  # major (`-otp-29`), so the Elixir version is compared exactly and OTP only on its
  # major; the digest is checked for presence and shape, since verifying which image
  # it names needs a registry and this hook stays offline.
  defp check_reference(path, reference, expected) do
    case String.split(reference, "@", parts: 2) do
      [tagged, digest] -> check_tag(path, tagged, expected) || check_digest(path, digest)
      [tagged] -> "#{path} pins `#{tagged}` by tag only; add an @sha256 digest"
    end
  end

  defp check_tag(path, "elixir:" <> tag, expected) when tag != expected do
    "#{path} pins `elixir:#{tag}`, expected `elixir:#{expected}`"
  end

  defp check_tag(_path, _tagged, _expected), do: nil

  defp check_digest(path, digest) do
    if Regex.match?(~r/^sha256:[0-9a-f]{64}$/, digest) do
      nil
    else
      "#{path} pins digest `#{digest}`, which is not a sha256:<64 hex> reference"
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
