defmodule Doctrans.Config.DevSecret do
  @moduledoc """
  The development `secret_key_base`, generated once per machine and kept outside
  the checkout.

  Development used to carry a literal key in `config/dev.exs`. The repository is
  public, so anyone could sign with it: a LiveView session token, a cookie, and,
  while `debug_errors` was on, a `Plug.Debugger` action that applies whatever
  MFA it is handed (#333). A rotated literal would be public again the moment it
  was committed, so `config/runtime.exs` takes `SECRET_KEY_BASE` from the
  environment when it is set and otherwise asks this module, which reads the key
  from a file in the user's configuration directory, writing a fresh random one
  there on first use.

  The file is created with mode 0600 inside a 0700 directory, and with
  `:exclusive`, so two boots racing to create it agree on one key. A file that
  holds anything other than a key of the length Phoenix requires is refused by
  name rather than quietly replaced: replacing it would sign out every open tab
  without saying why, and an unreadable key is a problem the operator should see.
  """

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
      {:ok, contents} -> validate!(String.trim(contents), path)
      {:error, :enoent} -> generate!(path)
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
    end
  end

  # The same path as `secret_key_base/1`, never an upload or request value.
  # sobelow_skip ["Traversal.FileModule"]
  defp generate!(path) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    key = @random_bytes |> :crypto.strong_rand_bytes() |> Base.encode64()

    case File.open(path, [:write, :exclusive]) do
      {:ok, device} ->
        File.chmod!(path, 0o600)
        :ok = IO.binwrite(device, key)
        :ok = File.close(device)
        key

      # Another boot created it between the read and the open; use its key.
      {:error, :eexist} ->
        secret_key_base(path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create", path: path
    end
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
