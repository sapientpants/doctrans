defmodule DoctransWeb.DocumentLive.PageContentTest do
  use DoctransWeb.ConnCase, async: true

  alias DoctransWeb.DocumentLive.ViewerComponents

  @states ~w(no_page pending extracting waiting_translation translating error content)a

  defp page(attrs) do
    Map.merge(
      %{
        extraction_status: "completed",
        translation_status: "completed",
        original_markdown: "# Original",
        translated_markdown: "# Translated"
      },
      attrs
    )
  end

  defp render(page, show_original) do
    html =
      render_component(&ViewerComponents.page_content/1, page: page, show_original: show_original)

    document = LazyHTML.from_fragment(html)
    root = LazyHTML.query(document, "#page-content")
    {LazyHTML.attribute(root, "data-page-state"), LazyHTML.query(document, "#page-content > *")}
  end

  describe "the panel renders exactly one block" do
    test "a failed translation does not stack the error on top of the original text" do
      page = page(%{translation_status: "error"})

      {["content"], blocks} = render(page, true)
      assert Enum.count(blocks) == 1
      assert LazyHTML.text(blocks) =~ "Original"
    end

    test "a translation that has not started yet is reported instead of an empty panel" do
      page = page(%{translation_status: "pending", translated_markdown: nil})

      {["waiting_translation"], blocks} = render(page, false)
      assert Enum.count(blocks) == 1
      assert LazyHTML.text(blocks) =~ "Waiting"
    end

    test "every state renders a single block" do
      for extraction <- ~w(pending processing completed error),
          translation <- ~w(pending processing completed error),
          show_original <- [true, false] do
        page = page(%{extraction_status: extraction, translation_status: translation})
        {[state], blocks} = render(page, show_original)

        assert String.to_existing_atom(state) in @states

        assert Enum.count(blocks) == 1,
               "#{extraction}/#{translation}/#{show_original} rendered #{Enum.count(blocks)} blocks"
      end

      {["no_page"], blocks} = render(nil, false)
      assert Enum.count(blocks) == 1
    end
  end

  describe "page_state/2" do
    test "extraction progress is reported regardless of the toggle" do
      for show_original <- [true, false] do
        assert ViewerComponents.page_state(page(%{extraction_status: "pending"}), show_original) ==
                 :pending

        assert ViewerComponents.page_state(
                 page(%{extraction_status: "processing"}),
                 show_original
               ) == :extracting

        assert ViewerComponents.page_state(page(%{extraction_status: "error"}), show_original) ==
                 :error
      end
    end

    test "showing the original only needs extraction to have completed" do
      for translation <- ~w(pending processing completed error) do
        assert ViewerComponents.page_state(page(%{translation_status: translation}), true) ==
                 :content
      end
    end

    test "showing the translation follows the translation pipeline" do
      assert ViewerComponents.page_state(page(%{translation_status: "pending"}), false) ==
               :waiting_translation

      assert ViewerComponents.page_state(page(%{translation_status: "processing"}), false) ==
               :translating

      assert ViewerComponents.page_state(page(%{translation_status: "error"}), false) == :error

      assert ViewerComponents.page_state(page(%{translation_status: "completed"}), false) ==
               :content
    end

    test "no page selected" do
      assert ViewerComponents.page_state(nil, true) == :no_page
    end
  end
end
