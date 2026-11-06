// Remembers in the browser which collapsible cards (<details data-collapse-key>) are
// open, so the choice survives page changes and reloads. Without a stored choice the
// server default applies. LiveView keeps the `open` attribute across patches
// (`JS.ignore_attributes("open")` on the element).
const STORAGE_PREFIX = "belgo:collapsible:"
const OPEN = "open"
const CLOSED = "closed"

export default {
  mounted() {
    this.key = STORAGE_PREFIX + this.el.dataset.collapseKey

    const stored = localStorage.getItem(this.key)
    if (stored !== null) this.el.open = stored === OPEN

    this.el.addEventListener("toggle", () => {
      localStorage.setItem(this.key, this.el.open ? OPEN : CLOSED)
    })
  }
}
