defmodule DoctransWeb.DocumentComponentsTest do
  use ExUnit.Case, async: true

  alias DoctransWeb.DocumentLive.Components

  describe "status_color/1" do
    test "returns badge-info for uploading" do
      assert Components.status_color("uploading") == "badge-info"
    end

    test "returns badge-info for extracting" do
      assert Components.status_color("extracting") == "badge-info"
    end

    test "returns badge-info for queued" do
      assert Components.status_color("queued") == "badge-info"
    end

    test "returns badge-warning for processing" do
      assert Components.status_color("processing") == "badge-warning"
    end

    test "returns badge-success for completed" do
      assert Components.status_color("completed") == "badge-success"
    end

    test "returns badge-error for error" do
      assert Components.status_color("error") == "badge-error"
    end

    test "returns badge-ghost for unknown status" do
      assert Components.status_color("unknown") == "badge-ghost"
    end
  end

  describe "status_text/1" do
    test "returns Uploading for uploading" do
      assert Components.status_text("uploading") == "Uploading"
    end

    test "returns Processing for extracting" do
      assert Components.status_text("extracting") == "Processing"
    end

    test "returns Queued for queued" do
      assert Components.status_text("queued") == "Queued"
    end

    test "returns Processing for processing" do
      assert Components.status_text("processing") == "Processing"
    end

    test "returns Completed for completed" do
      assert Components.status_text("completed") == "Completed"
    end

    test "returns Error for error" do
      assert Components.status_text("error") == "Error"
    end

    test "returns Unknown for unknown status" do
      assert Components.status_text("unknown") == "Unknown"
    end
  end

  describe "sort_label/2" do
    test "returns Newest for inserted_at desc" do
      assert Components.sort_label(:inserted_at, :desc) == "Newest"
    end

    test "returns Oldest for inserted_at asc" do
      assert Components.sort_label(:inserted_at, :asc) == "Oldest"
    end

    test "returns A-Z for title asc" do
      assert Components.sort_label(:title, :asc) == "A-Z"
    end

    test "returns Z-A for title desc" do
      assert Components.sort_label(:title, :desc) == "Z-A"
    end

    test "returns Sort for unknown combination" do
      assert Components.sort_label(:unknown, :unknown) == "Sort"
    end
  end

  describe "language_name/1" do
    test "returns German for de" do
      assert Components.language_name("de") == "German"
    end

    test "returns English for en" do
      assert Components.language_name("en") == "English"
    end

    test "returns French for fr" do
      assert Components.language_name("fr") == "French"
    end

    test "returns Spanish for es" do
      assert Components.language_name("es") == "Spanish"
    end

    test "returns Italian for it" do
      assert Components.language_name("it") == "Italian"
    end

    test "returns Portuguese for pt" do
      assert Components.language_name("pt") == "Portuguese"
    end

    test "returns Dutch for nl" do
      assert Components.language_name("nl") == "Dutch"
    end

    test "returns Polish for pl" do
      assert Components.language_name("pl") == "Polish"
    end

    test "returns Russian for ru" do
      assert Components.language_name("ru") == "Russian"
    end

    test "returns Chinese for zh" do
      assert Components.language_name("zh") == "Chinese"
    end

    test "returns Japanese for ja" do
      assert Components.language_name("ja") == "Japanese"
    end

    test "returns Korean for ko" do
      assert Components.language_name("ko") == "Korean"
    end

    test "returns code for unknown language" do
      assert Components.language_name("xx") == "xx"
    end
  end
end
