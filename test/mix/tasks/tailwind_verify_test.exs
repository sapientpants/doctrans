defmodule Mix.Tasks.Tailwind.VerifyTest do
  use Doctrans.EnvCase, async: true

  alias Mix.Tasks.Tailwind.Verify

  @moduletag :tmp_dir

  @target "macos-arm64"
  @every_target ~w(
    linux-arm64 linux-arm64-musl linux-x64 linux-x64-musl macos-arm64 macos-x64 windows-x64.exe
  )

  setup %{tmp_dir: dir} do
    bin_path = Path.join(dir, "tailwind-#{@target}-9.9.9")
    File.write!(bin_path, "not really a binary")
    %{bin_path: bin_path, sums_path: Path.join(dir, "tailwind-9.9.9.sha256sums")}
  end

  defp sha256(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  test "accepts the binary whose digest the release file lists", ctx do
    File.write!(ctx.sums_path, """
    0000000000000000000000000000000000000000000000000000000000000000  ./tailwindcss-linux-x64
    #{sha256(ctx.bin_path)}  ./tailwindcss-#{@target}
    """)

    assert :ok = Verify.verify(ctx.bin_path, @target, ctx.sums_path)
    assert File.exists?(ctx.bin_path)
  end

  test "reads the plain and binary-mode spellings sha256sum writes", ctx do
    File.write!(ctx.sums_path, "#{String.upcase(sha256(ctx.bin_path))} *tailwindcss-#{@target}\n")

    assert :ok = Verify.verify(ctx.bin_path, @target, ctx.sums_path)
  end

  test "deletes a binary that does not match and says what it saw", ctx do
    expected = String.duplicate("ab", 32)
    File.write!(ctx.sums_path, "#{expected}  ./tailwindcss-#{@target}\n")

    assert {:error, message} = Verify.verify(ctx.bin_path, @target, ctx.sums_path)
    assert message =~ "does not match"
    assert message =~ expected
    assert message =~ sha256_of_fixture()
    assert message =~ "has been deleted"
    refute File.exists?(ctx.bin_path)
  end

  test "fails without touching the binary when the file has no entry for the target", ctx do
    File.write!(ctx.sums_path, "#{sha256(ctx.bin_path)}  ./tailwindcss-linux-x64\n")

    assert {:error, message} = Verify.verify(ctx.bin_path, @target, ctx.sums_path)
    assert message =~ "no digest for tailwindcss-#{@target}"
    assert File.exists?(ctx.bin_path)
  end

  test "fails when there is no digest file for the version", ctx do
    assert {:error, message} = Verify.verify(ctx.bin_path, @target, ctx.sums_path)
    assert message =~ "cannot read #{ctx.sums_path}"
    assert message =~ "sha256sums.txt"
    assert File.exists?(ctx.bin_path)
  end

  test "fails when the binary has not been installed", ctx do
    File.write!(ctx.sums_path, "#{sha256(ctx.bin_path)}  ./tailwindcss-#{@target}\n")
    File.rm!(ctx.bin_path)

    assert {:error, message} = Verify.verify(ctx.bin_path, @target, ctx.sums_path)
    assert message =~ "no binary at #{ctx.bin_path}"
  end

  # A version bump in config.exs has to come with the new release's file, and
  # that file has to cover every target the installer can choose, or one
  # platform would install unverified.
  test "the pinned version has a committed digest for every installer target" do
    sums_path = Verify.sums_path(Tailwind.configured_version())
    assert File.exists?(sums_path), "missing #{sums_path}; see `mix help tailwind.verify`"

    contents = File.read!(sums_path)

    for target <- @every_target do
      assert contents =~ ~r/^[0-9a-f]{64}  \.\/tailwindcss-#{Regex.escape(target)}$/m,
             "#{Path.basename(sums_path)} has no digest for tailwindcss-#{target}"
    end
  end

  defp sha256_of_fixture do
    "not really a binary" |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
