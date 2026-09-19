defmodule Doctrans.Resilience.HealthCheckTest do
  @moduledoc """
  Exercises each dependency probe against a real, local failure.

  The checks exist to describe a broken deployment, so every test here drives
  one of the failures they are meant to report -- an API that answers with an
  error status, an unreachable endpoint, a storage root that is missing or
  read-only -- rather than only the happy path. The OpenAI probe talks to a
  local Bypass server, so no test reaches the network.
  """

  use Doctrans.DataCase, async: false

  alias Doctrans.Resilience.CircuitBreaker
  alias Doctrans.Resilience.HealthCheck
  alias Doctrans.TestEnv

  @completed [:doctrans, :health_check, :completed]

  setup do
    CircuitBreaker.reset(:openai_api)
    bypass = Bypass.open()
    put_openai_env(base_url: "http://localhost:#{bypass.port}", api_key: "sk-test-123")

    on_exit(fn -> CircuitBreaker.reset(:openai_api) end)

    %{bypass: bypass}
  end

  describe "check_openai/0" do
    test "reports the models the API advertises", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
        send(test_pid, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
        models(conn, ["gpt-4o-mini", "gpt-4o"])
      end)

      assert HealthCheck.check_openai() ==
               {:ok, %{available: true, models: ["gpt-4o-mini", "gpt-4o"], circuit: :ok}}

      assert_received {:authorization, ["Bearer sk-test-123"]}
    end

    test "reports an empty model list when the API returns no data", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"object" => "list"}))
      end)

      assert HealthCheck.check_openai() == {:ok, %{available: true, models: [], circuit: :ok}}
    end

    test "reports the status code when the API rejects the request", %{bypass: bypass} do
      # An unauthorized key is the failure an operator actually gets here.
      Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
        Plug.Conn.resp(conn, 401, "unauthorized")
      end)

      assert HealthCheck.check_openai() == {:error, {:http_error, [status: 401]}}
    end

    test "reports a transport error when the API is unreachable" do
      put_openai_env(base_url: "http://127.0.0.1:1", api_key: nil)

      assert HealthCheck.check_openai() == {:error, {:transport_error, [reason: :econnrefused]}}
    end

    test "normalizes a raised failure instead of crashing the caller" do
      # A base URL without a scheme makes Req raise while building the request.
      put_openai_env(base_url: "localhost:9999", api_key: nil)

      assert {:error, {:operation_failed, [reason: %ArgumentError{}]}} =
               HealthCheck.check_openai()
    end

    test "rejects the call without reaching the API when the circuit is blown", %{bypass: bypass} do
      test_pid = self()

      Bypass.stub(bypass, "GET", "/v1/models", fn conn ->
        send(test_pid, :http_request)
        models(conn, [])
      end)

      blow(:openai_api)

      assert HealthCheck.check_openai() == {:error, :circuit_open}
      refute_received :http_request
    end

    test "emits a completed event carrying the outcome", %{bypass: bypass} do
      attach_completed()
      Bypass.expect(bypass, "GET", "/v1/models", &models(&1, []))

      assert {:ok, _} = HealthCheck.check_openai()
      assert_received {:completed, %{duration_ms: duration}, %{check: :openai, result: :ok}}
      assert duration >= 0

      blow(:openai_api)

      assert HealthCheck.check_openai() == {:error, :circuit_open}
      assert_received {:completed, _measurements, %{check: :openai, result: :error}}
    end
  end

  describe "check_database/0" do
    test "returns :ok when the repo answers a query" do
      assert HealthCheck.check_database() == :ok
    end

    test "emits a completed event for the database check" do
      attach_completed()

      assert HealthCheck.check_database() == :ok
      assert_received {:completed, _measurements, %{check: :database, result: :ok}}
    end
  end

  describe "check_filesystem/0" do
    test "returns :ok and leaves no probe file behind" do
      uploads_dir = Doctrans.Documents.uploads_dir()

      assert HealthCheck.check_filesystem() == :ok
      refute Enum.any?(File.ls!(uploads_dir), &String.starts_with?(&1, ".health_check_"))
    end

    @tag :tmp_dir
    test "names the storage root when it does not exist", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "storage-root-that-was-never-created")
      TestEnv.put_env(:uploads, upload_dir: missing, max_file_size: 100_000_000)

      assert HealthCheck.check_filesystem() ==
               {:error, {:uploads_directory_missing, [path: missing]}}
    end

    @tag :tmp_dir
    test "reports the reason when the storage root is read-only", %{tmp_dir: tmp_dir} do
      read_only = Path.join(tmp_dir, "read-only-root")
      File.mkdir!(read_only)
      File.chmod!(read_only, 0o500)
      on_exit(fn -> File.chmod(read_only, 0o700) end)

      TestEnv.put_env(:uploads, upload_dir: read_only, max_file_size: 100_000_000)

      assert HealthCheck.check_filesystem() ==
               {:error, {:uploads_directory_unwritable, [reason: :eacces]}}
    end

    test "normalizes a raised failure instead of crashing the caller" do
      # An unusable `:upload_dir` makes the storage root accessor raise before
      # the check gets as far as probing anything.
      TestEnv.put_env(:uploads, upload_dir: :not_a_path, max_file_size: 100_000_000)

      assert {:error, {:operation_failed, [reason: %ArgumentError{}]}} =
               HealthCheck.check_filesystem()
    end

    @tag :tmp_dir
    test "emits a completed event carrying the failure", %{tmp_dir: tmp_dir} do
      attach_completed()
      TestEnv.put_env(:uploads, upload_dir: Path.join(tmp_dir, "gone"), max_file_size: 1)

      assert {:error, _reason} = HealthCheck.check_filesystem()
      assert_received {:completed, _measurements, %{check: :filesystem, result: :error}}
    end
  end

  describe "check_all/0" do
    test "returns one verdict per dependency", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/models", &models(&1, ["gpt-4o-mini"]))

      assert HealthCheck.check_all() == %{
               openai: {:ok, %{available: true, models: ["gpt-4o-mini"], circuit: :ok}},
               database: :ok,
               filesystem: :ok
             }
    end

    test "keeps checking the other dependencies after one fails", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v1/models", &models(&1, []))
      blow(:openai_api)

      results = HealthCheck.check_all()

      assert results.openai == {:error, :circuit_open}
      assert results.database == :ok
      assert results.filesystem == :ok
    end
  end

  describe "healthy?/0" do
    test "returns true when every check passes", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/models", &models(&1, ["gpt-4o-mini"]))

      assert HealthCheck.healthy?()
    end

    test "returns false when a check fails", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/v1/models", &models(&1, []))
      blow(:openai_api)

      refute HealthCheck.healthy?()
    end
  end

  describe "circuit_breaker_status/0" do
    test "reports every configured fuse" do
      CircuitBreaker.reset(:embedding_api)

      assert HealthCheck.circuit_breaker_status() == %{openai_api: :ok, embedding_api: :ok}
    end

    test "reports a blown fuse" do
      blow(:openai_api)

      assert HealthCheck.circuit_breaker_status().openai_api == :blown
    end
  end

  # `:openai` also carries the model names the processing pipeline reads, and
  # `Application.put_env/3` is VM-global: replacing the keyword list outright
  # would unset them for every process for as long as the test runs.
  defp put_openai_env(overrides) do
    merged = Keyword.merge(Application.fetch_env!(:doctrans, :openai), overrides)
    TestEnv.put_env(:openai, merged)
  end

  defp models(conn, ids) do
    body = %{"object" => "list", "data" => Enum.map(ids, &%{"id" => &1})}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp blow(fuse_name) do
    for _ <- 1..6, do: CircuitBreaker.melt(fuse_name)
    :blown = CircuitBreaker.status(fuse_name)
    :ok
  end

  # The checks run in the test process, so a handler that forwards to `self()`
  # delivers before the call returns and `assert_received` needs no timeout.
  defp attach_completed do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @completed,
        fn _event, measurements, metadata, pid ->
          send(pid, {:completed, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
