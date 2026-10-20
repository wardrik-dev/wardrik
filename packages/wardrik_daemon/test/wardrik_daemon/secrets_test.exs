defmodule WardrikDaemon.SecretsTest do
  use ExUnit.Case, async: false

  alias WardrikDaemon.Secrets
  alias WardrikDaemon.Test.Settings

  @variables ["ANTHROPIC_API_KEY", "SEARCH_API_KEY"]

  setup do
    previous = %{environment: Map.new(@variables, &{&1, System.get_env(&1)})}

    :ok = Settings.vault()
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(@variables, &WardrikVault.forget(vault(), &1, Wardrik.Resource.deployment()))

      for {name, value} <- previous.environment,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)
  end

  defp vault, do: Settings.held_vault()

  test "reads an agent's secret as its owner holds it, and no other" do
    name = "HOOK_SECRET_#{System.unique_integer([:positive])}"
    jon = Wardrik.AgentID.parse!("acme/@jon/triage")
    ann = Wardrik.AgentID.parse!("acme/@ann/triage")
    acme = Wardrik.AgentID.parse!("acme/triage")
    globex = Wardrik.AgentID.parse!("globex/triage")

    on_exit(fn ->
      System.delete_env(name)

      for owner <- Enum.map(~w(acme/@jon acme deployment), &Wardrik.Resource.parse!/1),
          do: WardrikVault.forget(vault(), name, owner)
    end)

    System.put_env(name, "environment's")
    :ok = WardrikVault.put(vault(), name, Wardrik.Resource.deployment(), value: "deployment's")
    :ok = WardrikVault.put(vault(), name, Wardrik.Resource.parse!("acme"), value: "acme's")
    :ok = WardrikVault.put(vault(), name, Wardrik.Resource.parse!("acme/@jon"), value: "jon's")

    assert Secrets.for_agent(vault(), name, jon) == "jon's"
    assert Secrets.for_agent(vault(), name, acme) == "acme's"
    assert Secrets.for_agent(vault(), name, ann) == nil
    assert Secrets.for_agent(vault(), name, globex) == nil
  end

  test "knows a provider's key variable from any other name" do
    assert Secrets.key?("ANTHROPIC_API_KEY")
    assert Secrets.key?("ZAI_API_KEY")
    refute Secrets.key?("SEARCH_API_KEY")
    refute Secrets.key?("LINEAR_TOKEN")
  end

  test "a provider's key the vault holds reaches a model call as its key, the environment's first" do
    :ok =
      WardrikVault.put(vault(), "ANTHROPIC_API_KEY", Wardrik.Resource.deployment(),
        value: "sk-ant-vault"
      )

    assert Wardrik.Credentials.key(vault(), "ANTHROPIC_API_KEY") == {:ok, "sk-ant-vault"}
    assert Wardrik.Credentials.key(vault(), "SEARCH_API_KEY") == :error
  end

  test "reads the deployment's secret, or nothing" do
    :ok =
      WardrikVault.put(vault(), "ANTHROPIC_API_KEY", Wardrik.Resource.deployment(),
        value: "sk-ant-vault"
      )

    assert Secrets.named(vault(), "ANTHROPIC_API_KEY") == "sk-ant-vault"
    assert Secrets.named(vault(), "NOT_IN_THE_VAULT") == nil

    :ok = Settings.no_vault()
    assert Secrets.named(vault(), "ANTHROPIC_API_KEY") == nil
  end
end
