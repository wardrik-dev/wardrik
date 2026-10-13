defmodule WardrikDaemon.SecretsTest do
  use ExUnit.Case, async: false

  alias WardrikDaemon.Secrets
  alias WardrikDaemon.Test.Settings

  @variables ["ANTHROPIC_API_KEY", "SEARCH_API_KEY"]

  setup do
    previous = %{
      anthropic: Application.get_env(:req_llm, :anthropic_api_key),
      environment: Map.new(@variables, &{&1, System.get_env(&1)})
    }

    Settings.keep()
    :ok = Settings.vault()
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(@variables, &WardrikVault.forget(&1, nil))
      restore(:req_llm, :anthropic_api_key, previous.anthropic)

      for {name, value} <- previous.environment,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  test "reads an agent's secret as its user's, its org's, the deployment's, then the environment's" do
    name = "HOOK_SECRET_#{System.unique_integer([:positive])}"
    jon = Wardrik.AgentID.parse!("acme/@jon/triage")
    acme = Wardrik.AgentID.parse!("acme/triage")
    globex = Wardrik.AgentID.parse!("globex/triage")

    on_exit(fn ->
      System.delete_env(name)
      for owner <- [{"acme", "jon"}, "acme", nil], do: WardrikVault.forget(name, owner)
    end)

    assert Secrets.for_agent(name, acme) == nil
    System.put_env(name, "environment's")
    assert Secrets.for_agent(name, acme) == "environment's"

    :ok = WardrikVault.put(name, nil, "deployment's")
    :ok = WardrikVault.put(name, "acme", "acme's")
    :ok = WardrikVault.put(name, {"acme", "jon"}, "jon's")

    assert Secrets.for_agent(name, jon) == "jon's"
    assert Secrets.for_agent(name, acme) == "acme's"
    assert Secrets.for_agent(name, globex) == "deployment's"
  end

  test "names each provider's key variable, and no other" do
    variables = Secrets.variables()

    assert variables["ANTHROPIC_API_KEY"] == [{:req_llm, :anthropic_api_key}]
    assert {:req_llm, :zai_coding_plan_api_key} in variables["ZAI_API_KEY"]
    assert Secrets.key?("ANTHROPIC_API_KEY")
    refute Secrets.key?("SEARCH_API_KEY")
    refute Secrets.key?("LINEAR_TOKEN")
  end

  test "gives a provider the vault's key where the environment sets none" do
    :ok = WardrikVault.put("ANTHROPIC_API_KEY", nil, "sk-ant-vault")
    :ok = WardrikVault.put("SEARCH_API_KEY", nil, "search-vault")

    assert Secrets.apply() == :ok
    assert ReqLLM.Keys.get(:anthropic) == {:ok, "sk-ant-vault", :application}
    refute "search-vault" in Keyword.values(Application.get_all_env(:req_llm))
  end

  test "leaves a key the environment sets to the environment" do
    :ok = WardrikVault.put("ANTHROPIC_API_KEY", nil, "sk-ant-vault")
    Application.delete_env(:req_llm, :anthropic_api_key)
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-environment")

    assert Secrets.apply() == :ok
    assert Secrets.place("ANTHROPIC_API_KEY", "sk-ant-placed") == :ok
    assert Application.get_env(:req_llm, :anthropic_api_key) == nil
    assert ReqLLM.Keys.get(:anthropic) == {:ok, "sk-ant-environment", :system}
  end

  test "places a key it is handed, clears it with nil, and places no other name" do
    assert Secrets.place("ANTHROPIC_API_KEY", "sk-ant-placed") == :ok
    assert ReqLLM.Keys.get(:anthropic) == {:ok, "sk-ant-placed", :application}

    assert Secrets.place("ANTHROPIC_API_KEY", nil) == :ok
    assert {:error, _none} = ReqLLM.Keys.get(:anthropic)

    assert Secrets.place("LINEAR_TOKEN", "lin") == :ok
    refute Application.get_all_env(:req_llm) |> Keyword.values() |> Enum.member?("lin")
  end

  test "reads the deployment's secret, or nothing" do
    :ok = WardrikVault.put("ANTHROPIC_API_KEY", nil, "sk-ant-vault")

    assert Secrets.named("ANTHROPIC_API_KEY") == "sk-ant-vault"
    assert Secrets.named("NOT_IN_THE_VAULT") == nil

    :ok = Settings.no_vault()
    assert Secrets.named("ANTHROPIC_API_KEY") == nil
  end
end
