defmodule DoctransWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    phoenix_metrics() ++
      database_metrics() ++
      vm_metrics() ++
      circuit_breaker_metrics() ++
      retry_metrics() ++
      health_check_metrics() ++
      processing_metrics() ++
      job_metrics()
  end

  # Phoenix Metrics
  defp phoenix_metrics do
    [
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      )
    ]
  end

  # Database Metrics
  defp database_metrics do
    [
      summary("doctrans.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("doctrans.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("doctrans.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("doctrans.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("doctrans.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      )
    ]
  end

  # VM Metrics
  defp vm_metrics do
    [
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  # Resilience Metrics - Circuit Breakers
  defp circuit_breaker_metrics do
    [
      counter("doctrans.circuit_breaker.blown.count",
        tags: [:fuse_name],
        description: "Circuit breaker blown events"
      ),
      counter("doctrans.circuit_breaker.reset.count",
        tags: [:fuse_name],
        description: "Circuit breaker reset events"
      ),
      counter("doctrans.circuit_breaker.failure.count",
        tags: [:fuse_name],
        description: "Circuit breaker failure reports"
      ),
      counter("doctrans.circuit_breaker.rejected.count",
        tags: [:fuse_name],
        description: "Requests rejected due to open circuit"
      )
    ]
  end

  # Background Job Metrics
  #
  # Indexing, extraction and translation all run as Oban jobs, so a job that
  # crashes, exhausts its attempts, or is cancelled is the way those failures
  # surface. Nothing else in the app subscribes to Oban's events, which is why
  # these are tagged by queue and worker rather than per-pipeline counters.
  defp job_metrics do
    [
      counter("oban.job.stop.duration",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        tags: [:queue, :state],
        description: "Jobs that finished, by queue and outcome"
      ),
      summary("oban.job.stop.duration",
        tags: [:queue],
        unit: {:native, :millisecond},
        description: "Job execution time by queue"
      ),
      counter("oban.job.exception.duration",
        event_name: [:oban, :job, :exception],
        measurement: :duration,
        tags: [:queue, :state],
        description: "Jobs that raised or exited, by queue"
      ),
      summary("oban.job.queue_time",
        event_name: [:oban, :job, :stop],
        measurement: :queue_time,
        tags: [:queue],
        unit: {:native, :millisecond},
        description: "Time spent waiting in the queue before execution"
      )
    ]
  end

  # Resilience Metrics - Retries
  defp retry_metrics do
    [
      counter("doctrans.retry.attempt.count",
        tags: [:type],
        description: "Retry attempts by operation type"
      ),
      counter("doctrans.retry.exhausted.count",
        tags: [:type],
        description: "Operations that exhausted all retries"
      )
    ]
  end

  # Resilience Metrics - Health Checks
  defp health_check_metrics do
    [
      summary("doctrans.health_check.completed.duration_ms",
        tags: [:check],
        unit: :millisecond,
        description: "Health check duration"
      ),
      counter("doctrans.health_check.all_completed.healthy",
        description: "Count of healthy services"
      ),
      counter("doctrans.health_check.all_completed.unhealthy",
        description: "Count of unhealthy services"
      )
    ]
  end

  # Processing Metrics
  defp processing_metrics do
    [
      counter("doctrans.processing.timeout.count",
        description: "Page processing timeouts"
      ),
      counter("doctrans.sweeper.completed.count",
        description: "Successful sweeper runs"
      ),
      counter("doctrans.sweeper.failed.count",
        description: "Failed sweeper runs"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {DoctransWeb, :count_users, []}
    ]
  end
end
