defmodule DoctransWeb.DocumentLive.DocumentStream do
  @moduledoc """
  Socket state for the dashboard's ordered document stream.

  Owns the list half of `DoctransWeb.DocumentLive.Index`: querying documents with
  their progress and keeping the `:documents` stream in the order PostgreSQL
  returned. The stream's order is tracked separately from the stream itself, in
  `:document_order`, because a LiveView stream is not enumerable and cannot be asked
  where an item currently sits. The PubSub subscription that feeds it belongs to
  `Index`, which holds a single one on the collection topic.

  Kept out of the LiveView module so that `Index` handles events and messages and does
  not also reach into the `Documents` context, in the same idiom as
  `DoctransWeb.DocumentLive.ChatSession`.
  """

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [stream: 3, stream: 4, stream_delete: 3, stream_insert: 4]

  alias Doctrans.Documents

  @doc """
  Assigns the empty stream state. The list itself arrives from `refresh/1`.
  """
  def init(socket) do
    socket
    |> assign(:documents_count, 0)
    |> stream(:documents, [])
  end

  @doc """
  Re-queries the document list and resets the stream.
  """
  def refresh(socket) do
    documents =
      Documents.list_documents_with_progress(
        sort_by: socket.assigns.sort_by,
        sort_dir: socket.assigns.sort_dir
      )

    socket
    |> assign(:document_order, Enum.map(documents, &order_entry(&1, socket)))
    |> assign(:documents_count, length(documents))
    |> stream(:documents, documents, reset: true)
  end

  @doc """
  Refreshes the cards for `ids` only, dropping any that no longer exist.
  """
  def refresh_documents(socket, []), do: socket

  def refresh_documents(socket, ids) do
    summaries = Documents.list_documents_with_progress(document_ids: ids)
    found_ids = Enum.map(summaries, & &1.id)
    socket = Enum.reduce(ids -- found_ids, socket, &remove(&2, &1))
    update_documents(socket, summaries)
  end

  @doc """
  Drops one document from the stream, its order, and every list keyed by id.
  """
  def remove(socket, id) do
    order = Enum.reject(socket.assigns.document_order, &(elem(&1, 0) == id))

    socket
    |> assign(:document_order, order)
    |> assign(:documents_count, length(order))
    |> assign(
      :pending_document_ids,
      Enum.reject(socket.assigns.pending_document_ids, &(&1 == id))
    )
    |> stream_delete(:documents, %{id: id})
  end

  # Keys detect changes; PostgreSQL determines ordering, including title collation.
  defp order_entry(summary, socket) do
    {summary.id, Map.fetch!(summary.document, socket.assigns.sort_by)}
  end

  defp update_documents(socket, summaries) do
    order = updated_document_order(socket, summaries)

    socket
    |> clear_reordered_cards(summaries, order != socket.assigns.document_order)
    |> track_documents(order)
    |> insert_in_order(order, Map.new(summaries, &{&1.id, &1}))
  end

  # The client applies all deletions before insertions. Remove affected cards
  # together, then reinsert from left to right at their final batch positions.
  defp clear_reordered_cards(socket, _summaries, false), do: socket

  defp clear_reordered_cards(socket, summaries, true) do
    Enum.reduce(summaries, socket, &stream_delete(&2, :documents, &1))
  end

  defp track_documents(socket, order) do
    socket
    |> assign(:document_order, order)
    |> assign(:documents_count, length(order))
  end

  defp insert_in_order(socket, order, summaries_by_id) do
    order
    |> Enum.with_index()
    |> Enum.reduce(socket, fn {{id, _key}, index}, socket ->
      case Map.fetch(summaries_by_id, id) do
        {:ok, summary} -> stream_insert(socket, :documents, summary, at: index)
        :error -> socket
      end
    end)
  end

  defp updated_document_order(socket, summaries) do
    previous_order = socket.assigns.document_order
    previous_keys = Map.new(previous_order)
    entries = Map.new(summaries, &order_entry(&1, socket))

    if Enum.any?(entries, fn {id, key} -> Map.fetch(previous_keys, id) != {:ok, key} end) do
      previous_keys
      |> Map.merge(entries)
      |> Map.to_list()
      |> Documents.sort_document_order(
        sort_by: socket.assigns.sort_by,
        sort_dir: socket.assigns.sort_dir
      )
    else
      previous_order
    end
  end
end
