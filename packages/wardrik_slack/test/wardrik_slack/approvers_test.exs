defmodule WardrikSlack.ApproversTest do
  use ExUnit.Case, async: true

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias WardrikChannel.Outbound
  alias WardrikNotify.Notice
  alias WardrikSlack.Approvers

  @req_options [plug: {Req.Test, __MODULE__}, retry: false]

  # Slack as a workspace whose members are U1 @maria (maria@example.com) on
  # the first page of users.list, and U2 @jon on the second; it refuses to
  # message anyone in `refused`.
  defp slack(refused \\ []) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      body = Req.Test.raw_body(conn)

      params =
        case JSON.decode(body) do
          {:ok, json} -> json
          {:error, _form} -> URI.decode_query(body)
        end

      send(test, {:slack, conn.request_path, params})
      Req.Test.json(conn, answer(conn.request_path, params, refused))
    end)

    [token: "xoxb-#{System.unique_integer([:positive])}", req_options: @req_options]
  end

  defp answer("/api/users.lookupByEmail", %{"email" => "maria@example.com"}, _refused),
    do: %{ok: true, user: %{id: "U1"}}

  defp answer("/api/users.lookupByEmail", _params, _refused),
    do: %{ok: false, error: "users_not_found"}

  defp answer("/api/users.list", %{"cursor" => "page2"}, _refused),
    do: %{ok: true, members: [%{id: "U2", name: "jon"}], response_metadata: %{next_cursor: ""}}

  defp answer("/api/users.list", _params, _refused),
    do: %{
      ok: true,
      members: [%{id: "U9", name: "jon", deleted: true}, %{id: "U1", name: "maria"}],
      response_metadata: %{next_cursor: "page2"}
    }

  defp answer("/api/chat.getPermalink", _params, _refused),
    do: %{ok: true, permalink: "https://acme.slack.com/archives/C1/p11"}

  defp answer("/api/chat.postMessage", %{"channel" => channel}, refused) do
    if channel in refused,
      do: %{ok: false, error: "messages_tab_disabled"},
      else: %{ok: true, ts: "9.9"}
  end

  defp parked do
    %Notice{
      agent: ~A"acme/books/C1-1.1",
      kind: :parked,
      at: ~U[2026-10-09 09:30:00Z],
      calls: [
        %{id: "call_1", name: "create_bill", arguments: %{}, prompt: "This posts."},
        %{
          id: "call_2",
          name: "github__issues",
          arguments: %{},
          prompt: "Connect github.",
          authorization: true
        }
      ]
    }
  end

  defp asking(approvers, opts) do
    %Outbound{
      installation: WardrikSlack.Test.installation(opts[:token]),
      room: "C1",
      thread: "1.1",
      body: {:notice, parked()},
      approvers: approvers,
      to: :approvers
    }
  end

  test "finds each approver as a member: an id as it is, an email address, a handle" do
    opts = slack()

    assert Approvers.members(["U7", "maria@example.com", "@jon", "@nobody"], opts) == [
             {"U7", {:ok, "U7"}},
             {"maria@example.com", {:ok, "U1"}},
             {"@jon", {:ok, "U2"}},
             {"@nobody", :error}
           ]

    assert_receive {:slack, "/api/users.list", %{"cursor" => "page2", "limit" => "200"}}
  end

  test "looks each found approver up once" do
    opts = slack()

    assert [{"@jon", {:ok, "U2"}}] = Approvers.members(["@jon"], opts)
    assert_receive {:slack, "/api/users.list", _first}
    assert_receive {:slack, "/api/users.list", _second}

    assert [{"@jon", {:ok, "U2"}}] = Approvers.members(["@jon"], opts)
    refute_receive {:slack, "/api/users.list", _again}
  end

  test "knows a member among those named by id, email address or handle" do
    opts = slack()

    installation = WardrikSlack.Test.installation(opts[:token])
    opts = Keyword.delete(opts, :token)

    assert WardrikSlack.among?(installation, "U1", ["U7", "maria@example.com"], opts)
    assert WardrikSlack.among?(installation, "U2", ["@nobody", "@jon"], opts)
    assert WardrikSlack.among?(installation, "U7", ["U7"], opts)
    refute WardrikSlack.among?(installation, "U2", ["U7", "maria@example.com"], opts)
  end

  test "names the approvers in a sentence, a member id as Slack shows one" do
    assert Approvers.named(["@maria"]) == "@maria"
    assert Approvers.named(["@maria", "U2"]) == "@maria or <@U2>"
    assert Approvers.named(["@maria", "@jon", "a@b.c"]) == "@maria, @jon or a@b.c"
  end

  test "asks each approver directly, from a link to the thread, and says so in the thread" do
    opts = slack() ++ [app_token: "xapp-1"]

    assert {:ok, _posted} = WardrikSlack.deliver(asking(["@maria", "U5", "@nobody"], opts), opts)

    for member <- ["U1", "U5"] do
      assert_receive {:slack, "/api/chat.postMessage", %{"channel" => ^member} = asked}
      refute Map.has_key?(asked, "thread_ts")

      assert [_heading, %{"type" => "context", "elements" => [%{"text" => from}]} | rest] =
               asked["blocks"]

      assert from == "From <https://acme.slack.com/archives/C1/p11|a thread> in <#C1>."
      assert Enum.any?(rest, &(&1["type"] == "actions"))
    end

    assert_receive {:slack, "/api/chat.postMessage", %{"channel" => "C1"} = said}

    assert said == %{
             "channel" => "C1",
             "thread_ts" => "1.1",
             "text" =>
               "Waiting on @maria, <@U5> or @nobody to approve `create_bill` and " <>
                 "connect an account for `github__issues`."
           }
  end

  test "asks in the thread where it reaches none of the approvers" do
    opts = slack(["U1"]) ++ [app_token: "xapp-1"]

    assert {:ok, _posted} = WardrikSlack.deliver(asking(["@maria", "@nobody"], opts), opts)

    assert_receive {:slack, "/api/chat.postMessage", %{"channel" => "U1"}}

    assert_receive {:slack, "/api/chat.postMessage",
                    %{"channel" => "C1", "thread_ts" => "1.1", "blocks" => blocks}}

    assert Enum.any?(blocks, &(&1["type"] == "actions"))
  end
end
