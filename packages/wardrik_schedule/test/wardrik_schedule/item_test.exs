defmodule WardrikSchedule.ItemTest do
  use ExUnit.Case, async: true

  alias WardrikSchedule.Item

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

  test "labels/1 is the labels of every item, once each" do
    assert Item.labels([
             %Item{id: "1", labels: ["outside"]},
             %Item{id: "2"},
             %Item{id: "3", labels: ["books", "outside"]}
           ]) == ["books", "outside"]
  end
end
