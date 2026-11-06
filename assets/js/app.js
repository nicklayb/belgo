import "./live.js"

// Ctrl/⌘+K opens Belgo's search: keep browsers from focusing their own search bar.
window.addEventListener("keydown", event => {
  if ((event.ctrlKey || event.metaKey) && event.key === "k") event.preventDefault()
})

// `JS.dispatch("belgo:set-value", to: "#input", detail: {value})` fills a form field as
// if typed, so the form change event sends it (e.g. a suggested address).
window.addEventListener("belgo:set-value", event => {
  event.target.value = event.detail.value
  event.target.dispatchEvent(new Event("input", {bubbles: true}))
})
