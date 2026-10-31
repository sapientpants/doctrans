defmodule Doctrans.Search.EmbeddingMocksTest do
  use Doctrans.EnvCase, async: true

  alias Doctrans.Search.{EmbeddingMock, EmbeddingMocks}

  test "the default stub answers every test without any setup" do
    assert {:ok, %Pgvector{}} = EmbeddingMock.generate("anything", [])
    assert {:ok, nil} = EmbeddingMock.generate("", [])
  end

  test "observe/0 reports each call with its options" do
    EmbeddingMocks.observe()

    assert {:ok, %Pgvector{}} = EmbeddingMock.generate("probe", timeout: 5_000)
    assert_received {:embedding_call, "probe", timeout: 5_000}
  end

  test "fail_matching/2 fails only the inputs the plan names" do
    EmbeddingMocks.fail_matching([{["alpha", "beta"], :timeout}, {"gamma", :circuit_open}],
      observe: true
    )

    assert {:error, :timeout} = EmbeddingMock.generate("alpha and beta", [])
    assert {:ok, %Pgvector{}} = EmbeddingMock.generate("alpha alone", [])
    assert {:error, :circuit_open} = EmbeddingMock.generate("gamma", [])
    assert_received {:embedding_call, "gamma", []}
  end

  test "hold/2 parks the selected input until released and answers the configured result" do
    barrier = EmbeddingMocks.hold("held", result: {:error, :circuit_open})

    assert {:ok, %Pgvector{}} = EmbeddingMock.generate("not held", [])

    task = Task.async(fn -> EmbeddingMock.generate("held", []) end)

    assert_receive {:embedding_started, ^barrier, pid}
    refute Task.yield(task, 50)

    send(pid, {:continue_embedding, barrier})
    assert {:error, :circuit_open} = Task.await(task)
  end

  test "a stub reaches only the processes this test spawned" do
    EmbeddingMocks.fail(:timeout)

    # A task carries `$callers`, so it sees this test's stub.
    assert {:error, :timeout} =
             Task.async(fn -> EmbeddingMock.generate("mine", []) end) |> Task.await()

    # A process the application supervises, with no `$callers` back to this
    # test, sees no stub at all in private mode -- which is what keeps one async
    # test's failure out of another's run, and why a test driving such a process
    # stays `async: false`.
    stranger =
      Task.Supervisor.async_nolink(Doctrans.TaskSupervisor, fn ->
        Process.delete(:"$callers")

        try do
          EmbeddingMock.generate("mine", [])
        rescue
          error -> {:raised, error}
        end
      end)

    assert {:raised, %Mox.UnexpectedCallError{}} = Task.await(stranger)
  end
end
