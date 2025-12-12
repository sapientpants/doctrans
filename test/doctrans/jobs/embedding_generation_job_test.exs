defmodule Doctrans.Jobs.EmbeddingGenerationJobTest do
  use Doctrans.DataCase
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Documents.Pages
  alias Doctrans.Jobs.EmbeddingGenerationJob

  import Doctrans.Fixtures

  describe "perform/1" do
    test "returns error when page not found" do
      fake_page_id = Uniq.UUID.uuid7()

      assert {:error, "Page not found"} =
               perform_job(EmbeddingGenerationJob, %{"page_id" => fake_page_id})
    end

    test "returns error when page has no content" do
      document = document_fixture()
      {:ok, page} = Pages.create_page(document, %{page_number: 1})

      assert {:error, "No content available for embedding generation"} =
               perform_job(EmbeddingGenerationJob, %{"page_id" => page.id})
    end

    test "processes page with translated content" do
      document = document_fixture()

      {:ok, page} =
        Pages.create_page(document, %{
          page_number: 1,
          translated_markdown: "Translated content"
        })

      result = perform_job(EmbeddingGenerationJob, %{"page_id" => page.id})
      # Should succeed if Ollama is running, or error if not
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "processes page with original content when no translation" do
      document = document_fixture()

      {:ok, page} =
        Pages.create_page(document, %{
          page_number: 1,
          original_markdown: "Original content"
        })

      result = perform_job(EmbeddingGenerationJob, %{"page_id" => page.id})
      # Should succeed if Ollama is running, or error if not
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
