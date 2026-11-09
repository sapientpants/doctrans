defmodule DoctransWeb.FilterParametersTest do
  # `config/config.exs` names the parameters Phoenix replaces with "[FILTERED]"
  # before logging them, and says why (#265). This file pins what that list
  # does, through the function Phoenix's controller logger and the LiveView
  # logger both call before writing a parameter. `Phoenix.Logger.filter_values/1`
  # is public but `@doc false`, so a Phoenix release that renames it breaks this
  # file, not the application; its default argument reads the application
  # environment at call time, so these tests exercise the configured list.
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

  test "the search query is filtered", %{filtered: filtered} do
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

  # Each entry is a substring. Phoenix filters any key containing the term and
  # any string value containing the term followed by "=", so the one-letter "q"
  # reaches further than the search form. Both reaches are accepted
  # over-filtering, pinned here so they stay a documented choice.
  test "an entry matches as a substring of the key, not as the exact key" do
    assert Phoenix.Logger.filter_values(%{"request_logger" => "abc"}) ==
             %{"request_logger" => "[FILTERED]"}
  end

  test "a value carrying a filtered term as a query-string key is filtered" do
    assert Phoenix.Logger.filter_values(%{"return_to" => "/search?q=merger"}) ==
             %{"return_to" => "[FILTERED]"}
  end
end
