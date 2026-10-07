defmodule Deploy.HetznerTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  # The files deploy/hetzner/cloud-init.yaml writes onto the box, read as the
  # daemon there reads them, so a file the box would refuse fails here first.
  @cloud_init Path.expand("../../../deploy/hetzner/cloud-init.yaml", __DIR__)

  defp written(path) do
    {:ok, cloud_init} = YamlElixir.read_from_file(@cloud_init)

    Enum.find_value(cloud_init["write_files"], fn file ->
      file["path"] == path && file["content"]
    end)
  end

  # Every ${NAME} the file names, set for the read and put back after.
  defp with_env(text, fun) do
    names = ~r/\$\{([A-Z0-9_]+)\}/ |> Regex.scan(text) |> Enum.map(&List.last/1) |> Enum.uniq()
    previous = Map.new(names, &{&1, System.get_env(&1)})

    for name <- names,
        do:
          System.put_env(
            name,
            if(name == "WARDRIK_VAULT_KEY", do: WardrikVault.generate_key(), else: "x")
          )

    try do
      fun.()
    after
      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end
  end

  test "the box's config.yaml, and its triage agent under it, read", %{tmp_dir: dir} do
    text = written("/home/wardrik/.config/wardrik/config.yaml")
    config = Path.join(dir, "config.yaml")
    File.write!(config, text)

    assert {:ok, settings} = with_env(text, fn -> WardrikDaemon.Config.read(config) end)

    github =
      settings
      |> Keyword.fetch!(WardrikOAuth)
      |> Keyword.fetch!(:providers)
      |> Keyword.fetch!(:github)

    assert github[:issuer] == "https://github.com/login/oauth"

    agent = Path.join(dir, "triage.md")
    File.write!(agent, written("/home/wardrik/.config/wardrik/agents/triage.md"))

    with_settings(settings, fn ->
      assert {:ok, %Wardrik.Agent.Spec{id: %Wardrik.AgentID{name: "triage"}}} =
               WardrikDaemon.AgentFile.read(agent)
    end)
  end

  # The settings config.yaml makes, as the daemon applies them, put back after.
  defp with_settings(settings, fun) do
    previous =
      for {module, _value} <- settings,
          app = WardrikDaemon.Config.application(module),
          do: {app, module, Application.get_env(app, module)}

    for {module, value} <- settings,
        do: Application.put_env(WardrikDaemon.Config.application(module), module, value)

    try do
      fun.()
    after
      for {app, module, value} <- previous,
          do:
            if(value,
              do: Application.put_env(app, module, value),
              else: Application.delete_env(app, module)
            )
    end
  end
end
