defmodule WardrikDaemon.PolicyFileTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.PolicyFile

  @moduletag :tmp_dir

  defp read(text, %{tmp_dir: dir}) do
    path = Path.join(dir, "careful.yaml")
    File.write!(path, text)
    PolicyFile.read(path)
  end

  test "reads a policy named after its file", context do
    assert {:ok, %WardrikPolicy{name: "careful", default: :deny}} =
             read("default: deny\n", context)
  end

  test "a file that says nothing is refused", context do
    for text <- ["", "# nothing yet\n", "{}\n"] do
      assert {:error, message} = read(text, context)

      assert message =~
               "careful.yaml: is empty; a policy that allows every call says default: allow"
    end

    assert {:ok, %WardrikPolicy{rules: [], default: :allow}} = read("default: allow\n", context)
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
