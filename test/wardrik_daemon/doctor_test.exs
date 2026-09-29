defmodule WardrikDaemon.DoctorTest do
  use ExUnit.Case, async: false

  alias Wardrik.Test.Services
  alias WardrikDaemon.Doctor

  @moduletag :tmp_dir

  defp config(dir, yaml), do: File.write!(Path.join(dir, "config.yaml"), yaml)

  setup %{tmp_dir: dir} do
    previous = System.get_env("WARDRIK_DATA_DIR")
    System.put_env("WARDRIK_DATA_DIR", Path.join(dir, "store"))

    on_exit(fn ->
      if previous,
        do: System.put_env("WARDRIK_DATA_DIR", previous),
        else: System.delete_env("WARDRIK_DATA_DIR")
    end)
  end

  test "checks that config.yaml reads, and the store it names", %{tmp_dir: dir} do
    config(dir, "cluster:\n  nodes: [a, b, c]\n")
    File.mkdir_p!(Path.join(dir, "store"))

    assert Doctor.checks(dir) == [
             {:ok, "config", "#{dir}/config.yaml reads"},
             {:ok, "store", "on this node's disk, at #{dir}/store"}
           ]
  end

  test "a config.yaml that does not read is the only check", %{tmp_dir: dir} do
    config(dir, "storage:\n  s3: {}\n")

    assert [{:error, "config", message}] = Doctor.checks(dir)
    assert message =~ "storage.s3.bucket is required"
  end

  test "a directory holding config.yaml and config.yml fails", %{tmp_dir: dir} do
    config(dir, "")
    File.write!(Path.join(dir, "config.yml"), "")

    assert [{:error, "config", message}] = Doctor.checks(dir)
    assert message =~ "holds both config.yaml and config.yml"
  end

  @tag :postgres
  test "reaches the database storage names, and says why it cannot", %{tmp_dir: dir} do
    config(dir, "storage:\n  postgres:\n    url: #{Services.database_url()}\n")

    assert [{:ok, "config", _read}, {:ok, "store", found}] = Doctor.checks(dir)
    assert found =~ "holds wardrik_records"

    wrong = String.replace(Services.database_url(), ":postgres@", ":wrong@")
    config(dir, "storage:\n  postgres:\n    url: #{wrong}\n")

    assert [{:ok, "config", _read}, {:error, "store", found}] = Doctor.checks(dir)
    assert found =~ "password authentication failed"
  end

  test "reports a check a line, marked by how it went" do
    assert Doctor.report([
             {:ok, "config", "/c/config.yaml reads"},
             {:error, "store", "the bucket b at https://s3: the bucket answered 403"}
           ]) ==
             "ok    config  /c/config.yaml reads\n" <>
               "FAIL  store   the bucket b at https://s3: the bucket answered 403"
  end
end
