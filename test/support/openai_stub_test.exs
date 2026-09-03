defmodule Doctrans.Processing.OpenAIStubTest do
  use ExUnit.Case, async: true

  alias Doctrans.Processing.OpenAIStub

  describe "list_models/0" do
    setup do
      previous = Application.get_env(:doctrans, :openai_stub_models)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:doctrans, :openai_stub_models, previous),
          else: Application.delete_env(:doctrans, :openai_stub_models)
      end)

      :ok
    end

    test "returns the default model list when unconfigured" do
      Application.delete_env(:doctrans, :openai_stub_models)

      assert {:ok, models} = OpenAIStub.list_models()
      assert is_list(models) and models != []
    end

    test "returns a custom model list when configured with a list" do
      Application.put_env(:doctrans, :openai_stub_models, ["model-a", "model-b"])

      assert {:ok, ["model-a", "model-b"]} = OpenAIStub.list_models()
    end

    test "returns the configured value as an error for non-list values" do
      Application.put_env(:doctrans, :openai_stub_models, :circuit_open)

      assert {:error, :circuit_open} = OpenAIStub.list_models()
    end
  end
end
