defmodule Doctrans.Config.DevSecret do
  @moduledoc """
  The development `secret_key_base`, generated once per machine and kept outside
  the checkout.

  Development used to carry a literal key in `config/dev.exs`. The repository is
  public, so anyone could sign with it: a LiveView session token, a cookie, and
  the `Plug.Debugger` action `config/dev.exs` explains (#333). A rotated literal
  would be public again the moment it was committed, so `config/runtime.exs`
  takes `SECRET_KEY_BASE` from the environment when it is set and otherwise asks
  this module, which reads the key from a file in the user's configuration
  directory, writing a fresh random one there on first use.

  The key is written whole under a private name in a 0700 directory, with mode
  0600, and then hard-linked into place. A link never replaces an existing file,
  so the key file appears complete or not at all, and of two boots racing to
  create it the one that links second reads the other's key. A file that holds
  anything other than a key of the length Phoenix requires is refused by name
  rather than quietly replaced: replacing it would sign out every open tab
  without saying why, and an unreadable key is a problem the operator should
  see. An existing file readable by anyone but its owner is narrowed to the
  owner.
  """

  import Bitwise, only: [&&&: 2]

  # Phoenix refuses a `secret_key_base` shorter than 64 bytes; 48 random bytes
  # encode to exactly 64 characters of Base64.
  @min_length 64
  @random_bytes 48

  @doc """
  Where the key is kept: `doctrans/dev_secret_key_base` under the user's
  configuration directory (`~/Library/Application Support` on macOS,
  `$XDG_CONFIG_HOME` or `~/.config` on Linux).
  """
  @spec default_path() :: Path.t()
  def default_path do
    Path.join(:filename.basedir(:user_config, "doctrans"), "dev_secret_key_base")
  end

  @doc "Reads the key at `path`, generating and persisting one when there is none."
  @spec secret_key_base(Path.t()) :: String.t()
  # The path is `default_path/0` or a test's tmp dir, never an upload or request value.
  # sobelow_skip ["Traversal.FileModule"]
  def secret_key_base(path \\ default_path()) do
    case File.read(path) do
      {:ok, contents} ->
        key = validate!(String.trim(contents), path)
        owner_only!(path)
        key

      {:error, :enoent} ->
        generate!(path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: path
    end
  end

  # The same path as `secret_key_base/1`, never an upload or request value.
  # sobelow_skip ["Traversal.FileModule"]
  defp generate!(path) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    key = @random_bytes |> :crypto.strong_rand_bytes() |> Base.encode64()
    staging = "#{path}.#{6 |> :crypto.strong_rand_bytes() |> Base.url_encode64()}.tmp"

    try do
      write_private!(staging, key)

      case File.ln(staging, path) do
        :ok -> key
        # Another boot linked its key first; use that one.
        {:error, :eexist} -> secret_key_base(path)
        {:error, reason} -> raise File.Error, reason: reason, action: "link", path: path
      end
    after
      File.rm(staging)
    end
  end

  # The same path as `secret_key_base/1`, never an upload or request value.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_private!(path, contents) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, device} ->
        File.chmod!(path, 0o600)
        :ok = IO.binwrite(device, contents)
        :ok = File.close(device)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create", path: path
    end
  end

  # Clears the group and other bits and keeps the owner's, so a key a developer
  # made read-only stays read-only. The same path as `secret_key_base/1`.
  # sobelow_skip ["Traversal.FileModule"]
  defp owner_only!(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    if (mode &&& 0o077) != 0, do: File.chmod!(path, mode &&& 0o700)
  end

  defp validate!(key, path) do
    if byte_size(key) >= @min_length do
      key
    else
      raise "#{path} does not hold a development secret_key_base of at least " <>
              "#{@min_length} characters. Delete it to have a new one generated on " <>
              "the next boot, or set SECRET_KEY_BASE (generate one with mix phx.gen.secret)."
    end
  end
end
