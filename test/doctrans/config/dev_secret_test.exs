defmodule Doctrans.Config.DevSecretTest do
  use Doctrans.EnvCase, async: true

  import Bitwise, only: [&&&: 2]

  alias Doctrans.Config.DevSecret

  @moduletag :tmp_dir

  # Phoenix's floor for `secret_key_base`, stated here rather than read from the
  # module, so the test checks the key against Phoenix and not against itself.
  @phoenix_min_length 64

  defp key_path(tmp_dir), do: Path.join([tmp_dir, "doctrans", "dev_secret_key_base"])

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  test "generates a key Phoenix accepts and keeps it private", %{tmp_dir: tmp_dir} do
    path = key_path(tmp_dir)

    key = DevSecret.secret_key_base(path)

    assert byte_size(key) >= @phoenix_min_length
    assert File.read!(path) == key
    assert mode(path) == 0o600
    assert mode(Path.dirname(path)) == 0o700
  end

  test "leaves only the key behind, no staging file", %{tmp_dir: tmp_dir} do
    path = key_path(tmp_dir)

    DevSecret.secret_key_base(path)

    assert File.ls!(Path.dirname(path)) == [Path.basename(path)]
  end

  test "reuses the key it persisted, so sessions survive a restart", %{tmp_dir: tmp_dir} do
    path = key_path(tmp_dir)

    assert DevSecret.secret_key_base(path) == DevSecret.secret_key_base(path)
  end

  # A smoke test of the `:eexist` path: the window in which a racing boot could
  # see a half-written file is too narrow to hit on demand, which is why the key
  # is linked into place whole rather than written where it is read.
  test "boots racing to create the key agree on one", %{tmp_dir: tmp_dir} do
    path = key_path(tmp_dir)

    keys =
      1..20
      |> Task.async_stream(fn _ -> DevSecret.secret_key_base(path) end, timeout: :infinity)
      |> Enum.map(fn {:ok, key} -> key end)

    assert [key] = Enum.uniq(keys)
    assert File.read!(path) == key
  end

  test "each machine gets its own key", %{tmp_dir: tmp_dir} do
    refute DevSecret.secret_key_base(Path.join(tmp_dir, "a")) ==
             DevSecret.secret_key_base(Path.join(tmp_dir, "b"))
  end

  test "reads a key written by hand, surrounding whitespace aside", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "key")
    key = String.duplicate("c", @phoenix_min_length)
    File.write!(path, key <> "\n")

    assert DevSecret.secret_key_base(path) == key
  end

  test "narrows a key file others can read to its owner", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "key")
    File.write!(path, String.duplicate("c", @phoenix_min_length))
    File.chmod!(path, 0o644)

    DevSecret.secret_key_base(path)

    assert mode(path) == 0o600
  end

  test "leaves a key file made read-only for its owner read-only", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "key")
    File.write!(path, String.duplicate("c", @phoenix_min_length))
    File.chmod!(path, 0o444)

    DevSecret.secret_key_base(path)

    assert mode(path) == 0o400
  end

  # Replacing it would sign out every open tab without saying why.
  test "refuses a file too short to be a key rather than replacing it", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "key")
    File.write!(path, "short")

    assert_raise RuntimeError, ~r/does not hold a development secret_key_base/, fn ->
      DevSecret.secret_key_base(path)
    end

    assert File.read!(path) == "short"
  end

  test "lives outside the checkout" do
    refute String.starts_with?(DevSecret.default_path(), File.cwd!())
  end
end
