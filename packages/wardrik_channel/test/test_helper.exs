Wardrik.Test.start(
  children: [{WardrikChannel.Replies, channels: %{}}],
  wait: [WardrikChannel.Replies.supervisor()]
)
