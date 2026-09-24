defmodule Doctrans.Documents.TopicsTest do
  use ExUnit.Case, async: true

  alias Doctrans.Documents.{Document, Page, Topics}

  # `refute_received` rather than `refute_receive` throughout: a local broadcast
  # dispatches with a direct send from the calling process, so everything a
  # broadcast will ever deliver is in this mailbox by the time it returns. There
  # is nothing to wait for, and five default 100ms waits would only slow the file
  # down. Every assertion pins the document it expects, so a `{:document_created,
  # _}` from a fixture in a concurrently running file cannot satisfy one.
  describe "PubSub functions" do
    test "broadcast_document_updated/1 broadcasts to subscribers" do
      doc = %Document{id: Ecto.UUID.generate()}
      Topics.subscribe_document(doc.id)
      Topics.subscribe_documents()

      Topics.broadcast_document_updated(doc)

      # Should receive on document topic
      assert_receive {:document_updated, ^doc}
      # Should also receive on general documents topic
      assert_receive {:document_updated, ^doc}
    end

    test "broadcast_document_created/1 reaches only the collection topic" do
      doc = %Document{id: Ecto.UUID.generate()}
      Topics.subscribe_document(doc.id)
      Topics.subscribe_documents()

      assert :ok = Topics.broadcast_document_created(doc)

      # Once for the documents topic and never again: a document nobody has
      # opened yet has no per-document subscribers to notify.
      assert_receive {:document_created, ^doc}
      refute_received {:document_created, ^doc}
    end

    test "broadcast_document_deleted/1 reaches both topics and carries the id" do
      doc = %Document{id: Ecto.UUID.generate()}
      id = doc.id
      Topics.subscribe_document(doc.id)
      Topics.subscribe_documents()

      assert :ok = Topics.broadcast_document_deleted(doc)

      # The row is gone, so the payload is the bare id rather than a stale struct.
      assert_receive {:document_deleted, ^id}
      assert_receive {:document_deleted, ^id}
      refute_received {:document_deleted, ^id}
    end

    test "unsubscribe_documents/0 stops collection events" do
      doc = %Document{id: Ecto.UUID.generate()}
      :ok = Topics.subscribe_documents()
      assert :ok = Topics.unsubscribe_documents()

      :ok = Topics.broadcast_document_created(doc)
      :ok = Topics.broadcast_document_deleted(doc)

      id = doc.id
      refute_received {:document_created, ^doc}
      refute_received {:document_deleted, ^id}
    end

    test "broadcast_page_updated/1 broadcasts to subscribers" do
      doc = %Document{id: Ecto.UUID.generate()}
      page = %Page{id: Ecto.UUID.generate(), document_id: doc.id, page_number: 1}
      Topics.subscribe_document(doc.id)
      Topics.subscribe_documents()

      Topics.broadcast_page_updated(page)

      assert_receive {:page_updated, ^page}
      assert_receive {:page_updated, ^page}
    end
  end

  test "unsubscribing stops document events and other documents stay isolated" do
    document = %Document{id: Ecto.UUID.generate()}
    other = %Document{id: Ecto.UUID.generate()}
    :ok = Topics.subscribe_document(document.id)
    :ok = Topics.broadcast_document_updated(other)
    refute_received {:document_updated, ^other}
    :ok = Topics.unsubscribe_document(document.id)
    :ok = Topics.broadcast_document_updated(document)
    refute_received {:document_updated, ^document}
  end
end
