defmodule Doctrans.Config.ReadinessTest do
  use Doctrans.EnvCase, async: false

  alias Doctrans.Config.Readiness

  alias Doctrans.Search.{
    EmbeddingErrorStub,
    EmbeddingNilStub,
    EmbeddingOptsStub,
    EmbeddingStub
  }

  alias Doctrans.TestEnv

  @models ["vision-model", "translation-model", "embedding-model"]

  # `TestEnv.put_env/2` replaces a whole section, so every setting the module
  # reads is named here rather than inherited from `config/config.exs`: a test
  # that silently fell back to the shipped model names would pass for the wrong
  # reason the moment those names changed.
  defp configure(opts \\ []) do
    TestEnv.put_env(:openai,
      base_url: Keyword.get(opts, :chat_url, "http://localhost:8000"),
      vision_model: Keyword.get(opts, :vision_model, "vision-model"),
      chat_model: "chat-model",
      translation_model: Keyword.get(opts, :translation_model, "translation-model")
    )

    TestEnv.put_env(:embedding,
      base_url: Keyword.get(opts, :embedding_url),
      model: Keyword.get(opts, :embedding_model, "embedding-model")
    )

    TestEnv.put_env(:openai_stub_models, Keyword.get(opts, :models, @models))
    TestEnv.put_env(:embedding_module, Keyword.get(opts, :embedding_module, EmbeddingStub))
  end

  defp codes(report), do: Enum.map(report.problems, fn {code, _bindings} -> code end)

  describe "check/0 with everything available" do
    test "reports ready, with the locality and destination the endpoints imply" do
      configure()

      report = Readiness.check()

      assert report.ready?
      assert report.problems == []
      assert report.local?
      assert report.destination == ""
    end

    test "a remote endpoint is still ready, and names where documents will go" do
      configure(chat_url: "https://api.somewhere.com/v1")

      report = Readiness.check()

      assert report.ready?
      refute report.local?
      assert report.destination == "api.somewhere.com"
    end
  end

  describe "check/0 when the model server cannot be reached" do
    test "reports the server, and invents no problems about models it never listed" do
      configure(models: :connection_refused)

      report = Readiness.check()

      refute report.ready?
      assert report.problems == [{:inference_unavailable, [destination: "localhost"]}]
    end

    test "a failed embedding probe is not blamed on a model list that was never fetched" do
      configure(models: :connection_refused, embedding_module: EmbeddingErrorStub)

      report = Readiness.check()

      assert report.problems == [
               {:inference_unavailable, [destination: "localhost"]},
               {:embedding_unavailable, [destination: "localhost"]}
             ]
    end
  end

  describe "check/0 model identifiers" do
    test "an extraction model the server does not offer is named with its destination" do
      configure(vision_model: "absent-vision-model")

      report = Readiness.check()

      refute report.ready?

      assert report.problems == [
               {:extraction_model_unavailable,
                [model: "absent-vision-model", destination: "localhost"]}
             ]
    end

    test "a translation model the server does not offer is named with its destination" do
      configure(translation_model: "absent-translation-model")

      report = Readiness.check()

      assert report.problems == [
               {:translation_model_unavailable,
                [model: "absent-translation-model", destination: "localhost"]}
             ]
    end

    test "both missing models are reported, extraction before translation" do
      configure(
        vision_model: "absent-vision-model",
        translation_model: "absent-translation-model"
      )

      assert codes(Readiness.check()) == [
               :extraction_model_unavailable,
               :translation_model_unavailable
             ]
    end

    # The settings fall back to each other, so a single misspelling arrives
    # under both roles; two entries would read as two independent faults.
    test "one model named by both settings is reported once, under the first role" do
      configure(vision_model: "absent-model", translation_model: "absent-model")

      report = Readiness.check()

      assert report.problems == [
               {:extraction_model_unavailable, [model: "absent-model", destination: "localhost"]}
             ]
    end

    test "the chat model is not upload readiness" do
      # "chat-model" is deliberately absent from the stubbed listing throughout.
      configure()

      assert Readiness.check().problems == []
    end

    test "an unreadable endpoint is named by its URL, since it has no host" do
      configure(chat_url: "llm:8000", models: :connection_refused)

      assert Readiness.check().problems == [
               {:inference_unavailable, [destination: "llm:8000"]}
             ]
    end
  end

  describe "check/0 embedding probe" do
    test "a vector narrower than the stored width reports both widths and the model" do
      configure(embedding_module: EmbeddingErrorStub)

      TestEnv.put_env(
        :embedding_error_reason,
        {:embedding_too_short, [expected: 1024, actual: 384]}
      )

      report = Readiness.check()

      refute report.ready?

      assert report.problems == [
               {:embedding_dimensions_too_small,
                [model: "embedding-model", expected: 1024, actual: 384]}
             ]
    end

    test "an embedding endpoint that does not answer is reported generically" do
      configure(embedding_module: EmbeddingErrorStub)
      TestEnv.put_env(:embedding_error_reason, :timeout)

      assert Readiness.check().problems == [
               {:embedding_unavailable, [destination: "localhost"]}
             ]
    end

    test "a success carrying no vector is a failed path, not a ready one" do
      configure(embedding_module: EmbeddingNilStub)

      assert Readiness.check().problems == [
               {:embedding_unavailable, [destination: "localhost"]}
             ]
    end

    test "a model absent from the shared server's list beats the generic reason" do
      configure(
        embedding_model: "absent-embedding-model",
        embedding_module: EmbeddingErrorStub
      )

      TestEnv.put_env(:embedding_error_reason, :timeout)

      assert Readiness.check().problems == [
               {:embedding_model_unavailable,
                [model: "absent-embedding-model", destination: "localhost"]}
             ]
    end

    # A separately hosted embedding server never appears in the chat server's
    # listing, so its absence there is evidence of nothing.
    test "a separately hosted embedding server falls back to the generic reason" do
      configure(
        embedding_url: "https://embed.example.com",
        embedding_model: "absent-embedding-model",
        embedding_module: EmbeddingErrorStub
      )

      TestEnv.put_env(:embedding_error_reason, :timeout)

      assert Readiness.check().problems == [
               {:embedding_unavailable, [destination: "embed.example.com"]}
             ]
    end

    test "the probe is bounded well under the indexing timeout it would inherit" do
      configure(embedding_module: EmbeddingOptsStub)
      TestEnv.put_env(:embedding_opts_observer, self())

      assert Readiness.check().problems == []

      assert_receive {:embedding_opts, "readiness", opts}
      assert Keyword.fetch!(opts, :timeout) == 5_000
    end
  end

  describe "check/0 ordering" do
    test "model problems come before the embedding problem" do
      configure(
        vision_model: "absent-vision-model",
        translation_model: "absent-translation-model",
        embedding_model: "absent-embedding-model",
        embedding_module: EmbeddingErrorStub
      )

      TestEnv.put_env(:embedding_error_reason, :timeout)

      assert codes(Readiness.check()) == [
               :extraction_model_unavailable,
               :translation_model_unavailable,
               :embedding_model_unavailable
             ]
    end
  end

  describe "check/0 credentials" do
    test "no part of a credential-bearing endpoint reaches the report" do
      configure(
        chat_url: "http://user:s3cret@remote.example:8000/v1?key=abc",
        models: :connection_refused,
        embedding_module: EmbeddingErrorStub
      )

      TestEnv.put_env(:embedding_error_reason, :timeout)

      report = Readiness.check()
      rendered = inspect(report, limit: :infinity, printable_limit: :infinity)

      refute rendered =~ "s3cret"
      refute rendered =~ "abc"
      refute report.local?
      assert report.destination == "remote.example"

      assert report.problems == [
               {:inference_unavailable, [destination: "remote.example"]},
               {:embedding_unavailable, [destination: "remote.example"]}
             ]
    end

    # These are the shapes that survive nulling `URI.userinfo`, and they are
    # also the ones with no host -- which is exactly when a destination falls
    # back to showing the configured URL.
    test "an endpoint with no parseable host still shows nothing secret" do
      for chat_url <- ["user:s3cret@llm.example.com:8000", "llm:8000?api-key=s3cret"] do
        configure(chat_url: chat_url, models: :connection_refused)

        rendered = inspect(Readiness.check(), limit: :infinity, printable_limit: :infinity)

        refute rendered =~ "s3cret", "#{chat_url} leaked its password into #{rendered}"
      end
    end
  end
end
