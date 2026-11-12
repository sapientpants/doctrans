defmodule Mix.Tasks.Tailwind.Verify do
  @moduledoc """
  Checks the installed Tailwind binary against its pinned SHA-256 digest.

  `mix tailwind.install` downloads the standalone CLI from a GitHub release
  over TLS and makes it executable without comparing it to anything, while
  esbuild's installer verifies an npm signature and a sha512 integrity
  value. This task closes that gap for the half that has none (#274): it
  hashes the binary `mix tailwind.install` put in place and compares the
  result with the digest tailwindlabs publishes for the release, which is
  committed to this repository so that a download, a restored CI cache and
  a Docker build layer are all held to the same value.

  The digests live in `config/tailwind-<version>.sha256sums`, next to the
  version pin in `config/config.exs`. The file is the release's
  `sha256sums.txt`, so bumping the version means adding the new release's
  file and the old one can be deleted:

      curl -fsSLO https://github.com/tailwindlabs/tailwindcss/releases/download/v<version>/sha256sums.txt
      mv sha256sums.txt config/tailwind-<version>.sha256sums

  The parser reads what `sha256sum` writes, in plain or binary (`*name`)
  mode, with or without a `./` prefix, so a file produced by hand from a
  release's assets is read the same way as the published one. A version
  without a digest file fails this task rather than passing with nothing to
  compare against.

  On a mismatch the binary is **deleted** before the task fails, so the
  next `mix assets.setup` fetches it again instead of running whatever was
  on disk. A second failure on the same version means the published asset
  no longer matches the pinned digest, and that is worth looking into
  before anything is re-pinned.

  Configuring `config :tailwind, :path` bypasses the download altogether:
  that binary is one you supplied, so the task reports it and does nothing.

  ## Usage

      mix tailwind.verify
      mix tailwind.verify --install

  Without options the task only checks, and a missing binary is a failure.

  With `--install` it stands in for `tailwind.install --if-missing`: a
  binary already on disk is hashed first and kept when it matches, deleted
  when it does not, and only when there is none is `mix tailwind.install`
  run and its download hashed in turn. The order matters: `tailwind.install`
  decides whether the binary is current by *running* it (`tailwindcss
  --help`), with or without `--if-missing`, so a stale `_build` or a
  restored cache has to be checked before that task gets to it. This is
  what `mix assets.setup` runs.
  """

  use Mix.Task

  @shortdoc "Check the Tailwind binary against its pinned SHA-256 digest"

  @chunk_bytes 1_048_576

  @impl true
  def run(args) do
    {opts, []} = OptionParser.parse!(args, strict: [install: :boolean])

    # Only `loadpaths`, as `tailwind.install` does without `--runtime-config`:
    # the version and target come from `config/config.exs`, which Mix has
    # loaded by now, and `app.config` would evaluate `config/runtime.exs`,
    # which under MIX_ENV=prod demands DATABASE_URL in a build that has none.
    Mix.Task.run("loadpaths")

    if Application.get_env(:tailwind, :path) do
      Mix.shell().info(
        "tailwind.verify: skipped, :tailwind :path names a binary this project did not download"
      )
    else
      check_configured(Tailwind.configured_version(), opts[:install] == true)
    end
  end

  defp check_configured(version, install?) do
    bin_path = Tailwind.bin_path(version)
    target = Tailwind.configured_target()
    sums_path = sums_path(version)

    result =
      if install?,
        do: verify_or_install(bin_path, target, sums_path, &install_tailwind/0),
        else: verify(bin_path, target, sums_path)

    case result do
      :ok ->
        Mix.shell().info(
          "tailwind.verify: #{Path.basename(bin_path)} matches the pinned digest for v#{version}"
        )

      {:error, message} ->
        Mix.raise(message)
    end
  end

  # `rerun` rather than `run`, so the download still happens when an earlier
  # task in the same `mix` invocation has already run `tailwind.install`.
  defp install_tailwind, do: Mix.Task.rerun("tailwind.install")

  @doc """
  The digest file for `version`: `config/tailwind-<version>.sha256sums`.
  """
  @spec sums_path(String.t()) :: Path.t()
  def sums_path(version) do
    Path.join([File.cwd!(), "config", "tailwind-#{version}.sha256sums"])
  end

  @doc """
  Compares the SHA-256 of the binary at `bin_path` with the entry for
  `tailwindcss-<target>` in the digest file at `sums_path`.

  Returns `:ok` when they agree. Otherwise the binary is deleted when it
  was the one that disagreed, and the reason comes back as a message ready
  to be raised.
  """
  @spec verify(Path.t(), String.t(), Path.t()) :: :ok | {:error, String.t()}
  def verify(bin_path, target, sums_path) do
    with {:ok, expected} <- expected_digest(sums_path, target),
         {:ok, actual} <- actual_digest(bin_path) do
      compare(bin_path, target, expected, actual, :on_disk)
    end
  end

  @doc """
  Like `verify/3`, but when there is no binary at `bin_path` it calls
  `install` to put one there and verifies that instead.

  A binary that is already on disk is hashed before `install` is called,
  never after, so nothing unverified is handed to a step that would run it.
  The pinned digest has to be readable before anything is downloaded: with
  no digest to compare against, there is no point fetching a binary.
  """
  @spec verify_or_install(Path.t(), String.t(), Path.t(), (-> any())) ::
          :ok | {:error, String.t()}
  def verify_or_install(bin_path, target, sums_path, install) when is_function(install, 0) do
    with {:ok, expected} <- expected_digest(sums_path, target),
         {:ok, actual, origin} <- present_or_installed(bin_path, install) do
      compare(bin_path, target, expected, actual, origin)
    end
  end

  defp present_or_installed(bin_path, install) do
    origin =
      if File.regular?(bin_path) do
        :on_disk
      else
        install.()
        :downloaded
      end

    with {:ok, actual} <- actual_digest(bin_path), do: {:ok, actual, origin}
  end

  defp compare(_bin_path, _target, expected, expected, _origin), do: :ok

  defp compare(bin_path, target, expected, actual, origin),
    do: reject(bin_path, target, expected, actual, origin)

  defp expected_digest(sums_path, target) do
    asset = "tailwindcss-#{target}"

    case File.read(sums_path) do
      {:ok, contents} ->
        contents
        |> parse_sums()
        |> Map.fetch(asset)
        |> case do
          {:ok, digest} ->
            {:ok, digest}

          :error ->
            {:error,
             "tailwind.verify: #{sums_path} has no digest for #{asset}; " <>
               "it should be the release's sha256sums.txt, which lists every target"}
        end

      {:error, reason} ->
        {:error,
         "tailwind.verify: cannot read #{sums_path} (#{:file.format_error(reason)}). " <>
           "Pin the release's sha256sums.txt there before installing this version " <>
           "(see `mix help tailwind.verify`)"}
    end
  end

  # One `<hex>  <name>` pair per line, as `sha256sum` writes them and as the
  # release publishes them. `./` and the `*` binary-mode marker are dropped
  # from the name so the file can be committed verbatim.
  defp parse_sums(contents) do
    for line <- String.split(contents, ~r/\r?\n/),
        [digest, name] <- [String.split(line, ~r/\s+\*?/, parts: 2, trim: true)],
        into: %{} do
      {name |> String.trim() |> String.replace_prefix("./", ""), String.downcase(digest)}
    end
  end

  defp actual_digest(bin_path) do
    if File.regular?(bin_path) do
      digest =
        bin_path
        |> File.stream!(@chunk_bytes)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, digest}
    else
      {:error,
       "tailwind.verify: no binary at #{bin_path}; run `mix tailwind.install` first " <>
         "(`mix assets.setup` does both)"}
    end
  end

  # The binary goes before the failure is reported, so that the next
  # `assets.setup` has to fetch it again: left in place, `mix tailwind`
  # would run it regardless, since that task only checks the file exists.
  # The path is the installer's own under `_build`, never input.
  # sobelow_skip ["Traversal.FileModule"]
  defp reject(bin_path, target, expected, actual, origin) do
    removal =
      case File.rm(bin_path) do
        :ok -> "It has been deleted."
        {:error, reason} -> "It could not be deleted (#{:file.format_error(reason)}): remove it."
      end

    {:error,
     """
     tailwind.verify: #{bin_path} does not match the pinned digest for tailwindcss-#{target}.

         expected #{expected}
         got      #{actual}

     #{removal} #{advice(origin)}
     """}
  end

  defp advice(:on_disk) do
    "Run `mix assets.setup` to fetch it again. A binary that fails again after a " <>
      "fresh download no longer matches the published release, which is worth " <>
      "investigating before the digest is changed."
  end

  defp advice(:downloaded) do
    "This was a fresh download, so the published asset no longer matches the pinned " <>
      "digest: compare the file under config/ with the release's sha256sums.txt and " <>
      "find out which one changed before re-pinning."
  end
end
