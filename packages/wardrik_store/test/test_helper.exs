Mimic.copy(WardrikStore.Memory)

# The suite writes to an EKV store of its own, removed once it is over.
dir =
  Path.join([
    System.tmp_dir!(),
    "wardrik-store-test",
    "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  ])

{:ok, store} =
  Supervisor.start_link([{WardrikStore, adapter: WardrikStore.EKV, data_dir: dir}],
    strategy: :one_for_one
  )

ExUnit.after_suite(fn _results ->
  Supervisor.stop(store)
  File.rm_rf(dir)
end)

ExUnit.start(capture_log: true, assert_receive_timeout: 1_000)
