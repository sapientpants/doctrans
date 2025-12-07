defmodule DoctransWeb.DocumentLive.ComponentsTest do
  use ExUnit.Case, async: true

  alias DoctransWeb.DocumentLive.Components

  describe "status_color/1" do
    test "returns correct color for all statuses" do
      assert Components.status_color("uploading") == "badge-info"
      assert Components.status_color("extracting") == "badge-info"
      assert Components.status_color("queued") == "badge-info"
      assert Components.status_color("processing") == "badge-warning"
      assert Components.status_color("completed") == "badge-success"
      assert Components.status_color("error") == "badge-error"
      assert Components.status_color("unknown") == "badge-ghost"
    end
  end

  describe "status_text/1" do
    test "returns correct text for all statuses" do
      assert Components.status_text("uploading") == "Uploading"
      assert Components.status_text("extracting") == "Processing"
      assert Components.status_text("queued") == "Queued"
      assert Components.status_text("processing") == "Processing"
      assert Components.status_text("completed") == "Completed"
      assert Components.status_text("error") == "Error"
      assert Components.status_text("unknown") == "Unknown"
    end
  end

  describe "sort_label/2" do
    test "returns correct label for all sort combinations" do
      assert Components.sort_label(:inserted_at, :desc) == "Newest"
      assert Components.sort_label(:inserted_at, :asc) == "Oldest"
      assert Components.sort_label(:title, :asc) == "A-Z"
      assert Components.sort_label(:title, :desc) == "Z-A"
      assert Components.sort_label(:other, :other) == "Sort"
    end
  end

  describe "language_name/1" do
    test "returns correct name for all language codes" do
      assert Components.language_name("de") == "German"
      assert Components.language_name("en") == "English"
      assert Components.language_name("fr") == "French"
      assert Components.language_name("es") == "Spanish"
      assert Components.language_name("it") == "Italian"
      assert Components.language_name("pt") == "Portuguese"
      assert Components.language_name("nl") == "Dutch"
      assert Components.language_name("pl") == "Polish"
      assert Components.language_name("ru") == "Russian"
      assert Components.language_name("zh") == "Chinese"
      assert Components.language_name("ja") == "Japanese"
      assert Components.language_name("ko") == "Korean"
      assert Components.language_name("xx") == "xx"
    end
  end
end
