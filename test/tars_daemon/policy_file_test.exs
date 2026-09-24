defmodule TarsDaemon.PolicyFileTest do
  use ExUnit.Case, async: true

  alias TarsDaemon.PolicyFile

  @moduletag :tmp_dir

  defp read(text, %{tmp_dir: dir}) do
    path = Path.join(dir, "careful.yaml")
    File.write!(path, text)
    PolicyFile.read(path)
  end

  test "reads a policy named after its file", context do
    assert {:ok, %TarsPolicy{name: "careful", default: :deny}} = read("default: deny\n", context)
  end

  test "an empty file is a policy that allows everything", context do
    assert {:ok, %TarsPolicy{name: "careful", rules: [], default: :allow}} = read("", context)
  end

  test "a file that is not YAML, or not a policy, says so", context do
    assert {:error, yaml} = read("deny: [a\n", context)
    assert yaml =~ "careful.yaml: is not YAML"

    assert {:error, policy} = read("allows: []\n", context)
    assert policy =~ "careful.yaml: allows is not a setting"
  end

  test "a file that is not there says so", %{tmp_dir: dir} do
    assert {:error, message} = PolicyFile.read(Path.join(dir, "missing.yaml"))
    assert message =~ "missing.yaml: no such file"
  end
end
