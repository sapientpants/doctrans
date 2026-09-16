defmodule Doctrans.Documents.TopicsTest do
  use ExUnit.Case, async: true

  alias Doctrans.Documents.{Document, Page, Topics}

  describe "PubSub functions" do
    test "subscribe_documents/0 subscribes to documents topic" do
      assert :ok = Topics.subscribe_documents()
    end

    test "subscribe_document/1 subscribes to document topic" do
      assert :ok = Topics.subscribe_document("test-id")
    end

    test "broadcast_document_update/1 broadcasts to subscribers" do
      doc = %Document{id: Ecto.UUID.generate()}
      Topics.subscribe_document(doc.id)
      Topics.subscribe_documents()

      Topics.broadcast_document_update(doc)

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
      refute_receive {:document_created, ^doc}
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
      refute_receive {:document_deleted, ^id}
    end

    test "unsubscribe_documents/0 stops collection events" do
      doc = %Document{id: Ecto.UUID.generate()}
      :ok = Topics.subscribe_documents()
      assert :ok = Topics.unsubscribe_documents()

      :ok = Topics.broadcast_document_created(doc)
      :ok = Topics.broadcast_document_deleted(doc)

      id = doc.id
      refute_receive {:document_created, ^doc}
      refute_receive {:document_deleted, ^id}
    end

    test "broadcast_page_update/1 broadcasts to subscribers" do
      doc = %Document{id: Ecto.UUID.generate()}
      page = %Page{id: Ecto.UUID.generate(), document_id: doc.id, page_number: 1}
      Topics.subscribe_document(doc.id)
      Topics.subscribe_documents()

      Topics.broadcast_page_update(page)

      assert_receive {:page_updated, ^page}
      assert_receive {:page_updated, ^page}
    end
  end

  test "unsubscribing stops document events and other documents stay isolated" do
    document = %Document{id: Ecto.UUID.generate()}
    other = %Document{id: Ecto.UUID.generate()}
    :ok = Topics.subscribe_document(document.id)
    :ok = Topics.broadcast_document_update(other)
    refute_receive {:document_updated, ^other}
    :ok = Topics.unsubscribe_document(document.id)
    :ok = Topics.broadcast_document_update(document)
    refute_receive {:document_updated, ^document}
  end
end
