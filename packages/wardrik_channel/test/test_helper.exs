Wardrik.Test.start(
  children:
    Wardrik.Test.children() ++
      [
        {WardrikTrigger, store: Wardrik.Test.store(), host: Wardrik.Test.host()},
        {WardrikChannel.Replies, host: Wardrik.Test.host()}
      ],
  wait: [WardrikTrigger.supervisor(), WardrikChannel.Replies.supervisor()]
)
