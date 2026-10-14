Wardrik.Test.start(
  children: [{WardrikChannel.Replies, channels: %{}, store: Wardrik.Test.store()}],
  wait: [WardrikChannel.Replies.supervisor()]
)
