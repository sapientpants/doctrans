defmodule Doctrans.ConfigTest do
  use ExUnit.Case, async: false

  alias Doctrans.Config.{Embedding, OpenAI, Uploads}
  alias Doctrans.Processing.PdfProcessor

  setup do
    previous =
      Map.new([:openai, :embedding, :uploads], &{&1, Application.fetch_env!(:doctrans, &1)})

    on_exit(fn ->
      for {key, value} <- previous, do: Application.put_env(:doctrans, key, value)
    end)

    :ok
  end

  test "reads current settings, including distinct models and timeouts" do
    Application.put_env(:doctrans, :openai,
      base_url: "http://llm:8000",
      api_key: "test-key",
      vision_model: "vision",
      chat_model: "chat",
      translation_model: "translation",
      timeout: 1234
    )

    assert OpenAI.base_url() == "http://llm:8000"
    assert OpenAI.api_key() == "test-key"
    assert OpenAI.vision_model() == "vision"
    assert OpenAI.chat_model() == "chat"
    assert OpenAI.translation_model() == "translation"
    assert OpenAI.timeout() == 1234

    Application.put_env(:doctrans, :openai, chat_model: "changed")
    assert OpenAI.chat_model() == "changed"
    assert OpenAI.vision_model() == "changed"
    assert OpenAI.translation_model() == "changed"
    assert OpenAI.api_key() == nil
    assert OpenAI.timeout() == 300_000

    Application.put_env(:doctrans, :openai, vision_model: "vision-only")
    assert OpenAI.chat_model() == "vision-only"
  end

  test "embedding shares the API endpoint unless explicitly configured" do
    Application.put_env(:doctrans, :openai, base_url: "http://llm:8000", chat_model: "chat")
    Application.put_env(:doctrans, :embedding, base_url: nil)
    assert Embedding.base_url() == "http://llm:8000"
    assert Embedding.model() == "chat"
    assert Embedding.api_key() == nil
    assert Embedding.timeout() == 60_000

    Application.put_env(:doctrans, :embedding,
      base_url: "http://embeddings:9000",
      api_key: "embedding-key",
      model: "embedding-model",
      timeout: 5678
    )

    assert Embedding.base_url() == "http://embeddings:9000"
    assert Embedding.api_key() == "embedding-key"
    assert Embedding.model() == "embedding-model"
    assert Embedding.timeout() == 5678
  end

  test "upload consumers share the configured directory and size limit" do
    Application.put_env(:doctrans, :uploads,
      upload_dir: "/tmp/custom-uploads",
      max_file_size: 123
    )

    assert Uploads.upload_dir() == "/tmp/custom-uploads"
    assert Uploads.max_file_size() == 123
    assert Doctrans.Documents.uploads_dir() == Uploads.upload_dir()

    assert PdfProcessor.get_pdf_path("document") ==
             "/tmp/custom-uploads/document.pdf"
  end

  test "the default storage root resolves inside the running application" do
    Application.put_env(:doctrans, :uploads, upload_dir: :default, max_file_size: 1)

    assert Uploads.upload_dir() == Application.app_dir(:doctrans, "priv/static/uploads")
    assert Path.type(Uploads.upload_dir()) == :absolute
  end

  test "missing required settings fail explicitly" do
    Application.put_env(:doctrans, :openai, [])
    Application.put_env(:doctrans, :uploads, [])
    assert_raise KeyError, fn -> OpenAI.chat_model() end
    assert_raise KeyError, fn -> OpenAI.base_url() end
    assert_raise KeyError, fn -> Uploads.upload_dir() end
    assert_raise KeyError, fn -> Uploads.max_file_size() end
  end
end
