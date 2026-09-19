defmodule Doctrans.Processing.PageContentStub do
  @moduledoc """
  An `OpenAIBehaviour` stub whose answers differ from page to page.

  `Doctrans.Processing.OpenAIStub` returns the same markdown for every image, so
  a retrieval result found after processing cannot be tied to the page that
  actually holds the queried text — every page holds it. This stub keys its
  extraction on the page number in the image filename, and its translation on
  the heading the extraction wrote, so each page of a document ends up with one
  source term and one translated term that no other page carries.

  Deriving the translation from the markdown handed in, rather than from the
  image, is deliberate: it makes the translated text evidence that extraction's
  output is what reached translation.
  """

  @behaviour Doctrans.Processing.OpenAIBehaviour

  alias Doctrans.Processing.OpenAIStub

  @source_terms %{
    1 => "Liquiditaetssicherung",
    2 => "Wertpapierportfolio",
    3 => "Pensionsrueckstellungen"
  }

  @translated_terms %{
    1 => "liquidity",
    2 => "securities",
    3 => "pensions"
  }

  @doc "The number of distinct pages this stub can answer for."
  @spec page_limit() :: pos_integer()
  def page_limit, do: map_size(@source_terms)

  @doc "The source term only page `page_number` carries."
  @spec source_term(pos_integer()) :: String.t()
  def source_term(page_number), do: Map.fetch!(@source_terms, page_number)

  @doc "The translated term only page `page_number` carries."
  @spec translated_term(pos_integer()) :: String.t()
  def translated_term(page_number), do: Map.fetch!(@translated_terms, page_number)

  @doc "The markdown `extract_markdown/2` answers for `page_number`."
  @spec source_markdown(pos_integer()) :: String.t()
  def source_markdown(page_number) do
    """
    # Seite #{page_number}

    Der Abschnitt ueber #{source_term(page_number)} nennt den Bestand zum Stichtag.
    """
    |> String.trim()
  end

  @doc "The markdown `translate/4` answers for `page_number`."
  @spec translated_markdown(pos_integer()) :: String.t()
  def translated_markdown(page_number) do
    """
    # Page #{page_number}

    The section about #{translated_term(page_number)} states the balance on the reporting date.
    """
    |> String.trim()
  end

  @impl true
  def extract_markdown(image_path, _opts),
    do: {:ok, image_path |> page_number_from_image() |> source_markdown()}

  @impl true
  def translate(markdown, _source_language, _target_language, _opts),
    do: {:ok, markdown |> page_number_from_markdown() |> translated_markdown()}

  @impl true
  def available?, do: OpenAIStub.available?()

  @impl true
  def list_models, do: OpenAIStub.list_models()

  @impl true
  def chat(messages, opts), do: OpenAIStub.chat(messages, opts)

  @impl true
  def chat_stream(messages, on_delta, opts), do: OpenAIStub.chat_stream(messages, on_delta, opts)

  # Raising rather than falling back keeps a test that wires this stub to an
  # unexpected caller visibly broken instead of quietly uniform again.
  defp page_number_from_image(image_path) do
    case Regex.run(~r/page-0*(\d+)\.png\z/, to_string(image_path)) do
      [_, number] -> validate(String.to_integer(number), image_path)
      nil -> raise ArgumentError, "#{inspect(__MODULE__)} cannot name a page in #{image_path}"
    end
  end

  defp page_number_from_markdown(markdown) do
    case Regex.run(~r/\A# Seite (\d+)/, to_string(markdown)) do
      [_, number] -> validate(String.to_integer(number), markdown)
      nil -> raise ArgumentError, "#{inspect(__MODULE__)} did not write #{inspect(markdown)}"
    end
  end

  defp validate(page_number, subject) when is_integer(page_number) do
    if Map.has_key?(@source_terms, page_number) do
      page_number
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)} answers pages 1..#{page_limit()}, got #{page_number} from #{inspect(subject)}"
    end
  end
end
