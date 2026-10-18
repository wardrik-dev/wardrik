defmodule WardrikTrigger.ItemTest do
  use ExUnit.Case, async: true

  alias WardrikTrigger.Item

  describe "message/2" do
    test "is the prompt alone where no item holds anything to show" do
      assert Item.message("Look.", [%Item{id: "tick"}]) == "Look."
    end

    test "puts each item under the prompt" do
      items = [
        %Item{id: "1", title: "One", at: ~U[2026-10-12 09:00:00Z], text: "First."},
        %Item{id: "2", link: "https://example.com/2"}
      ]

      assert Item.message("What is new?", items) ==
               "What is new?\n\n## One (2026-10-12T09:00:00Z)\nFirst.\n\nhttps://example.com/2"
    end
  end

  test "message/2 shows twenty items, and says how many more there are" do
    items = for n <- 1..22, do: %Item{id: "#{n}", title: "Item #{n}"}
    message = Item.message("What is new?", items)

    assert message =~ "## Item 20"
    refute message =~ "## Item 21"
    assert String.ends_with?(message, "\n\n…and 2 more.")

    assert "What is new?"
           |> Item.message(Enum.take(items, 21))
           |> String.ends_with?("…and 1 more.")
  end

  test "labels/1 is the labels of every item, once each" do
    assert Item.labels([
             %Item{id: "1", labels: ["outside"]},
             %Item{id: "2"},
             %Item{id: "3", labels: ["books", "outside"]}
           ]) == ["books", "outside"]
  end
end
