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

const COPIED_FEEDBACK_MILLISECONDS = 1500

// The asynchronous clipboard API only exists in secure contexts (HTTPS, localhost):
// plain HTTP falls back to a selected hidden textarea and `execCommand("copy")`.
const copyText = text => {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text)

  const textarea = document.createElement("textarea")
  textarea.value = text
  textarea.setAttribute("readonly", "")
  textarea.style.position = "fixed"
  textarea.style.opacity = "0"
  document.body.appendChild(textarea)
  textarea.select()
  const isCopied = document.execCommand("copy")
  textarea.remove()
  return isCopied ? Promise.resolve() : Promise.reject(new Error("copy refused"))
}

// `JS.dispatch("belgo:copy", detail: {text})` copies the text, then marks the button
// `data-copied` for a moment (see the `copy_button` component).
window.addEventListener("belgo:copy", event => {
  const button = event.target
  copyText(event.detail.text).then(() => {
    button.setAttribute("data-copied", "")
    setTimeout(() => button.removeAttribute("data-copied"), COPIED_FEEDBACK_MILLISECONDS)
  })
})
