defmodule Wardrik.LabelTest do
  use ExUnit.Case, async: true

  alias Wardrik.Label

  test "union/2 holds each label once, in order" do
    assert Label.union(["outside"], ["books", "outside"]) == ["books", "outside"]
    assert Label.union([], []) == []
  end

  test "described/1 says what content with the labels is, as a person reads it" do
    assert Label.described(["outside"]) == "content from outside"

    assert Label.described(["outside", "books"]) ==
             "content from outside and content labelled books"
  end
end
