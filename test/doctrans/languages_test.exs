defmodule Doctrans.LanguagesTest do
  use ExUnit.Case, async: true

  alias Doctrans.Languages

  test "every supported code has exactly one name, in the same order" do
    assert Enum.map(Languages.names(), &elem(&1, 0)) == Languages.supported()
    assert Enum.uniq(Languages.supported()) == Languages.supported()
  end

  test "names are non-empty English msgids" do
    for {code, name} <- Languages.names() do
      assert String.length(code) == 2
      assert name =~ ~r/^[A-Z][a-z]+$/
    end
  end

  test "supported?/1 follows the list" do
    for code <- Languages.supported(), do: assert(Languages.supported?(code))
    refute Languages.supported?("xx")
    refute Languages.supported?(nil)
  end
end
