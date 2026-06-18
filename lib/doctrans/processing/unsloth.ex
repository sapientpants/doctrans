defmodule Doctrans.Processing.Unsloth do
  @moduledoc """
  Client for the Unsloth API.

  Provides functions for:
  - Extracting markdown from page images using a vision model
  - Translating markdown using a text model
  - Chat completions for RAG queries

  ## I18n Note

  This module runs in background GenServer processes (document processing workers),
  not in the web request process. Since Gettext locales are process-specific, error
  messages from this module will use the default locale, not the user's browser locale.
  This is acceptable as these errors are primarily logged and displayed as system status.
  """

  @behaviour Doctrans.Processing.ProviderBehaviour

  alias Doctrans.Processing.HttpProvider

  @provider %HttpProvider.Config{
    config_key: :unsloth,
    circuit_key: :unsloth_api,
    name: "Unsloth"
  }

  @impl true
  def extract_markdown(image_path, opts \\ []),
    do: HttpProvider.extract_markdown(image_path, @provider, opts)

  @impl true
  def translate(markdown, source_language, target_language, opts \\ []),
    do:
      HttpProvider.translate(
        markdown,
        source_language,
        target_language,
        @provider,
        opts
      )

  @impl true
  def chat(messages, opts \\ []),
    do: HttpProvider.chat(messages, @provider, opts)

  @impl true
  def available?, do: HttpProvider.available?(@provider)

  @impl true
  def list_models, do: HttpProvider.list_models(@provider)
end
