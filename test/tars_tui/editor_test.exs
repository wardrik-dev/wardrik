defmodule TarsTUI.EditorTest do
  # The editor is named by the environment, which is shared.
  use ExUnit.Case, async: false

  alias TarsTUI.Editor

  @variables ["VISUAL", "EDITOR"]
  @no_terminal %{terminal: nil, server: nil}

  setup do
    saved = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  describe "command/0" do
    test "prefers $VISUAL, falls back to $EDITOR, and treats a blank as unset" do
      assert Editor.command() == nil

      System.put_env("EDITOR", "nano")
      assert Editor.command() == "nano"

      System.put_env("VISUAL", "  ")
      assert Editor.command() == "nano"

      System.put_env("VISUAL", "code --wait")
      assert Editor.command() == "code --wait"
    end
  end

  describe "quote_arg/1" do
    test "quotes a path for the shell, quotes in it included" do
      assert Editor.quote_arg("/tmp/it's here.md") == "'/tmp/it'\\''s here.md'"
    end
  end

  describe "edit/2" do
    test "without an editor set, says so and keeps the draft" do
      assert Editor.edit("draft", @no_terminal) == {:error, :no_editor}
    end

    test "returns what the editor saved, without a trailing newline" do
      System.put_env("VISUAL", ~s|sh -c 'printf " edited\\n" >> "$0"'|)

      assert Editor.edit("draft", @no_terminal) == {:ok, "draft edited"}
    end

    test "an editor exiting with another status cancels" do
      System.put_env("VISUAL", "sh -c 'exit 3'")

      assert Editor.edit("draft", @no_terminal) == {:error, {:exit, 3}}
    end

    test "keeps drafts private and removes the directory including editor backups" do
      System.put_env(
        "VISUAL",
        ~s|sh -c 'test "$(stat -c %a "$0")" = 600 && test "$(stat -c %a "$(dirname "$0")")" = 700 && cp "$0" "$0.bak" && printf "%s" "$0" > "$0"'|
      )

      assert {:ok, path} = Editor.edit("private draft", @no_terminal)
      refute File.exists?(path)
      refute File.exists?(Path.dirname(path))
    end
  end
end
