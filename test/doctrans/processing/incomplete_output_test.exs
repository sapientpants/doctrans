defmodule Doctrans.Processing.IncompleteOutputTest do
  use Doctrans.DataCase, async: false

  import Doctrans.Fixtures

  alias Doctrans.Documents
  alias Doctrans.Processing.{LlmProcessor, OpenAI}
  alias Doctrans.Resilience.{CircuitBreaker, ErrorClassifier}
  alias DoctransWeb.ErrorMessages

  setup do
    bypass = Bypass.open()
    previous = Application.get_env(:doctrans, :openai)
    previous_module = Application.get_env(:doctrans, :openai_module)

    Application.put_env(:doctrans, :openai,
      base_url: "http://localhost:#{bypass.port}",
      chat_model: "test-model"
    )

    Application.put_env(:doctrans, :openai_module, OpenAI)
    CircuitBreaker.reset(:openai_api)

    document = document_fixture(%{status: "processing", total_pages: 1})
    page = page_fixture(document)
    path = Path.join(Documents.uploads_dir(), page.image_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "test image")

    on_exit(fn ->
      Application.put_env(:doctrans, :openai, previous)
      Application.put_env(:doctrans, :openai_module, previous_module)
      CircuitBreaker.reset(:openai_api)
      File.rm(path)
    end)

    %{bypass: bypass, page: page, path: path}
  end

  @invalid_choices [
    %{"finish_reason" => "length", "message" => %{"content" => "truncated text"}},
    %{"finish_reason" => "content_filter", "message" => %{"content" => "filtered text"}},
    %{"finish_reason" => "tool_calls", "message" => %{"content" => "calling tool"}},
    %{"finish_reason" => "unknown", "message" => %{"content" => "unverified"}},
    %{"finish_reason" => nil, "message" => %{"content" => "unverified"}},
    %{"message" => %{"content" => "missing completion marker"}},
    %{"finish_reason" => "stop", "message" => %{"reasoning_content" => "private reasoning"}},
    %{"finish_reason" => "stop", "message" => %{"content" => nil, "reasoning" => "reasoning"}},
    %{"finish_reason" => "stop", "message" => %{"content" => " ", "reasoning" => "reasoning"}},
    %{"finish_reason" => "stop", "message" => %{"content" => %{"text" => "invalid shape"}}},
    %{"finish_reason" => "stop", "message" => %{"content" => "<think>reasoning</think>"}},
    %{"finish_reason" => "stop", "message" => %{"content" => "<think>unfinished reasoning"}},
    %{"finish_reason" => "stop", "message" => %{"content" => "```markdown\n```"}}
  ]

  for {choice, index} <- Enum.with_index(@invalid_choices),
      stage <- [:extraction, :translation] do
    @choice choice
    @stage stage

    test "#{stage} rejects incomplete fixture #{index} without persisting output", context do
      page =
        if @stage == :translation do
          {:ok, page} =
            Documents.update_page_extraction(context.page, %{
              extraction_status: "completed",
              original_markdown: "Verified source"
            })

          page
        else
          context.page
        end

      Bypass.expect_once(context.bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"choices" => [@choice]}))
      end)

      assert {:error, {stage_error, bindings}} = LlmProcessor.process_page(page.id, MapSet.new())

      assert stage_error ==
               if(@stage == :extraction,
                 do: :page_extraction_failed,
                 else: :page_translation_failed
               )

      assert bindings[:reason] == :incomplete_output
      assert ErrorClassifier.classify(bindings[:reason]) == :permanent
      assert ErrorMessages.message({stage_error, bindings}) =~ "reprocess"

      saved = Documents.get_page!(page.id)
      assert saved.translated_markdown == nil
      assert saved.translation_status != "completed"
      assert saved.embedding == nil
      assert saved.embedding_status == "pending"
      assert Documents.get_document!(page.document_id).status != "completed"

      if @stage == :extraction do
        assert saved.original_markdown == nil
        assert saved.extraction_status == "error"
      else
        assert saved.original_markdown == "Verified source"
        assert saved.translation_status == "error"
      end
    end
  end

  for message <- [
        %{"role" => "assistant", "content" => "Final text"},
        %{"content" => "Final text", "reasoning_content" => "private reasoning"},
        %{"content" => "Final text", "reasoning" => "private reasoning"},
        %{"content" => "<think>private reasoning</think>\nFinal text"},
        %{"content" => "```markdown\nFinal text\n```"}
      ] do
    @message message

    test "accepts completed final content #{inspect(message)}", %{bypass: bypass, path: path} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"choices" => [%{"finish_reason" => "stop", "message" => @message}]})
        )
      end)

      assert {:ok, "Final text"} = OpenAI.extract_markdown(path)
      assert {:ok, "Final text"} = OpenAI.translate("source", "de", "en")
    end
  end
end
