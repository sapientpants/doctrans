defmodule Doctrans.Processing.OpenAIStubTest do
  use Doctrans.EnvCase, async: false

  alias Doctrans.Processing.OpenAIStub
  alias Doctrans.TestEnv

  describe "list_models/0" do
    test "returns the default model list when unconfigured" do
      TestEnv.put_env(:openai_stub_models, nil)

      assert {:ok,
              [
                "mlx-community/Qwen3.6-35B-A3B-4bit",
                "mlx-community/Qwen3-Embedding-8B-4bit-DWQ"
              ]} = OpenAIStub.list_models()
    end

    test "returns a custom model list when configured with a list" do
      TestEnv.put_env(:openai_stub_models, ["model-a", "model-b"])

      assert {:ok, ["model-a", "model-b"]} = OpenAIStub.list_models()
    end

    test "returns the configured value as an error for non-list values" do
      TestEnv.put_env(:openai_stub_models, :circuit_open)

      assert {:error, :circuit_open} = OpenAIStub.list_models()
    end
  end
end
