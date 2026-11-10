(() => {
  const meta = (name) => document.querySelector(`meta[name='${name}']`).getAttribute("content")
  const hooks = {
    // Keeps a growing timeline pinned to its end while the reader is already there.
    FollowEnd: {
      mounted() { window.scrollTo(0, document.body.scrollHeight) },
      beforeUpdate() { this.pinned = window.innerHeight + window.scrollY >= document.body.scrollHeight - 80 },
      updated() { if (this.pinned) window.scrollTo(0, document.body.scrollHeight) }
    },
    // Sends the composer's form on Enter; Shift+Enter makes a new line.
    SendOnEnter: {
      mounted() {
        this.el.addEventListener("keydown", (e) => {
          if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); this.el.form.requestSubmit() }
        })
      }
    }
  }
  const liveSocket = new LiveView.LiveSocket(meta("wardrik-socket"), Phoenix.Socket, {
    params: { _csrf_token: meta("csrf-token") },
    hooks
  })
  liveSocket.connect()
  window.liveSocket = liveSocket
})()
