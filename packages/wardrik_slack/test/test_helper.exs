Wardrik.Test.start(
  children:
    Wardrik.Test.children() ++
      [{WardrikChannel.Replies, channels: %{}, store: Wardrik.Test.store()}],
  wait: [WardrikChannel.Replies.supervisor()]
)
