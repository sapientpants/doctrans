defmodule DoctransWeb.AsyncFailureTest do
  use ExUnit.Case, async: true

  alias DoctransWeb.AsyncFailure

  test "classifies expected exits without including attached payloads" do
    for reason <- [:normal, :shutdown, :killed, :timeout, :noproc] do
      assert AsyncFailure.summary(reason) == Atom.to_string(reason)
    end

    assert AsyncFailure.summary({:shutdown, "sk-secret"}) == "shutdown"
    assert AsyncFailure.summary(%{authorization: "sk-secret"}) == "unexpected task failure"

    assert AsyncFailure.summary({%{__exception__: true, __struct__: "sk-secret"}, []}) ==
             "unexpected task failure"

    assert AsyncFailure.summary("https://user:password@host/?key=private") ==
             "unexpected task failure"
  end
end
