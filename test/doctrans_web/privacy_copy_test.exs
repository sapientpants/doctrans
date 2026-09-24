defmodule DoctransWeb.PrivacyCopyTest do
  use Doctrans.EnvCase, async: false

  alias Doctrans.TestEnv
  alias DoctransWeb.PrivacyCopy

  defp configure(chat_url, embedding_url, opts \\ []) do
    key = Keyword.take(opts, [:api_key])

    TestEnv.put_env(:openai, [base_url: chat_url, chat_model: "chat"] ++ key)
    TestEnv.put_env(:embedding, [base_url: embedding_url] ++ key)
  end

  describe "when all inference is local" do
    setup do
      configure("http://localhost:8000", nil)
    end

    test "the copy promises the documents stay put" do
      assert PrivacyCopy.tagline() == "Private document translation powered by local AI"

      assert PrivacyCopy.empty_state() ==
               "Upload a document to get started. All processing happens locally on your device."

      assert PrivacyCopy.upload_notice() == "Your documents never leave your device"
    end

    test "the notice is marked with a closed padlock" do
      assert PrivacyCopy.upload_notice_icon() == "hero-lock-closed"
    end
  end

  describe "when the chat endpoint is remote" do
    setup do
      configure("https://api.example.com", nil)
    end

    test "every claim names the destination instead of promising locality" do
      for copy <- [
            PrivacyCopy.tagline(),
            PrivacyCopy.empty_state(),
            PrivacyCopy.upload_notice()
          ] do
        assert copy =~ "api.example.com"
        refute copy =~ "never leave"
        refute copy =~ "locally"
      end
    end

    test "the padlock gives way to an outbound icon" do
      assert PrivacyCopy.upload_notice_icon() == "hero-arrow-up-tray"
    end
  end

  test "a remote embedding host is named even while chat stays local" do
    # Embedding requests carry the chunk text, so this is document egress too.
    configure("http://localhost:8000", "https://vectors.example.com")

    assert PrivacyCopy.upload_notice() =~ "vectors.example.com"
    refute PrivacyCopy.upload_notice() =~ "never leave"
  end

  test "both destinations are named when the two endpoints diverge" do
    configure("https://chat.example.com", "https://vectors.example.com")

    copy = PrivacyCopy.empty_state()
    assert copy =~ "chat.example.com"
    assert copy =~ "vectors.example.com"
  end

  test "an unreadable endpoint still names something rather than claiming locality" do
    configure("llm:8000", nil)

    assert PrivacyCopy.upload_notice() =~ "llm:8000"
    refute PrivacyCopy.upload_notice() =~ "never leave"
    assert PrivacyCopy.upload_notice_icon() == "hero-arrow-up-tray"
  end

  test "a configured API key never reaches the copy" do
    configure("https://api.example.com", nil, api_key: "sk-must-not-appear")

    for copy <- [
          PrivacyCopy.tagline(),
          PrivacyCopy.empty_state(),
          PrivacyCopy.upload_notice(),
          PrivacyCopy.upload_notice_icon()
        ] do
      refute copy =~ "sk-must-not-appear"
    end
  end

  test "credentials in an endpoint URL are stripped from the copy" do
    configure("http://user:s3cret@api.example.com:8000", nil)

    copy = PrivacyCopy.upload_notice()
    assert copy =~ "api.example.com"
    refute copy =~ "s3cret"
    refute copy =~ "user:"
  end
end
