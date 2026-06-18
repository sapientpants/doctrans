defmodule Doctrans.Processing.ProviderResolverTest do
  use ExUnit.Case, async: false

  alias Doctrans.Processing.ProviderResolver

  setup do
    on_exit(fn ->
      Application.delete_env(:doctrans, :provider)
      Application.delete_env(:doctrans, :provider_module)
    end)
  end

  describe "resolve/0" do
    test "returns Ollama when provider is :ollama" do
      Application.put_env(:doctrans, :provider, :ollama)
      assert {:ok, Doctrans.Processing.Ollama} = ProviderResolver.resolve()
    end

    test "returns Unsloth when provider is :unsloth" do
      Application.put_env(:doctrans, :provider, :unsloth)
      assert {:ok, Doctrans.Processing.Unsloth} = ProviderResolver.resolve()
    end

    test "returns Ollama when provider is not set" do
      Application.delete_env(:doctrans, :provider)
      assert {:ok, Doctrans.Processing.Ollama} = ProviderResolver.resolve()
    end

    test "returns error for unknown provider" do
      Application.put_env(:doctrans, :provider, :unknown)
      assert {:error, reason} = ProviderResolver.resolve()
      assert reason =~ "Unknown provider"
    end

    test "returns module when provider_module is set" do
      Application.put_env(:doctrans, :provider_module, Doctrans.Processing.OllamaStub)
      assert {:ok, Doctrans.Processing.OllamaStub} = ProviderResolver.resolve()
    end

    test "provider_module takes precedence over provider" do
      Application.put_env(:doctrans, :provider, :unsloth)
      Application.put_env(:doctrans, :provider_module, Doctrans.Processing.OllamaStub)
      assert {:ok, Doctrans.Processing.OllamaStub} = ProviderResolver.resolve()
    end
  end

  describe "resolve!/0" do
    test "returns module for valid provider" do
      Application.put_env(:doctrans, :provider, :ollama)
      assert ProviderResolver.resolve!() == Doctrans.Processing.Ollama
    end

    test "raises for unknown provider" do
      Application.put_env(:doctrans, :provider, :unknown)

      assert_raise ArgumentError, fn ->
        ProviderResolver.resolve!()
      end
    end
  end
end
