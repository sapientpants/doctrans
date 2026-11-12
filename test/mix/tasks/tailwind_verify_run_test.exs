defmodule Mix.Tasks.Tailwind.VerifyRunTest do
  # `:tailwind :path` is VM-global application env, so this file overrides it
  # through `TestEnv.put_env/3` and cannot run alongside the other tests.
  use Doctrans.EnvCase, async: false

  import ExUnit.CaptureIO

  alias Doctrans.TestEnv
  alias Mix.Tasks.Tailwind.Verify

  test "a binary supplied through :path is reported and left alone" do
    TestEnv.put_env(:tailwind, :path, "/opt/somewhere/tailwindcss")

    output = capture_io(fn -> Verify.run([]) end)

    assert output =~ "skipped"
    assert output =~ ":path"
  end

  test "rejects options it does not know" do
    assert_raise OptionParser.ParseError, fn -> Verify.run(["--if-missing"]) end
  end
end
