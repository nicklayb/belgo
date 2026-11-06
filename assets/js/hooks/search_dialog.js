// Opens the global search dialog in the browser, so the field is focused inside the
// click / key handler itself: browsers such as Safari ignore a focus requested later
// (after a server round trip). LiveView keeps the `open` attribute across patches
// (`JS.ignore_attributes("open")` on the dialog).
//
// Arrow keys move through the results while the focus stays in the field; Enter
// follows the selected result (the first one when none is selected).
const isShortcut = event => (event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k"
const NONE = -1
const STEP_BY_KEY = {ArrowDown: 1, ArrowUp: -1}

export default {
  mounted() {
    this.input = this.el.querySelector("input[type=text]")
    this.activeIndex = NONE

    this.onKeydown = event => {
      if (!isShortcut(event)) return
      event.preventDefault()
      this.open()
    }

    this.onClick = event => {
      if (event.target.closest("[data-search-open]")) this.open()
    }

    // A click on the backdrop targets the dialog itself; following a result closes it.
    this.el.addEventListener("click", event => {
      if (event.target === this.el || event.target.closest("a[href]")) this.el.close()
    })

    this.el.addEventListener("keydown", event => this.navigate(event))
    // New text means new results: the selection starts over.
    this.input.addEventListener("input", () => this.select(NONE))

    window.addEventListener("keydown", this.onKeydown)
    document.addEventListener("click", this.onClick)
  },

  // Patches drop the client-side highlight, so it is put back on the same position.
  updated() {
    this.select(Math.min(this.activeIndex, this.results().length - 1))
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("click", this.onClick)
  },

  open() {
    if (!this.el.open) this.el.showModal()
    this.input.focus()
    this.input.select()
  },

  results() {
    return Array.from(this.el.querySelectorAll("[data-search-result]"))
  },

  navigate(event) {
    const results = this.results()
    if (results.length === 0) return

    if (event.key in STEP_BY_KEY) {
      event.preventDefault()
      const step = STEP_BY_KEY[event.key]
      const first = step > 0 ? 0 : results.length - 1
      const next = (this.activeIndex + step + results.length) % results.length
      this.select(this.activeIndex === NONE ? first : next)
    } else if (event.key === "Enter" && event.target === this.input) {
      event.preventDefault()
      results[Math.max(this.activeIndex, 0)].click()
    }
  },

  select(index) {
    this.activeIndex = index

    this.results().forEach((result, position) => {
      const active = position === index
      result.toggleAttribute("data-active", active)
      result.setAttribute("aria-selected", active ? "true" : "false")
      if (active) result.scrollIntoView({block: "nearest"})
    })
  }
}
