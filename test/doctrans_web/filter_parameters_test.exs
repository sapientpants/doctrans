defmodule DoctransWeb.FilterParametersTest do
  # `config/config.exs` names the parameters Phoenix replaces with "[FILTERED]"
  # before logging them (#265). The LiveView logger prints every event's
  # parameters at `:debug`, which is development's level, so without this the
  # chat message and the search entry are logged as typed. Phoenix's default
  # covers only "password" and the list replaces that default, so "password"
  # has to stay on it.
  use ExUnit.Case, async: true

  setup do
    filtered =
      Phoenix.Logger.filter_values(%{
        "message" => "what does page 3 say about the merger?",
        "q" => "merger",
        "password" => "hunter2",
        "page" => "3",
        "id" => "6f2c4a4e-9a5a-4a2e-9c1a-1d2f3e4a5b6c"
      })

    %{filtered: filtered}
  end

  test "the chat message is filtered", %{filtered: filtered} do
    assert filtered["message"] == "[FILTERED]"
  end

  test "the search entry is filtered", %{filtered: filtered} do
    assert filtered["q"] == "[FILTERED]"
  end

  test "the Phoenix default is kept", %{filtered: filtered} do
    assert filtered["password"] == "[FILTERED]"
  end

  test "parameters that carry no user text are logged as they are", %{filtered: filtered} do
    assert filtered["page"] == "3"
    assert filtered["id"] == "6f2c4a4e-9a5a-4a2e-9c1a-1d2f3e4a5b6c"
  end

  test "nested parameters are filtered too" do
    assert Phoenix.Logger.filter_values(%{"chat" => %{"message" => "hello"}}) ==
             %{"chat" => %{"message" => "[FILTERED]"}}
  end
end
