defmodule Wardrik.ResourceTest do
  use ExUnit.Case, async: true

  alias Wardrik.Resource

  import Wardrik.AgentID, only: [sigil_A: 2]

  defp r(text), do: Resource.parse!(text)

  describe "parse/1" do
    test "reads namespaces and what is in them" do
      for text <-
            ~w(acme acme/@jon deployment acme/agent/triage acme/@jon/agent/triage/thread/1696.1234
                     acme/agent/triage/trigger/hook acme/server/crm deployment/secret/LINEAR_API_KEY
                     deployment/token/0192) do
        assert {:ok, %Resource{name: ^text}} = Resource.parse(text)
      end
    end

    test "reads patterns up to their first wildcard" do
      for text <- ~w(* acme/* acme/agent/* */agent/* acme/@*/agent/* acme/agent/tri?ge) do
        assert {:ok, _pattern} = Resource.parse(text), text
      end
    end

    test "refuses unknown types, names that are not segments, and the deployment as an org" do
      for text <-
            [
              "",
              "acme/",
              "acme/agnet/*",
              "acme/agent",
              "acme/agent/_kept",
              "acme/@jon/@sam",
              "deployment/@jon",
              "acme/agent/tri age",
              "_acme",
              "acme/agent/../x"
            ] do
        assert {:error, message} = Resource.parse(text), text
        assert message =~ "is not a resource"
      end

      assert_raise ArgumentError, fn -> Resource.parse!("acme/robot/triage") end
    end
  end

  test "new/2 names what a resource holds, and refuses a name that is not a segment" do
    assert Resource.new(Resource.deployment(), server: "github") == r("deployment/server/github")

    assert Resource.new(r("acme"), agent: "triage", thread: "1") ==
             r("acme/agent/triage/thread/1")

    assert_raise ArgumentError, fn -> Resource.new(r("acme"), server: "*") end
    assert_raise ArgumentError, fn -> Resource.new(r("acme"), server: "a/agent/b") end
  end

  test "owner/1 is the namespace a resource is in" do
    assert Resource.owner(r("acme/@jon/agent/triage")) == r("acme/@jon")
    assert Resource.owner(r("acme/agent/triage/thread/1")) == r("acme")
    assert Resource.owner(r("deployment/server/github")) == Resource.deployment()
    assert Resource.owner(r("acme/@jon")) == r("acme/@jon")
  end

  test "org/1 is the org a resource is in" do
    assert Resource.org(r("acme/@jon/agent/triage")) == r("acme")
    assert Resource.org(r("acme/@jon")) == r("acme")
    assert Resource.org(r("acme")) == r("acme")
    assert Resource.org(r("deployment/server/github")) == Resource.deployment()
  end

  test "basename/1 is the name a resource ends in" do
    assert Resource.basename(r("acme/server/crm")) == "crm"
  end

  describe "covers?/2" do
    test "matches * across segments and ? as one character" do
      assert Resource.covers?(r("*"), r("deployment/token/1"))
      assert Resource.covers?(r("acme/*"), r("acme/@jon/agent/triage"))
      assert Resource.covers?(r("acme/agent/*"), r("acme/agent/triage/thread/1"))
      refute Resource.covers?(r("acme/agent/*"), r("acme/@jon/agent/triage"))
      refute Resource.covers?(r("acme/*"), r("acmecorp/agent/triage"))
      assert Resource.covers?(r("acme/agent/tri?ge"), r("acme/agent/triage"))
      refute Resource.covers?(r("acme/agent/tri?ge"), r("acme/agent/trige"))
    end

    test "implies nothing beyond the name" do
      refute Resource.covers?(r("acme/agent/triage"), r("acme/agent/triage/thread/1"))
      refute Resource.covers?(r("acme/agent/triage/*"), r("acme/agent/triage"))
      assert Resource.covers?(r("acme/agent/triage"), r("acme/agent/triage"))
    end

    test "covers a pattern only where it covers every name the pattern does" do
      assert Resource.covers?(r("*"), r("acme/*"))
      assert Resource.covers?(r("acme/*"), r("acme/agent/*"))
      refute Resource.covers?(r("acme/agent/*"), r("acme/*"))
      refute Resource.covers?(r("acme/agent/tri?ge"), r("acme/agent/tri*ge"))
      assert Resource.covers?(r("acme/agent/tri?ge"), r("acme/agent/tri?ge"))
    end

    test "reads each character of a name as itself" do
      refute Resource.covers?(r("acme/agent/a.c"), r("acme/agent/abc"))
      assert Resource.covers?(r("acme/agent/é*"), r("acme/agent/été"))
      assert Resource.covers?(r("acme/agent/?t?"), r("acme/agent/été"))
      refute Resource.covers?(r("acme/agent/ab"), r("acme/agent/abc"))
      refute Resource.covers?(r("acme/agent/abc"), r("acme/agent/ab"))
    end

    test "takes no longer for a pattern of many stars than its length allows" do
      many = "acme/agent/" <> String.duplicate("a*", 30) <> "b"
      name = "acme/agent/" <> String.duplicate("a", 200)

      {microseconds, covered?} = :timer.tc(fn -> Resource.covers?(r(many), r(name)) end)

      refute covered?
      assert microseconds < 1_000_000
      assert Resource.covers?(r("acme/*/*/thread/*"), r("acme/agent/triage/thread/1"))
      assert Resource.covers?(r("a*e/agent/*ia*e"), r("acme/agent/triage"))
    end
  end

  test "an agent's ID is its resource's" do
    assert Wardrik.AgentID.resource(~A"acme/@jon/triage/1696.1234") ==
             r("acme/@jon/agent/triage/thread/1696.1234")

    assert to_string(Wardrik.AgentID.resource(~A"acme/triage")) == "acme/agent/triage"
    assert inspect(r("acme")) == "#Wardrik.Resource<acme>"
  end
end
