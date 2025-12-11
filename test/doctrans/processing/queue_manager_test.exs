defmodule Doctrans.Processing.QueueManagerTest do
  use Doctrans.DataCase
  use ExUnit.Case

  alias Doctrans.Processing.QueueManager

  setup do
    # Start QueueManager process for each test
    {:ok, _pid} = QueueManager.start_link()
    :ok
  end

  describe "QueueManager" do
    test "handles concurrent job operations" do
      # Test concurrent add operations
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            job = %{id: "job_#{i}", type: :pdf_extraction}
            QueueManager.add_job(job)
          end)
        end)

      # Wait for all to complete
      Enum.each(tasks, &Task.await/1)

      state = QueueManager.get_state()
      assert :queue.len(state.queue) == 5
    end

    test "handles job priority" do
      high_priority_job = %{id: "high_priority", type: :pdf_extraction, priority: :high}
      normal_job = %{id: "normal", type: :pdf_extraction}

      QueueManager.add_job(normal_job)
      QueueManager.add_job(high_priority_job)

      assert {:ok, ^high_priority_job} = QueueManager.get_next_job()
    end

    test "handles job retry logic" do
      job = %{id: "retry_job", type: :pdf_extraction}

      QueueManager.add_job(job)
      QueueManager.start_processing("retry_job")
      QueueManager.handle_job_timeout("retry_job")

      state = QueueManager.get_state()
      assert :queue.len(state.queue) == 1
      queue_items = :queue.to_list(state.queue)
      assert hd(queue_items).id == "retry_job"
    end

    test "handles job status transitions" do
      job = %{id: "status_job", type: :pdf_extraction}

      QueueManager.add_job(job)
      QueueManager.start_processing("status_job")
      QueueManager.complete_job("status_job", :success)

      state = QueueManager.get_state()
      assert length(state.completed) == 1

      case state.completed do
        [] -> flunk("Expected completed job but got empty list")
        [job | _] -> assert job.status == :success
      end
    end

    test "handles error job completion" do
      job = %{id: "error_job", type: :pdf_extraction}
      error = "Processing failed"

      QueueManager.add_job(job)
      QueueManager.start_processing("error_job")
      QueueManager.complete_job("error_job", {:error, error})

      state = QueueManager.get_state()
      assert length(state.completed) == 1

      case state.completed do
        [] -> flunk("Expected completed job but got empty list")
        [job | _] -> assert job.status == {:error, error}
      end
    end
  end
end
