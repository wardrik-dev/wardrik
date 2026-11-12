defmodule WardrikTriggersTest do
  use ExUnit.Case, async: false

  alias WardrikTriggers.Test.FailingStore
  alias WardrikTriggers.Trigger

  @agent "acme/digest"

  setup context do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")
    name = :"triggers #{context.test}"
    answer = Map.get(context, :answer, :asked)

    start_supervised!({WardrikStore, store})

    start_supervised!(
      {WardrikTriggers,
       name: name,
       store: store,
       target: {WardrikTriggers.Test.Target, %{test: self(), answer: answer}},
       req_options: [plug: {Req.Test, __MODULE__}, retry_delay: 0],
       reconcile: :infinity}
    )

    %{triggers: name, store: WardrikStore.scope(store, "wardrik_triggers")}
  end

  defp due(store, triggers, name, ago) do
    key = "triggers/" <> URI.encode_www_form(@agent) <> "/" <> name
    {record, _vsn} = WardrikStore.lookup(store, key)
    next_at = DateTime.utc_now() |> DateTime.add(-ago) |> DateTime.to_iso8601()
    {:ok, _vsn} = WardrikStore.put(store, key, %{record | "next_at" => next_at})
    :ok = WardrikTriggers.reconcile(triggers)
  end

  defp feed(items) do
    entries =
      Enum.map_join(items, fn id -> "<item><title>#{id}</title><guid>#{id}</guid></item>" end)

    "<rss><channel>#{entries}</channel></rss>"
  end

  defp serve(xml) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("etag", "\"v1\"")
      |> Plug.Conn.send_resp(200, xml)
    end)
  end

  test "says which triggers aren't started" do
    assert_raise ArgumentError, ~r/^MyApp.Missing isn't started/, fn ->
      WardrikTriggers.list(MyApp.Missing, "acme/digest")
    end
  end

  describe "keeping triggers" do
    test "gives an agent its triggers, each with its next run", %{triggers: triggers} do
      :ok =
        WardrikTriggers.put(triggers, @agent, [
          %{"name" => "daily", "every" => "0 9 * * *", "prompt" => "Go."}
        ])

      assert [{%Trigger{name: "daily"}, %DateTime{} = next_at}] =
               WardrikTriggers.list(triggers, @agent)

      assert DateTime.after?(next_at, DateTime.utc_now())
    end

    test "gives each agent's earliest scheduled run, in one read", %{triggers: triggers} do
      :ok =
        WardrikTriggers.put(triggers, @agent, [
          %{"name" => "daily", "every" => "1d", "prompt" => "Go."},
          %{"name" => "hourly", "every" => "1h", "prompt" => "Go."}
        ])

      :ok =
        WardrikTriggers.put(triggers, "acme/other", [
          %{"name" => "hook", "webhook" => %{"secret" => "${HOOK_SECRET}"}, "prompt" => "Go."}
        ])

      [_daily, {_hourly, hourly}] = WardrikTriggers.list(triggers, @agent)

      assert WardrikTriggers.next_runs(triggers, [@agent, "acme/other", "acme/none"]) ==
               %{@agent => hourly}
    end

    test "keeps a trigger's next run while its clock stays, and replaces the rest", %{
      triggers: triggers
    } do
      :ok =
        WardrikTriggers.put(triggers, @agent, [
          %{"name" => "a", "every" => "1d", "prompt" => "Go."},
          %{"name" => "b", "every" => "1h", "prompt" => "Go."}
        ])

      [{_a, next_at}, _b] = WardrikTriggers.list(triggers, @agent)

      :ok =
        WardrikTriggers.put(triggers, @agent, [
          %{"name" => "a", "every" => "1d", "prompt" => "Changed."}
        ])

      assert [{%Trigger{prompt: "Changed."}, ^next_at}] = WardrikTriggers.list(triggers, @agent)

      :ok =
        WardrikTriggers.put(triggers, @agent, [
          %{"name" => "a", "every" => "2d", "prompt" => "Go."}
        ])

      assert [{_a, moved}] = WardrikTriggers.list(triggers, @agent)
      refute moved == next_at

      :ok = WardrikTriggers.put(triggers, @agent, [])
      assert WardrikTriggers.list(triggers, @agent) == []
    end

    test "sets and removes one trigger, and says what doesn't read", %{triggers: triggers} do
      assert {:ok, %Trigger{name: "hook"}} =
               WardrikTriggers.set(triggers, @agent, %{
                 "name" => "hook",
                 "webhook" => %{"secret" => "${HOOK_SECRET}"},
                 "prompt" => "Go."
               })

      assert [{%Trigger{name: "hook"}, nil}] = WardrikTriggers.list(triggers, @agent)
      assert :ok = WardrikTriggers.remove(triggers, agent_id: @agent, name: "hook")

      assert {:error, :not_found} =
               WardrikTriggers.remove(triggers, agent_id: @agent, name: "hook")

      assert {:error, "a trigger has every, or a webhook"} =
               WardrikTriggers.set(triggers, @agent, %{"prompt" => "Go."})

      assert {:error, "a trigger has every" <> _} =
               WardrikTriggers.put(triggers, @agent, [%{"prompt" => "Go."}])
    end

    test "says when the store fails partway, and finishes the change when put again", context do
      store = FailingStore.new(:"failing #{context.test}")
      triggers = :"failing triggers #{context.test}"
      start_supervised!({WardrikStore, store}, id: :failing_store)

      start_supervised!(
        {WardrikTriggers,
         name: triggers,
         store: store,
         target: {WardrikTriggers.Test.Target, %{test: self(), answer: :asked}},
         reconcile: :infinity},
        id: :failing_triggers
      )

      before = for name <- ~w(a b c), do: %{"name" => name, "every" => "1d", "prompt" => "Go."}
      later = for name <- ~w(a d), do: %{"name" => name, "every" => "1d", "prompt" => "Again."}

      for n <- 1..4 do
        :ok = WardrikTriggers.put(triggers, @agent, before)
        FailingStore.fail_on(store, n)

        assert {:error, :unavailable} = WardrikTriggers.put(triggers, @agent, later)
        assert :ok = WardrikTriggers.put(triggers, @agent, later)

        assert [{%Trigger{name: "a", prompt: "Again."}, _}, {%Trigger{name: "d"}, _}] =
                 WardrikTriggers.list(triggers, @agent)
      end

      FailingStore.fail_on(store, 1)
      assert {:error, :unavailable} = WardrikTriggers.set(triggers, @agent, hd(before))
      assert [{%Trigger{prompt: "Again."}, _}, _d] = WardrikTriggers.list(triggers, @agent)
    end
  end

  describe "on a clock" do
    setup %{triggers: triggers} do
      :ok =
        WardrikTriggers.put(triggers, @agent, [
          %{"name" => "daily", "every" => "1d", "prompt" => "Write it."}
        ])
    end

    test "asks the agent once its trigger comes due, and moves its next run on", %{
      triggers: triggers,
      store: store
    } do
      due(store, triggers, "daily", 5)

      assert_receive {:asked, @agent, "Write it.",
                      [trigger: "daily", overlap: :settle, labels: []]}

      assert_receive {:fired, @agent, "daily", :asked}

      assert [{_daily, next_at}] = WardrikTriggers.list(triggers, @agent)
      assert DateTime.diff(next_at, DateTime.utc_now(), :hour) >= 23
    end

    @tag answer: :busy
    test "says when the agent was busy", %{triggers: triggers, store: store} do
      due(store, triggers, "daily", 5)
      assert_receive {:fired, @agent, "daily", :busy}
    end

    @tag answer: {:error, :down}
    test "says when asking failed", %{triggers: triggers, store: store} do
      due(store, triggers, "daily", 5)
      assert_receive {:fired, @agent, "daily", :failed}
    end

    test "runs once for what it missed, or lets it go", %{triggers: triggers, store: store} do
      due(store, triggers, "daily", 600)
      assert_receive {:asked, @agent, "Write it.", _opts}
      assert_receive {:fired, @agent, "daily", :asked}

      :ok =
        WardrikTriggers.put(triggers, @agent, [
          %{"name" => "daily", "every" => "1d", "missed" => "skip", "prompt" => "Write it."}
        ])

      due(store, triggers, "daily", 600)

      assert_receive {:fired, @agent, "daily", :missed}
      refute_received {:asked, _agent, _prompt, _opts}
    end
  end

  describe "watching a feed" do
    setup %{triggers: triggers} do
      :ok =
        WardrikTriggers.put(triggers, @agent, [
          %{
            "name" => "rivals",
            "every" => "6h",
            "feed" => "https://r.test/rss",
            "prompt" => "What changed?"
          }
        ])
    end

    test "notes what a feed holds first, then asks about what's new", %{
      triggers: triggers,
      store: store
    } do
      serve(feed(["r-1"]))
      due(store, triggers, "rivals", 5)
      assert_receive {:fired, @agent, "rivals", :nothing_new}

      serve(feed(["r-2", "r-1"]))
      due(store, triggers, "rivals", 5)
      assert_receive {:asked, @agent, "What changed?\n\nr-2", opts}
      assert opts[:labels] == ["outside"]
      assert_receive {:fired, @agent, "rivals", :asked}

      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-none-match") == ["\"v1\""]
        Plug.Conn.send_resp(conn, 304, "")
      end)

      due(store, triggers, "rivals", 5)
      assert_receive {:fired, @agent, "rivals", :nothing_new}
    end

    test "fails a run when no feed reads", %{triggers: triggers, store: store} do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 500, "down"))
      due(store, triggers, "rivals", 5)
      assert_receive {:fired, @agent, "rivals", :failed}

      serve("not xml at all <")
      due(store, triggers, "rivals", 5)
      assert_receive {:fired, @agent, "rivals", :failed}
    end
  end

  describe "receiving a webhook" do
    setup %{triggers: triggers} do
      :ok =
        WardrikTriggers.put(triggers, @agent, [
          %{
            "name" => "issues",
            "webhook" => %{"secret" => "${HOOK_SECRET}"},
            "prompt" => "Triage it."
          },
          %{"name" => "signed", "webhook" => %{"secret" => "${MISSING}"}, "prompt" => "Go."},
          %{"name" => "daily", "every" => "1d", "prompt" => "Go."}
        ])
    end

    defp hook(body, secret \\ "s3cret"),
      do: %{body: body, headers: %{"authorization" => "Bearer " <> secret}, path_secret: nil}

    test "asks the agent about each request once", %{triggers: triggers} do
      assert :ok =
               WardrikTriggers.deliver(triggers,
                 agent_id: @agent,
                 name: "issues",
                 request: hook("{\"id\":1}")
               )

      assert_receive {:asked, @agent, "Triage it.\n\n{\"id\":1}",
                      [trigger: "issues", overlap: :queue, labels: ["outside"]]}

      assert_receive {:fired, @agent, "issues", :asked}

      assert :ok =
               WardrikTriggers.deliver(triggers,
                 agent_id: @agent,
                 name: "issues",
                 request: hook("{\"id\":1}")
               )

      refute_received {:asked, _agent, _prompt, _opts}
    end

    test "turns away what doesn't prove itself, or isn't a webhook", %{triggers: triggers} do
      assert {:error, :not_found} =
               WardrikTriggers.deliver(triggers,
                 agent_id: @agent,
                 name: "issues",
                 request: hook("{}", "nope")
               )

      assert {:error, :not_found} =
               WardrikTriggers.deliver(triggers,
                 agent_id: @agent,
                 name: "signed",
                 request: hook("{}")
               )

      assert {:error, :not_found} =
               WardrikTriggers.deliver(triggers,
                 agent_id: @agent,
                 name: "daily",
                 request: hook("{}")
               )

      assert {:error, :not_found} =
               WardrikTriggers.deliver(triggers,
                 agent_id: @agent,
                 name: "missing",
                 request: hook("{}")
               )

      refute_received {:asked, _agent, _prompt, _opts}
    end

    @tag answer: :busy
    test "says when it can't be asked now, and asks again when it's sent again", %{
      triggers: triggers
    } do
      assert {:error, :busy} =
               WardrikTriggers.deliver(triggers,
                 agent_id: @agent,
                 name: "issues",
                 request: hook("{}")
               )

      assert {:error, :busy} =
               WardrikTriggers.deliver(triggers,
                 agent_id: @agent,
                 name: "issues",
                 request: hook("{}")
               )

      assert_receive {:asked, @agent, _prompt, _opts}
      assert_receive {:asked, @agent, _prompt, _opts}
    end
  end
end
