// The 3D view of a plan. three.js is only loaded when this hook mounts (a separate
// chunk), so other pages never download it. The scene is computed by the server
// (`Belgo.Plans.Scene`) and given as JSON in `data-scene`; `data-visible-up-to`
// (an elevation in centimetres, empty for all) hides the levels above it.
// A click on a device sends `select-device` (an empty id for a click elsewhere); the
// server answers with its network path in `data-network-path`, drawn in the view.
// The camera and the toggles (`[data-toggle]`: facade = exterior walls, labels =
// device labels, names = room names on the floors, markers / boxes = device bubbles
// and boxes, grouped in the `[data-toggle-menu]` menu) are kept per plan
// (`data-plan-id`) in localStorage, so the view comes back as it was left; so is
// the full width choice (`[data-wide-toggle]`, sent to the server as `set-wide`).
const STORAGE_PREFIX = "belgo:plan3d:"
const SAVE_DELAY_MILLISECONDS = 300
const TOGGLES = {
  facade: (viewer, visible) => viewer.showFacade(visible),
  labels: (viewer, visible) => viewer.showDeviceLabels(visible),
  names: (viewer, visible) => viewer.showRoomNames(visible),
  markers: (viewer, visible) => viewer.showMarkers(visible),
  boxes: (viewer, visible) => viewer.showBoxes(visible)
}

export default {
  mounted() {
    this.storageKey = STORAGE_PREFIX + this.el.dataset.planId
    this.stored = this.readStored()
    this.toggles = [...this.el.querySelectorAll("[data-toggle]")]
    this.toggles.forEach(button => {
      button.addEventListener("click", () => this.toggle(button.dataset.toggle))
    })
    this.applyToggles()
    this.toggleMenus = [...this.el.querySelectorAll("[data-toggle-menu]")]
    this.closeMenus = event => {
      this.toggleMenus.forEach(menu => { if (!menu.contains(event.target)) menu.open = false })
    }
    document.addEventListener("pointerdown", this.closeMenus, true)
    this.wideToggle = this.el.querySelector("[data-wide-toggle]")
    this.wideToggle?.addEventListener("click", () => this.setWide(!this.stored.wide))
    if (this.stored.wide === true) this.setWide(true)

    import("../plan3d/viewer").then(({createViewer}) => {
      if (!this.el.isConnected) return
      this.viewer = createViewer(this.el.querySelector("[data-viewport]"))
      if (this.stored.view) this.viewer.setView(this.stored.view)
      Object.keys(TOGGLES).forEach(key => TOGGLES[key](this.viewer, !this.hidden(key)))
      this.viewer.onViewChange(() => this.scheduleSave())
      this.viewer.onDeviceClick(deviceId => {
        if (deviceId || this.el.dataset.networkPath) this.pushEvent("select-device", {device_id: deviceId || ""})
      })
      this.render()
    })
  },

  updated() {
    this.render()
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.closeMenus, true)
    clearTimeout(this.saveTimer)
    this.save()
    this.viewer?.dispose()
  },

  render() {
    if (!this.viewer) return
    this.viewer.setScene(JSON.parse(this.el.dataset.scene))
    const upTo = this.el.dataset.visibleUpTo
    this.viewer.showUpTo(upTo === "" || upTo === undefined ? null : Number(upTo))
    const path = this.el.dataset.networkPath
    this.viewer.showPath(path ? JSON.parse(path) : null)
  },

  hidden(key) {
    return this.stored.hidden?.[key] === true
  },

  toggle(key) {
    const hidden = !this.hidden(key)
    this.stored.hidden = {...this.stored.hidden, [key]: hidden}
    if (this.viewer) TOGGLES[key](this.viewer, !hidden)
    this.applyToggles()
    this.save()
  },

  // The canvas follows through the viewer's ResizeObserver.
  setWide(wide) {
    this.stored.wide = wide
    this.wideToggle?.setAttribute("aria-pressed", String(wide))
    this.pushEvent("set-wide", {wide})
    this.save()
  },

  applyToggles() {
    this.toggles.forEach(button => {
      button.setAttribute("aria-pressed", String(!this.hidden(button.dataset.toggle)))
    })
  },

  scheduleSave() {
    clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => this.save(), SAVE_DELAY_MILLISECONDS)
  },

  save() {
    if (this.viewer) this.stored.view = this.viewer.getView()
    try {
      localStorage.setItem(this.storageKey, JSON.stringify(this.stored))
    } catch (_error) {
      // Storage full or disabled: the view is simply not remembered.
    }
  },

  readStored() {
    try {
      const stored = JSON.parse(localStorage.getItem(this.storageKey)) || {}
      // Saved before the other toggles existed.
      if (stored.facadeHidden !== undefined) {
        stored.hidden = {facade: stored.facadeHidden, ...stored.hidden}
        delete stored.facadeHidden
      }
      return stored
    } catch (_error) {
      return {}
    }
  }
}
