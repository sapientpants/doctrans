defmodule Doctrans.Jobs.HealthCheckJobTest do
  use Doctrans.DataCase, async: false
  use Oban.Testing, repo: Doctrans.Repo

  alias Doctrans.Jobs.HealthCheckJob
  alias Doctrans.Resilience.CircuitBreaker
  alias Doctrans.TestEnv

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    bypass = Bypass.open()
    TestEnv.put_env(:openai, base_url: "http://localhost:#{bypass.port}", api_key: nil)
    TestEnv.put_env(:uploads, upload_dir: tmp_dir)
    CircuitBreaker.reset(:openai_api)
    on_exit(fn -> CircuitBreaker.reset(:openai_api) end)

    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:doctrans, :health_check, :completed],
      fn _, _, metadata, owner ->
        send(owner, {:health_check, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{bypass: bypass}
  end

  for {status, result} <- [{200, :ok}, {503, :error}] do
    @status status
    @result result

    test "runs every probe and succeeds when the API returns #{status}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(@status, Jason.encode!(%{"data" => []}))
      end)

      assert :ok = perform_job(HealthCheckJob, %{})
      assert_received {:health_check, %{check: :openai, result: @result}}
      assert_received {:health_check, %{check: :database, result: :ok}}
      assert_received {:health_check, %{check: :filesystem, result: :ok}}
      refute_received {:health_check, _}
    end
  end
end
