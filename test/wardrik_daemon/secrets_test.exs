defmodule WardrikDaemon.SecretsTest do
  use ExUnit.Case, async: false

  alias WardrikDaemon.Secrets

  @tool WardrikDaemon.SecretsTest.Search
  @variables ["ANTHROPIC_API_KEY", "SEARCH_API_KEY"]

  setup do
    previous = %{
      vault: Application.get_env(:wardrik, WardrikVault),
      secrets: Application.get_env(:wardrik, Secrets),
      anthropic: Application.get_env(:req_llm, :anthropic_api_key),
      environment: Map.new(@variables, &{&1, System.get_env(&1)})
    }

    Application.put_env(:wardrik, WardrikVault, keys: [WardrikVault.generate_key()])

    Application.put_env(:wardrik, Secrets,
      keys: %{"SEARCH_API_KEY" => {:wardrik, @tool, :api_key}}
    )

    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(@variables, &WardrikVault.forget({:named, &1}, nil))
      Application.delete_env(:wardrik, @tool)
      restore(:wardrik, WardrikVault, previous.vault)
      restore(:wardrik, Secrets, previous.secrets)
      restore(:req_llm, :anthropic_api_key, previous.anthropic)

      for {name, value} <- previous.environment,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  test "names each provider's key variable, and each tool's :keys names" do
    variables = Secrets.variables()

    assert variables["ANTHROPIC_API_KEY"] == [{:req_llm, :anthropic_api_key}]
    assert {:req_llm, :zai_coding_plan_api_key} in variables["ZAI_API_KEY"]
    assert variables["SEARCH_API_KEY"] == [{:wardrik, @tool, :api_key}]
    assert Secrets.key?("ANTHROPIC_API_KEY")
    refute Secrets.key?("LINEAR_TOKEN")
  end

  test "gives a provider and a tool the vault's key where the environment sets none" do
    :ok = WardrikVault.put({:named, "ANTHROPIC_API_KEY"}, nil, "sk-ant-vault")
    :ok = WardrikVault.put({:named, "SEARCH_API_KEY"}, nil, "search-vault")

    assert Secrets.apply() == :ok
    assert ReqLLM.Keys.get(:anthropic) == {:ok, "sk-ant-vault", :application}
    assert Application.get_env(:wardrik, @tool)[:api_key] == "search-vault"
  end

  test "leaves a key the environment sets to the environment" do
    :ok = WardrikVault.put({:named, "ANTHROPIC_API_KEY"}, nil, "sk-ant-vault")
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
    :ok = WardrikVault.put({:named, "ANTHROPIC_API_KEY"}, nil, "sk-ant-vault")

    assert Secrets.named("ANTHROPIC_API_KEY") == "sk-ant-vault"
    assert Secrets.named("NOT_IN_THE_VAULT") == nil

    Application.delete_env(:wardrik, WardrikVault)
    assert Secrets.named("ANTHROPIC_API_KEY") == nil
  end
end
