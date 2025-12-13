defmodule Doctrans.Validation do
  @moduledoc """
  Comprehensive input validation and sanitization utilities.

  Provides functions for validating and sanitizing user input
  to ensure security and data integrity.
  """

  @doc """
  Validates file upload parameters.

  ## Parameters
  - `filename` - The original filename
  - `size` - The file size in bytes
  - `content_type` - The MIME content type

  ## Returns
  - `{:ok, sanitized_filename}` if valid
  - `{:error, reason}` if invalid
  """
  def validate_file_upload(upload, max_size) when is_map(upload) do
    filename = Map.get(upload, :filename)
    content_type = Map.get(upload, :content_type)
    size = Map.get(upload, :size)

    # Check if this looks like a file upload structure
    if is_nil(filename) or is_nil(content_type) do
      {:error, "Invalid file upload structure"}
    else
      case validate_file_upload(filename, content_type, size, max_size) do
        {:ok, _} ->
          sanitized_filename = sanitize_filename_string(filename)
          {:ok, Map.put(upload, :filename, sanitized_filename)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def validate_file_upload(_, _), do: {:error, "Invalid file upload structure"}

  def validate_file_upload(filename, content_type, size)
      when is_binary(filename) and is_integer(size) and is_binary(content_type) do
    with :ok <- validate_filename(filename),
         :ok <- validate_file_size(size),
         :ok <- validate_content_type(content_type) do
      sanitized_filename = sanitize_filename(filename)
      {:ok, sanitized_filename}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_file_upload(filename, content_type, size, max_size)
      when is_binary(filename) do
    with :ok <- validate_filename(filename),
         :ok <- validate_content_type(content_type || ""),
         :ok <- validate_file_size(size, max_size) do
      sanitized_filename = sanitize_filename(filename)
      {:ok, sanitized_filename}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates document creation/update parameters.

  ## Parameters
  - `attrs` - Map of document attributes

  ## Returns
  - `{:ok, sanitized_attrs}` if valid
  - `{:error, changeset}` if invalid
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
  Validates page update parameters.

  ## Parameters
  - `attrs` - Map of page attributes

  ## Returns
  - `{:ok, sanitized_attrs}` if valid
  - `{:error, changeset}` if invalid
  """
  def validate_page_attrs(attrs) when is_map(attrs) do
    with {:ok, attrs} <- validate_required_fields(attrs, [:page_number]),
         {:ok, attrs} <-
           sanitize_markdown_fields(attrs, [:original_markdown, :translated_markdown]) do
      {:ok, attrs}
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Validates page update parameters with status validation.

  ## Parameters
  - `attrs` - Map of page attributes

  ## Returns
  - `{:ok, sanitized_attrs}` if valid
  - `{:error, reason}` if invalid
  """
  def validate_page_update_attrs(attrs) when is_map(attrs) do
    with {:ok, sanitized_attrs} <- validate_page_attrs(attrs),
         :ok <- validate_extraction_status(sanitized_attrs),
         :ok <- validate_translation_status(sanitized_attrs) do
      {:ok, sanitized_attrs}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_page_update_attrs(_), do: {:error, "Page attributes must be a map"}

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
      String.length(trimmed) < 3 ->
        {:error, "Query too short (minimum 3 characters)"}

      String.length(trimmed) > 500 ->
        {:error, "Query too long (max 500 characters)"}

      String.contains?(trimmed, "<script>") or String.contains?(trimmed, "</script>") ->
        {:error, "Query contains invalid characters"}

      true ->
        sanitized = String.slice(trimmed, 0, 500)
        {:ok, sanitized}
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

  # Private validation functions

  defp validate_filename(filename) when is_binary(filename) do
    cond do
      String.starts_with?(filename, ".") ->
        {:error, "Filename cannot start with a dot"}

      String.length(filename) > 255 ->
        {:error, "Filename too long (max 255 characters)"}

      String.match?(filename, ~r/[<>:"\/?*|\x00-\x1f]/) ->
        {:error, "Filename contains invalid characters"}

      true ->
        :ok
    end
  end

  defp validate_file_size(size) when is_integer(size) do
    # Use configured max size or default to 100MB
    max_size =
      Application.get_env(:doctrans, :uploads, []) |> Keyword.get(:max_file_size, 100_000_000)

    validate_file_size(size, max_size)
  end

  defp validate_file_size(size, max_size) when is_integer(size) and is_integer(max_size) do
    if size > max_size do
      {:error, "File too large (max #{div(max_size, 1_000_000)}MB)"}
    else
      :ok
    end
  end

  defp validate_file_size(nil, _max_size), do: {:error, "File size is required"}

  defp validate_content_type(content_type) when is_binary(content_type) do
    allowed_types = [
      # PDF
      "application/pdf",
      # Generic binary (browsers sometimes use this)
      "application/octet-stream",
      # Word documents
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "application/msword",
      # OpenDocument
      "application/vnd.oasis.opendocument.text",
      # Rich Text Format
      "application/rtf",
      "text/rtf"
    ]

    if content_type in allowed_types do
      :ok
    else
      {:error, "Invalid file type: #{content_type}"}
    end
  end

  defp validate_extraction_status(attrs) do
    case Map.get(attrs, :extraction_status) do
      nil -> :ok
      status when status in ["pending", "in_progress", "completed", "failed"] -> :ok
      status -> {:error, "Invalid extraction status: #{status}"}
    end
  end

  defp validate_translation_status(attrs) do
    case Map.get(attrs, :translation_status) do
      nil -> :ok
      status when status in ["pending", "in_progress", "completed", "failed"] -> :ok
      status -> {:error, "Invalid translation status: #{status}"}
    end
  end

  defp validate_required_fields(attrs, required_fields) when is_list(required_fields) do
    # Only check required fields if attrs is a map (not an error tuple)
    if is_map(attrs) do
      missing_fields = Enum.reject(required_fields, &Map.has_key?(attrs, &1))

      if Enum.empty?(missing_fields) do
        {:ok, attrs}
      else
        {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
      end
    else
      {:error, "Invalid attributes"}
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

  # Sanitization functions

  defp sanitize_filename(filename) when is_binary(filename) do
    filename
    # Replace .. with _
    |> String.replace(~r/\.\./, "_")
    |> String.replace(~r/[^\w\-\.]/, "_")
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim(".")
  end

  defp sanitize_filename(%{original_filename: filename} = attrs) when is_binary(filename) do
    sanitized = sanitize_filename_string(filename)
    {:ok, Map.put(attrs, :original_filename, sanitized)}
  end

  defp sanitize_filename(attrs), do: {:ok, attrs}

  defp sanitize_title(%{title: title} = attrs) when is_binary(title) do
    sanitized = String.trim(title)
    {:ok, Map.put(attrs, :title, sanitized)}
  end

  defp sanitize_title(attrs), do: {:ok, attrs}

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

  defp sanitize_markdown_fields(attrs, fields) when is_list(fields) do
    sanitized_attrs =
      Enum.reduce(fields, attrs, fn field, acc ->
        if Map.has_key?(acc, field) and is_binary(Map.get(acc, field)) do
          original_value = Map.get(acc, field)
          sanitized = sanitize_markdown_string(original_value)
          Map.put(acc, field, sanitized)
        else
          acc
        end
      end)

    {:ok, sanitized_attrs}
  end

  @doc """
  Sanitizes markdown content by removing dangerous HTML.

  ## Parameters
  - `markdown` - The markdown content to sanitize

  ## Returns
  - Sanitized markdown string
  """
  def sanitize_markdown_string(markdown) when is_binary(markdown) do
    markdown
    # Remove entire script blocks
    |> String.replace(~r/<script[^>]*>.*?<\/script>/i, "")
    # Remove opening script tags
    |> String.replace(~r/<script[^>]*>/i, "")
    # Remove closing script tags
    |> String.replace(~r/<\/script>/i, "")
    |> String.replace(~r/on\w+\s*=/i, "")
    |> String.replace(~r/<img[^>]*>/i, "")
  end

  def sanitize_markdown_string(_), do: ""

  @doc """
  Sanitizes markdown content for safe storage and display.
  """
  def sanitize_markdown(markdown) when is_binary(markdown) do
    markdown
    # Remove potentially dangerous HTML tags
    |> String.replace(~r/<script[^>]*>/i, "")
    |> String.replace(~r/<\/script>/i, "")
    # Remove javascript: protocols
    |> String.replace(~r/javascript:/i, "")
    # Remove data: URLs
    |> String.replace(~r/data:[^"\s]*]/i, "")
    # Limit length
    |> String.slice(0, 50_000)
  end
end
