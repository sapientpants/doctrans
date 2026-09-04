defmodule Doctrans.Validation do
  @moduledoc """
  Input validation and sanitization utilities.

  Provides functions for validating and sanitizing user input
  to ensure security and data integrity.
  """

  @doc """
  Validates document creation/update parameters.

  ## Parameters
  - `attrs` - Map of document attributes

  ## Returns
  - `{:ok, sanitized_attrs}` if valid
  - `{:error, reason}` if invalid
  """
  def validate_document_attrs(attrs) when is_map(attrs) do
    required_fields = [:title, :original_filename, :target_language]

    with {:ok, attrs} <- validate_required_fields(attrs, required_fields),
         {:ok, attrs} <- validate_title(attrs),
         {:ok, attrs} <- validate_target_language(attrs),
         {:ok, attrs} <- sanitize_title(attrs),
         {:ok, attrs} <- sanitize_filename(attrs) do
      {:ok, attrs}
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Validates search query parameters.

  ## Parameters
  - `query` - Search query string

  ## Returns
  - `{:ok, sanitized_query}` if valid
  - `{:error, reason}` if invalid
  """
  def validate_search_query(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      String.length(trimmed) < 1 ->
        {:error, "Query too short"}

      String.length(trimmed) > 500 ->
        {:error, "Query too long (max 500 characters)"}

      true ->
        {:ok, String.slice(trimmed, 0, 500)}
    end
  end

  def validate_search_query(_), do: {:error, "Search query must be a string"}

  @doc """
  Validates language code.

  ## Parameters
  - `language` - Language code (e.g., "en", "es", "fr")

  ## Returns
  - `{:ok, language}` if valid
  - `{:error, reason}` if invalid
  """
  def validate_language(language) when is_binary(language) do
    supported_languages = ["en", "es", "fr", "de", "it", "pt", "nl", "no", "sv", "da", "pl"]
    normalized_language = String.downcase(String.trim(language))

    if normalized_language in supported_languages do
      {:ok, normalized_language}
    else
      {:error, "Unsupported language: #{language}"}
    end
  end

  def validate_language(_), do: {:error, "Language code must be a string"}

  @doc """
  Validates that a file's content matches its claimed extension by checking magic bytes.

  ## Parameters
  - `file_path` - Path to the file on disk
  - `extension` - The claimed file extension (e.g., ".pdf")

  ## Returns
  - :ok if the magic bytes match the extension
  - {:error, reason} if they don't match or the file can't be read
  """
  def validate_file_content(file_path, extension)
      when is_binary(file_path) and is_binary(extension) do
    case read_header(file_path, 8) do
      {:ok, header} when byte_size(header) == 8 ->
        if magic_bytes_match?(header, String.downcase(extension)) do
          :ok
        else
          {:error, "File content does not match its extension"}
        end

      {:ok, _too_small} ->
        {:error, "File is too small to be a valid document"}

      {:error, _} ->
        {:error, "Could not read file for validation"}
    end
  end

  def validate_file_content(_file_path, _extension),
    do: {:error, "File path and extension must be strings"}

  @doc """
  Sanitizes a filename string by removing dangerous characters.

  ## Parameters
  - `filename` - The filename to sanitize

  ## Returns
  - Sanitized filename string
  """
  def sanitize_filename_string(filename) when is_binary(filename) do
    filename
    # Replace .. with _
    |> String.replace(~r/\.\./, "_")
    |> String.replace("/", "_")
    # Remove null bytes completely
    |> String.replace("\0", "")
    |> String.replace(~r/[<>:"\/?*|\x01-\x1f]/, "_")
  end

  def sanitize_filename_string(_), do: ""

  # Private helpers

  defp read_header(file_path, bytes) do
    case File.open(file_path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, bytes) do
            data when is_binary(data) -> {:ok, data}
            :eof -> {:ok, ""}
            {:error, _} = err -> err
          end
        after
          File.close(io)
        end

      {:error, _} = err ->
        err
    end
  end

  defp magic_bytes_match?(header, ".pdf"),
    do: binary_part(header, 0, 5) == "%PDF-"

  defp magic_bytes_match?(header, ext) when ext in [".docx", ".odt"],
    do: binary_part(header, 0, 4) == <<0x50, 0x4B, 0x03, 0x04>>

  defp magic_bytes_match?(header, ".doc"),
    do: binary_part(header, 0, 4) == <<0xD0, 0xCF, 0x11, 0xE0>>

  defp magic_bytes_match?(header, ".rtf"),
    do: binary_part(header, 0, 5) == "{\\rtf"

  defp magic_bytes_match?(_header, _ext), do: false

  defp validate_required_fields(attrs, required_fields) when is_list(required_fields) do
    missing_fields = Enum.reject(required_fields, &Map.has_key?(attrs, &1))

    if Enum.empty?(missing_fields) do
      {:ok, attrs}
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp validate_title(%{title: title} = attrs) when is_binary(title) do
    trimmed_title = String.trim(title)

    if String.length(trimmed_title) >= 1 do
      {:ok, %{attrs | title: trimmed_title}}
    else
      {:error, "Title cannot be empty"}
    end
  end

  defp validate_title(_attrs), do: {:error, "Title is required and must be a string"}

  defp validate_target_language(%{target_language: language} = attrs) when is_binary(language) do
    case validate_language(language) do
      {:ok, _} -> {:ok, attrs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_target_language(_attrs),
    do: {:error, "Target language is required and must be a string"}

  defp sanitize_filename(%{original_filename: filename} = attrs) when is_binary(filename) do
    sanitized = sanitize_filename_string(filename)
    {:ok, Map.put(attrs, :original_filename, sanitized)}
  end

  defp sanitize_filename(attrs), do: {:ok, attrs}

  defp sanitize_title(%{title: title} = attrs) when is_binary(title) do
    sanitized = String.trim(title)
    {:ok, Map.put(attrs, :title, sanitized)}
  end

  defp sanitize_title(%{} = attrs), do: {:ok, attrs}
end
