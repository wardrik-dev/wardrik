defmodule WardrikDaemon.OrgsTest do
  use ExUnit.Case, async: true

  import WardrikDaemon.Test

  alias WardrikDaemon.Ceiling
  alias WardrikDaemon.Config
  alias WardrikDaemon.Config.Orgs
  alias WardrikDaemon.Dirs

  setup context, do: dirs(context)

  defp read(context, text) do
    write(context, "config.yaml", text)
    Config.read(Dirs.new(context.env), context.env)
  end

  @yaml """
  org: platform
  mcp:
    stripe: {url: https://mcp.stripe.test}
    github: {url: https://mcp.github.test}
    search: {url: https://search.test/mcp}
    wiki: {url: https://wiki.test/mcp}
  channels:
    payments-slack: {type: slack, token: xoxb-1, signing_secret: s}
    all-slack: {type: slack, token: xoxb-2, signing_secret: s}
  notify:
    targets:
      audit: {webhook: {url: https://hooks.test/w}}
  orgs:
    "*":
      mcp: [search]
      channels: [all-slack]
      policy: base
    payments:
      mcp: [stripe, github]
      channels: [payments-slack]
      notify: [audit]
      policy: strict
    growth:
      mcp: [github]
  """

  test "gives each server, channel and target to the orgs that list it", context do
    assert {:ok, config} = read(context, @yaml)

    serves = fn kind, name ->
      for org <- ["platform", "payments", "growth", "deployment"],
          Orgs.serves?(config, kind: kind, name: name, org: org),
          do: org
    end

    assert Map.new(config.mcp, fn {name, _opts} -> {name, serves.(:mcp, name)} end) == %{
             "stripe" => ["payments", "deployment"],
             "github" => ["payments", "growth", "deployment"],
             "search" => ["platform", "payments", "growth", "deployment"],
             "wiki" => ["platform", "deployment"]
           }

    owners = Map.new(config.channels, fn {name, {_adapter, opts}} -> {name, opts[:owner]} end)
    assert owners == %{"payments-slack" => "payments", "all-slack" => "*"}

    assert [{"audit", {_module, opts}}] = Keyword.fetch!(config.notify, :targets)
    refute Keyword.has_key?(opts, :orgs)
    assert serves.(:notify, "audit") == ["payments", "deployment"]
  end

  test "refuses an org that names what isn't defined, a channel two orgs list, or a key it doesn't take",
       context do
    assert {:error, message} = read(context, "orgs: {payments: {mcp: [nope]}}")
    assert message =~ "orgs.payments.mcp: names nope, which mcp doesn't define"

    assert {:error, message} =
             read(context, """
             channels: {team: {type: slack, token: x, signing_secret: s}}
             orgs: {a: {channels: [team]}, b: {channels: [team]}}
             """)

    assert message =~
             ~s(channels.team: is listed by a and b; a channel serves one org, or every org under "*")

    assert {:error, message} = read(context, "orgs: {payments: {ceiling: 5}}")
    assert message =~ "orgs.payments: unknown options [:ceiling], valid options are: [:mcp,"

    assert {:error, message} = read(context, "orgs: {deployment: {}}")
    assert message =~ "orgs.deployment: is the deployment's own namespace"
  end

  describe "settings" do
    setup do
      base = WardrikPolicy.new!(budget: [usd: 50.0, per: :month])

      strict =
        WardrikPolicy.new!(
          deny: ["stripe/refund"],
          budget: [usd: 1.0, per: :turn]
        )

      orgs = %{
        "*" => %{mcp: [], channels: [], notify: [], policy: "base"},
        "payments" => %{mcp: [], channels: [], notify: [], policy: "strict"},
        "growth" => %{mcp: [], channels: [], notify: [], policy: "missing"},
        "ops" => %{mcp: [], channels: [], notify: [], policy: "unlimited"}
      }

      {:ok, unlimited} = WardrikPolicy.decode(%{"budget" => %{"per" => "day"}})
      policies = %{"base" => base, "strict" => strict, "unlimited" => unlimited}
      %{config: %{org: "platform", orgs: orgs, policies: policies}}
    end

    test "hold an org to every org's policy, then its own, pooling each budget but a turn's", %{
      config: config
    } do
      assert {:ok, %{policy: [base, strict], ceilings: [pooled]}} =
               WardrikDaemon.Orgs.settings("payments", config)

      assert base.budget == nil
      assert %WardrikPolicy.Budget{usd: 1.0, per: :turn} = strict.budget

      assert %Ceiling{name: "base", budget: %{usd: 50.0, per: :month}, on_exhausted: :ask} =
               pooled

      assert {:ok, %{policy: [_base]}} = WardrikDaemon.Orgs.settings("platform", config)
    end

    test "refuse an org config.yaml doesn't declare, and run none of one whose policy is missing",
         %{
           config: config
         } do
      assert {:error, %Wardrik.Error{type: :not_found, message: message}} =
               WardrikDaemon.Orgs.settings("globex", config)

      assert message ==
               "There's no org globex here: config.yaml declares growth, ops, payments, platform."

      assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
               WardrikDaemon.Orgs.settings("growth", config)

      assert message =~ "growth is held to the policy missing, which policies/ doesn't hold"

      assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
               WardrikDaemon.Orgs.settings("ops", config)

      assert message == "ops's ceiling unlimited: a ceiling sets usd, tokens or both."
      assert WardrikDaemon.Orgs.known("platform", config) == :ok
    end
  end
end
