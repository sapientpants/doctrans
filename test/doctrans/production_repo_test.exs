defmodule Doctrans.ProductionRepoTest do
  use ExUnit.Case, async: false

  alias Doctrans.Documents.{Document, Page}
  alias Doctrans.ProductionConfigRepo, as: Repo

  @env_keys ~w(DATABASE_URL SECRET_KEY_BASE DOCTRANS_ENV_FILE ECTO_IPV6 POOL_SIZE)

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    System.put_env(%{
      "DATABASE_URL" => "ecto://unused/unused",
      "SECRET_KEY_BASE" => String.duplicate("a", 64),
      "DOCTRANS_ENV_FILE" => Path.join(System.tmp_dir!(), "missing-#{Uniq.UUID.uuid7()}.env"),
      "ECTO_IPV6" => "false",
      "POOL_SIZE" => "1"
    })

    config_dir = Path.expand("../../config", __DIR__)
    compile_config = Config.Reader.read!(Path.join(config_dir, "config.exs"), env: :prod)
    runtime_config = Config.Reader.read!(Path.join(config_dir, "runtime.exs"), env: :prod)
    config = Config.Reader.merge(compile_config, runtime_config)

    # Redirect only the connection to the test database. In particular, never
    # inherit the test repository's types or sandbox pool configuration.
    connection =
      Doctrans.Repo.config()
      |> Keyword.take([:username, :password, :hostname, :port, :database, :socket_dir])

    repo_config =
      config[:doctrans][Doctrans.Repo]
      |> Keyword.delete(:url)
      |> Keyword.merge(connection)

    start_supervised!({Repo, repo_config})
    :ok
  end

  test "production configuration supports page reads and vector writes" do
    assert {:error, :smoke_test_complete} =
             Repo.transaction(fn ->
               document =
                 Repo.insert!(%Document{
                   title: "Production vector smoke test",
                   original_filename: "test.pdf",
                   target_language: "en"
                 })

               page = Repo.insert!(%Page{document_id: document.id, page_number: 1})
               assert Repo.get!(Page, page.id).embedding == nil

               vector = Pgvector.new(List.duplicate(0.5, 1024))

               page
               |> Page.embedding_changeset(%{embedding: vector, embedding_status: "completed"})
               |> Repo.update!()

               stored_page = Repo.get!(Page, page.id)
               assert Pgvector.to_list(stored_page.embedding) == Pgvector.to_list(vector)
               assert stored_page.embedding_status == "completed"

               Repo.rollback(:smoke_test_complete)
             end)
  end
end
