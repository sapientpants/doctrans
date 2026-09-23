defmodule DoctransWeb.DocumentLive.UploadReadinessTest do
  @moduledoc """
  Covers what the upload dialog says about the configured model servers.

  `Doctrans.Config.ReadinessTest` covers what the check finds; this covers what
  reaches the user -- that each finding arrives as a specific remediation rather
  than a code, that a check which could not be made is never rendered as an
  all-clear, that nothing it shows carries a credential, and that none of it
  stops the upload.

  Not async: every test swaps global `Application` env to configure the endpoints
  and the collaborators the probe runs against.
  """
  use DoctransWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Doctrans.Search.{
    EmbeddingErrorStub,
    EmbeddingExitStub,
    EmbeddingOptsStub
  }

  alias Doctrans.TestEnv
  alias DoctransWeb.DocumentLive.UploadReadiness
  alias DoctransWeb.ErrorMessages

  # These tests wait on real tasks. Cap well under ExUnit's 60s default so a
  # regression that wedges the probe is reported in seconds rather than stalling
  # the suite.
  @moduletag timeout: 10_000

  # Generous, because it waits on a task rather than on a render.
  @async_timeout 2_000

  @notice "#upload-readiness"
  @checking "#upload-readiness-checking"
  @unknown "#upload-readiness-unknown"
  @problems "#upload-readiness-problems"

  @models ["vision-model", "translation-model", "embedding-model"]

  # Mirrors `Doctrans.Config.ReadinessTest`: every setting the probe reads is
  # named here rather than inherited from `config/config.exs`, so a test cannot
  # pass because the shipped model names happened to line up.
  defp configure(opts \\ []) do
    TestEnv.put_env(:openai,
      base_url: Keyword.get(opts, :chat_url, "http://localhost:8000"),
      vision_model: Keyword.get(opts, :vision_model, "vision-model"),
      chat_model: "chat-model",
      translation_model: Keyword.get(opts, :translation_model, "translation-model")
    )

    TestEnv.put_env(:embedding,
      base_url: nil,
      model: Keyword.get(opts, :embedding_model, "embedding-model")
    )

    TestEnv.put_env(:openai_stub_models, Keyword.get(opts, :models, @models))

    if embedding_module = opts[:embedding_module] do
      TestEnv.put_env(:embedding_module, embedding_module)
    end
  end

  defp open_modal(view) do
    view |> element("#upload-document-btn") |> render_click()
    view
  end

  defp problem(code), do: "#{@problems} [data-readiness-problem=#{code}]"

  describe "a ready configuration" do
    test "says nothing at all once the check reports", %{conn: conn} do
      configure()

      {:ok, view, _html} = live(conn, ~p"/")
      view = open_modal(view)
      render_async(view, @async_timeout)

      # The live region stays, so the next open's checking line is an update to
      # an existing one; everything it can say is gone.
      assert has_element?(view, @notice)
      refute has_element?(view, @checking)
      refute has_element?(view, @unknown)
      refute has_element?(view, @problems)
    end

    test "reports while the probe is in flight, then replaces it", %{conn: conn} do
      configure()
      barrier = make_ref()
      TestEnv.put_env(:embedding_stub_barrier, {"readiness", self(), barrier})

      {:ok, view, _html} = live(conn, ~p"/")
      view = open_modal(view)

      assert_receive {:embedding_started, ^barrier, task_pid}, @async_timeout
      assert has_element?(view, @checking)

      send(task_pid, {:continue_embedding, barrier})
      render_async(view, @async_timeout)

      refute has_element?(view, @checking)
      refute has_element?(view, @problems)
    end
  end

  describe "unavailable models" do
    test "names the extraction model and the server to load it on", %{conn: conn} do
      configure(vision_model: "absent-vision-model")

      {:ok, view, _html} = live(conn, ~p"/")
      view = open_modal(view)
      render_async(view, @async_timeout)

      html = element_html(view, problem(:extraction_model_unavailable))

      assert html =~ "absent-vision-model"
      assert html =~ "localhost"
      assert html =~ "extraction model"
      refute has_element?(view, problem(:translation_model_unavailable))
    end

    test "names the translation model separately", %{conn: conn} do
      configure(translation_model: "absent-translation-model")

      {:ok, view, _html} = live(conn, ~p"/")
      view = open_modal(view)
      render_async(view, @async_timeout)

      assert element_html(view, problem(:translation_model_unavailable)) =~
               "absent-translation-model"

      refute has_element?(view, problem(:extraction_model_unavailable))
    end

    # The distinction the user acts on: a missing embedding model costs search,
    # not translation, and the line has to say so or it reads as a reason to
    # cancel an upload that would have worked.
    test "says an unavailable embedding model costs search rather than translation", %{conn: conn} do
      configure(embedding_model: "absent-embedding-model", embedding_module: EmbeddingErrorStub)
      TestEnv.put_env(:embedding_error_reason, :timeout)

      {:ok, view, _html} = live(conn, ~p"/")
      view = open_modal(view)
      render_async(view, @async_timeout)

      html = element_html(view, problem(:embedding_model_unavailable))

      assert html =~ "absent-embedding-model"
      assert html =~ "still translate"
      assert html =~ "searched"
    end

    test "reports both widths when the embedding model is too narrow", %{conn: conn} do
      configure(embedding_module: EmbeddingErrorStub)

      TestEnv.put_env(
        :embedding_error_reason,
        {:embedding_too_short, [expected: 1024, actual: 384]}
      )

      {:ok, view, _html} = live(conn, ~p"/")
      view = open_modal(view)
      render_async(view, @async_timeout)

      html = element_html(view, problem(:embedding_dimensions_too_small))

      assert html =~ "384"
      assert html =~ "1024"
      assert html =~ "embedding-model"
    end

    test "tells the user a silent server will leave the upload queued", %{conn: conn} do
      configure(models: :connection_refused, embedding_module: EmbeddingErrorStub)
      TestEnv.put_env(:embedding_error_reason, :timeout)

      {:ok, view, _html} = live(conn, ~p"/")
      view = open_modal(view)
      render_async(view, @async_timeout)

      html = element_html(view, problem(:inference_unavailable))

      assert html =~ "localhost"
      assert html =~ "queue"
      assert has_element?(view, problem(:embedding_unavailable))
    end
  end

  describe "a check that could not be made" do
    test "says so rather than rendering an all-clear", %{conn: conn} do
      configure(embedding_module: EmbeddingExitStub)

      log =
        capture_log(fn ->
          {:ok, view, _html} = live(conn, ~p"/")
          view = open_modal(view)
          render_async(view, @async_timeout)

          assert has_element?(view, @unknown)
          refute has_element?(view, @checking)
          refute has_element?(view, @problems)
        end)

      # This module's own line, isolated from the `Task` supervisor's crash
      # report on the same exit -- that report is written by OTP, dumps the
      # reason in full, and is not this module's to bound.
      warning =
        log
        |> String.split("\n")
        |> Enum.find("", &(&1 =~ "Readiness check crashed"))

      assert warning =~ "Readiness check crashed"

      # The exit reason carries a 1024-float vector. Eleven consecutive floats
      # would mean the `limit:` bound was dropped and the warning is now a dump.
      refute warning =~ String.duplicate("0.1, ", 11)
    end
  end

  describe "credentials" do
    test "no part of a credential-bearing endpoint reaches the dialog", %{conn: conn} do
      configure(
        chat_url: "http://user:s3cret@remote.example:8000/v1?key=abc",
        models: :connection_refused,
        embedding_module: EmbeddingErrorStub
      )

      TestEnv.put_env(:embedding_error_reason, :timeout)

      {:ok, view, _html} = live(conn, ~p"/")
      view = open_modal(view)
      render_async(view, @async_timeout)

      html = element_html(view, @notice)

      refute html =~ "s3cret"
      refute html =~ "abc"
      assert html =~ "remote.example"
    end
  end

  describe "the check is a report, not a gate" do
    test "a file can still be submitted while problems are showing", %{conn: conn} do
      configure(models: [])

      {:ok, view, _html} = live(conn, ~p"/")
      view = open_modal(view)
      render_async(view, @async_timeout)

      upload =
        file_input(view, "#upload-form", :document, [
          %{
            name: "readiness.pdf",
            content: "%PDF-1.7\n" <> String.duplicate("x", 2_000),
            type: "application/pdf"
          }
        ])

      render_upload(upload, "readiness.pdf")

      assert has_element?(view, @problems)
      refute has_element?(view, "#start-translation-btn[disabled]")
    end
  end

  describe "when the check runs" do
    test "on each open of the dialog, and never before one", %{conn: conn} do
      configure(embedding_module: EmbeddingOptsStub)
      TestEnv.put_env(:embedding_opts_observer, self())

      {:ok, view, _html} = live(conn, ~p"/")

      # Mounting the dashboard is not about to upload anything, and two HTTP
      # calls per visit would be paid by every reader.
      refute_receive {:embedding_opts, "readiness", _opts}, 100

      view = open_modal(view)
      assert_receive {:embedding_opts, "readiness", _opts}, @async_timeout
      render_async(view, @async_timeout)

      # Closing and reopening is the retry offered to a user who has just gone
      # and started their model server.
      render_click(view, "hide_upload_modal")
      view = open_modal(view)

      assert_receive {:embedding_opts, "readiness", _opts}, @async_timeout
      render_async(view, @async_timeout)
    end
  end

  # `Doctrans.Errors.reason/0` is a tagged tuple *or* a bare atom, and every
  # reason `check/0` builds today is the former. Rendered through the component
  # directly, because no configuration makes the domain module produce the other
  # one -- and a render that destructured the tuple inline would take the whole
  # dashboard down the day one is added.
  describe "a reason that is not a tagged tuple" do
    test "renders as a message rather than raising" do
      html =
        render_component(&UploadReadiness.readiness_notice/1,
          readiness: %{
            ready?: false,
            local?: true,
            destination: "",
            problems: [:models_unavailable]
          }
        )

      assert html =~ "data-readiness-problem=\"models_unavailable\""
      assert html =~ ErrorMessages.message(:models_unavailable)
    end
  end

  describe "locale" do
    test "the remediation is translated with the rest of the interface", %{conn: conn} do
      configure(vision_model: "absent-vision-model")

      {:ok, view, _html} = live(conn, ~p"/?lang=de")
      view = open_modal(view)
      render_async(view, @async_timeout)

      html = element_html(view, problem(:extraction_model_unavailable))

      assert html =~ "absent-vision-model"
      refute html =~ "is not available on"
    end
  end
end
