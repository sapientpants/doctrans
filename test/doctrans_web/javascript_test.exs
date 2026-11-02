defmodule DoctransWeb.JavaScriptTest do
  @moduledoc """
  Runs the Node test files under `test/js`, which execute the real modules in
  `assets/js` -- the theme bundle, and the LiveView hooks whose behaviour the
  LiveView tests can only declare -- against the browser fakes in
  `test/js/fake_dom.mjs`.

  Every `*_test.mjs` in the directory runs, so a new file is picked up without
  being named here; the files known to exist are checked for so a glob that
  matched nothing cannot pass in silence.
  """
  use ExUnit.Case, async: true

  @js_dir Path.expand("../js", __DIR__)
  @known_tests ~w(theme_test.mjs chat_scroll_test.mjs dialog_focus_test.mjs)

  test "every JavaScript test file passes" do
    node = System.find_executable("node") || flunk("Node.js is required for the JavaScript tests")
    files = Path.wildcard(Path.join(@js_dir, "*_test.mjs"))

    for known <- @known_tests do
      assert Path.join(@js_dir, known) in files, "#{known} is missing from #{@js_dir}"
    end

    # System.cmd inherits the VM's environment even with env: []. Keep only
    # runtime basics; credentials and Node preload options must not reach it.
    env =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&(&1 in ~w(PATH TMPDIR TMP TEMP LANG LC_ALL TZ SystemRoot WINDIR)))
      |> Enum.map(&{&1, nil})

    {output, status} =
      System.cmd(node, ["--experimental-vm-modules", "--test" | files],
        stderr_to_stdout: true,
        env: env
      )

    assert status == 0, output
  end
end
