defmodule Doctrans.Processing.Executable do
  @moduledoc """
  Resolves the path of an external processing tool.

  Every processing command resolves the same way, so a poppler installed where
  LibreOffice would be found is found too:

    1. an explicitly configured path, when it points at an executable regular file
    2. the first match on `PATH`
    3. the known absolute install locations for the supported platforms

  `PATH` comes before the known locations so that a deliberately installed tool
  wins over a system one, and so a caller can point the app at a specific build.
  The known locations exist for the opposite case: a daemon started with a slim
  `PATH` that does not include Homebrew's, where the tool is installed but not
  visible.
  """

  @doc """
  Returns `{:ok, absolute_path}` for `name`, or `:error` when nothing matches.

  ## Options

  - `:configured` - an explicit path that wins when it is executable
  - `:candidates` - absolute paths to fall back to when `PATH` has no match
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | :error
  def resolve(name, opts \\ []) do
    configured = Keyword.get(opts, :configured)
    candidates = Keyword.get(opts, :candidates, [])

    found =
      if executable_file?(configured) do
        configured
      else
        find_on_path(name) || Enum.find(candidates, &absolute_executable?/1)
      end

    case found do
      nil -> :error
      path -> {:ok, Path.expand(path)}
    end
  end

  @doc "Returns true when `path` points at an existing, executable regular file."
  @spec executable_file?(term()) :: boolean()
  def executable_file?(path) do
    case is_binary(path) && File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> :erlang.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp absolute_executable?(path),
    do: is_binary(path) and Path.type(path) == :absolute and executable_file?(path)

  # Searches the directories in the current `PATH`, honouring whatever PATH the
  # process environment holds at call time.
  defp find_on_path(name) do
    separator =
      case :os.type() do
        {:win32, _} -> ";"
        _other -> ":"
      end

    "PATH"
    |> System.get_env("")
    |> String.split(separator, trim: false)
    |> Enum.map(fn dir -> Path.join(dir, name) end)
    |> Enum.find(&executable_file?/1)
  end
end
