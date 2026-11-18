defmodule Doctrans.Config.DevSecretTest do
  use Doctrans.EnvCase, async: true

  import Bitwise, only: [&&&: 2]

  alias Doctrans.Config.DevSecret

  @moduletag :tmp_dir

  defp key_path(tmp_dir), do: Path.join([tmp_dir, "doctrans", "dev_secret_key_base"])

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  test "generates a key Phoenix accepts and keeps it private", %{tmp_dir: tmp_dir} do
    path = key_path(tmp_dir)

    key = DevSecret.secret_key_base(path)

    assert byte_size(key) >= 64
    assert File.read!(path) == key
    assert mode(path) == 0o600
    assert mode(Path.dirname(path)) == 0o700
  end

  test "reuses the key it persisted, so sessions survive a restart", %{tmp_dir: tmp_dir} do
    path = key_path(tmp_dir)

    assert DevSecret.secret_key_base(path) == DevSecret.secret_key_base(path)
  end

  test "each machine gets its own key", %{tmp_dir: tmp_dir} do
    refute DevSecret.secret_key_base(Path.join(tmp_dir, "a")) ==
             DevSecret.secret_key_base(Path.join(tmp_dir, "b"))
  end

  test "reads a key written by hand, surrounding whitespace aside", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "key")
    key = String.duplicate("c", 64)
    File.write!(path, key <> "\n")

    assert DevSecret.secret_key_base(path) == key
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
