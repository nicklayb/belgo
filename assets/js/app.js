import "./live.js"

// Ctrl/⌘+K opens Belgo's search: keep browsers from focusing their own search bar.
window.addEventListener("keydown", event => {
  if ((event.ctrlKey || event.metaKey) && event.key === "k") event.preventDefault()
})
