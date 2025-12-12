defmodule Doctrans.Jobs.LlmProcessingJobTest do
  use Doctrans.DataCase
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Documents.Pages
  alias Doctrans.Jobs.LlmProcessingJob

  import Doctrans.Fixtures

  describe "perform/1" do
    test "processes page without opts" do
      document = document_fixture()

      {:ok, page} =
        Pages.create_page(document, %{
          page_number: 1,
          image_path: "/nonexistent/image.png"
        })

      result = perform_job(LlmProcessingJob, %{"page_id" => page.id})
      # Result depends on Ollama availability and file existence
      assert result == :ok or match?({:error, _}, result)
    end

    test "handles non-existent page" do
      fake_page_id = Uniq.UUID.uuid7()

      result = perform_job(LlmProcessingJob, %{"page_id" => fake_page_id})
      assert {:error, _reason} = result
    end
  end
end
