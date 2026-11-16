(() => {
  const meta = (name) => document.querySelector(`meta[name='${name}']`).getAttribute("content")
  const hooks = {
    // Keeps a growing timeline pinned to its end while the reader is already there.
    FollowEnd: {
      mounted() { window.scrollTo(0, document.body.scrollHeight) },
      beforeUpdate() { this.pinned = window.innerHeight + window.scrollY >= document.body.scrollHeight - 80 },
      updated() { if (this.pinned) window.scrollTo(0, document.body.scrollHeight) }
    },
    // Sends the composer's form on Enter; Shift+Enter makes a new line. Empties it once sent.
    SendOnEnter: {
      mounted() {
        this.el.addEventListener("keydown", (e) => {
          if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); this.el.form.requestSubmit() }
        })
        this.handleEvent("composer:sent", () => { this.el.value = "" })
      }
    },
    // Counts the time since data-since, as 0:42 or 1:05:09.
    Elapsed: {
      mounted() {
        const tick = () => {
          const s = Math.max(0, Math.floor((Date.now() - Date.parse(this.el.dataset.since)) / 1000))
          const [h, m, r] = [Math.floor(s / 3600), Math.floor(s / 60) % 60, s % 60]
          const pad = (n) => String(n).padStart(2, "0")
          this.el.textContent = h > 0 ? `${h}:${pad(m)}:${pad(r)}` : `${m}:${pad(r)}`
        }
        tick()
        this.timer = setInterval(tick, 1000)
      },
      destroyed() { clearInterval(this.timer) }
    },
    // Tells the reader, by a browser notification, when more calls wait for their approval while
    // the tab is in the background. Offers a button to allow notifications until they're decided.
    NotifyWaiting: {
      mounted() {
        this.count = Number(this.el.dataset.count)
        if (!("Notification" in window) || Notification.permission !== "default") return
        const button = document.getElementById("notify-me")
        if (!button) return
        button.hidden = false
        button.addEventListener("click", () => {
          Notification.requestPermission().then(() => { button.hidden = true })
        })
      },
      updated() {
        const count = Number(this.el.dataset.count)
        const more = count > this.count
        this.count = count
        if (more && document.hidden && "Notification" in window && Notification.permission === "granted") {
          new Notification(document.title, { body: this.el.dataset.text, tag: "wardrik-waiting" })
        }
      }
    }
  }
  const liveSocket = new LiveView.LiveSocket(meta("wardrik-socket"), Phoenix.Socket, {
    params: { _csrf_token: meta("csrf-token") },
    hooks,
    // A <details> the reader opened or closed stays that way when the page updates. Until then,
    // the page decides.
    dom: {
      onBeforeElUpdated(from, to) {
        if (from.tagName === "DETAILS" && from.dataset.toggled) {
          to.open = from.open
          to.dataset.toggled = "1"
        }
      }
    }
  })
  document.addEventListener("click", (e) => {
    const summary = e.target.closest("summary")
    if (summary && summary.parentElement.tagName === "DETAILS") summary.parentElement.dataset.toggled = "1"
  })
  liveSocket.connect()
  window.liveSocket = liveSocket
})()
