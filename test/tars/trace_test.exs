defmodule Tars.TraceTest do
  use ExUnit.Case, async: true

  alias Tars.Trace

  test "a root span opens a new trace and has no parent" do
    trace = Trace.root(name: "turn")

    assert Trace.root?(trace)
    assert trace.parent_span_id == nil
    assert trace.name == "turn"
    assert byte_size(trace.trace_id) == 32
    assert byte_size(trace.span_id) == 16
  end

  test "every root span is distinct" do
    assert Trace.root().trace_id != Trace.root().trace_id
  end

  test "a child stays in the trace and points at its parent" do
    parent = Trace.root()
    child = Trace.child(parent, name: "web_search")

    assert child.trace_id == parent.trace_id
    assert child.parent_span_id == parent.span_id
    assert child.span_id != parent.span_id
    assert child.name == "web_search"
    refute Trace.root?(child)
  end

  test "nesting goes as deep as the work does" do
    root = Trace.root()
    branch = Trace.child(root)
    leaf = Trace.child(branch)

    assert leaf.trace_id == root.trace_id
    assert leaf.parent_span_id == branch.span_id
    refute Trace.root?(leaf)
  end

  test "siblings share a parent and differ from each other" do
    parent = Trace.root()
    one = Trace.child(parent)
    two = Trace.child(parent)

    assert one.parent_span_id == two.parent_span_id
    assert one.span_id != two.span_id
  end

  test "a span renders as a W3C traceparent" do
    trace = Trace.root()

    assert Trace.traceparent(trace) == "00-#{trace.trace_id}-#{trace.span_id}-01"
  end

  test "names are optional" do
    assert Trace.root().name == nil
    assert Trace.root() |> Trace.child() |> Map.fetch!(:name) == nil
  end
end
