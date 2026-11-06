// Pointer gestures of the plan editor, on the SVG drawn by the server
// (BelgoWeb.Components.PlanDrawing). Positions are plan centimetres snapped to the
// grid; the server applies the edit and redraws. Previews go to the overlay group,
// which LiveView leaves alone (phx-update="ignore").
//
// data-tool: select (move / resize / pick), draw (a new zone), rectangle (add to the
// selected zone), split, door, opening, place (a device, see data-device).
//
// The view (zoom and pan) belongs to the browser: the server's viewBox only sets the
// first frame (`data-fit`, used by "Fit"), LiveView ignores later changes of it
// (JS.ignore_attributes). Wheel zooms around the cursor; Space + drag or the middle
// button pans. Keyboard shortcuts (outside form fields) are sent as `key` events.
const SVG_NAMESPACE = "http://www.w3.org/2000/svg"
const MINIMUM_SIZE_STEPS = 1
const ZOOM_STEP = 1.2
const WHEEL_ZOOM_STEP = 1.1
const MIDDLE_BUTTON = 1
const TOOL_KEYS = {v: "select", r: "draw", e: "rectangle", s: "split", d: "door", o: "opening", p: "place"}

const snap = (value, grid) => Math.round(value / grid) * grid
const editingText = target =>
  target.closest("input, select, textarea, [contenteditable]") !== null

export default {
  mounted() {
    this.gesture = null
    this.view = null
    this.spaceHeld = false
    this.el.addEventListener("pointerdown", event => this.start(event))
    this.el.addEventListener("pointermove", event => this.move(event))
    this.el.addEventListener("pointerup", event => this.finish(event))
    this.el.addEventListener("pointercancel", () => this.cancel())
    this.el.addEventListener("wheel", event => this.wheel(event), {passive: false})
    this.el.addEventListener("plan:zoom", event => this.zoom(event.detail.factor))
    this.el.addEventListener("plan:fit", () => this.fit())

    this.onKeydown = event => this.keydown(event)
    this.onKeyup = event => { if (event.key === " ") this.spaceHeld = false }
    window.addEventListener("keydown", this.onKeydown)
    window.addEventListener("keyup", this.onKeyup)
    this.applyView()
  },

  // Patches keep the viewBox the browser set; a new canvas (another level) gets the
  // current zoom too.
  updated() {
    this.applyView()
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
    window.removeEventListener("keyup", this.onKeyup)
  },

  applyView() {
    const svg = this.svg()
    if (!svg) return
    if (!this.view) this.view = svg.getAttribute("viewBox").split(" ").map(Number)
    svg.setAttribute("viewBox", this.view.join(" "))
  },

  fit() {
    this.view = this.svg().dataset.fit.split(" ").map(Number)
    this.applyView()
  },

  // Zooms by `factor` (< 1 zooms in) around a plan point, the centre by default.
  zoom(factor, around = null) {
    const [x, y, width, height] = this.view
    const centre = around || {x: x + width / 2, y: y + height / 2}
    this.view = [
      centre.x - (centre.x - x) * factor, centre.y - (centre.y - y) * factor,
      width * factor, height * factor
    ]
    this.applyView()
  },

  wheel(event) {
    if (!this.svg()?.contains(event.target)) return
    event.preventDefault()
    const factor = event.deltaY > 0 ? WHEEL_ZOOM_STEP : 1 / WHEEL_ZOOM_STEP
    this.zoom(factor, this.point(event))
  },

  keydown(event) {
    if (editingText(event.target)) return
    const key = event.key.toLowerCase()
    const command = event.ctrlKey || event.metaKey

    if (event.key === " ") {
      this.spaceHeld = true
      event.preventDefault()
    } else if (command && key === "z") {
      event.preventDefault()
      this.pushEvent("key", {action: event.shiftKey ? "redo" : "undo"})
    } else if (command && key === "y") {
      event.preventDefault()
      this.pushEvent("key", {action: "redo"})
    } else if (command) {
      return
    } else if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault()
      this.pushEvent("key", {action: "delete"})
    } else if (event.key === "Escape") {
      this.cancel()
      this.pushEvent("key", {action: "escape"})
    } else if (key in TOOL_KEYS) {
      this.pushEvent("tool", {tool: TOOL_KEYS[key]})
    } else if (key === "f") {
      this.fit()
    } else if (key === "+" || key === "=") {
      this.zoom(1 / ZOOM_STEP)
    } else if (key === "-") {
      this.zoom(ZOOM_STEP)
    }
  },

  svg() {
    return this.el.querySelector("svg")
  },

  grid() {
    return Number(this.el.dataset.grid)
  },

  point(event) {
    const svg = this.svg()
    const point = svg.createSVGPoint()
    point.x = event.clientX
    point.y = event.clientY
    const plan = point.matrixTransform(svg.getScreenCTM().inverse())
    return {x: plan.x, y: plan.y}
  },

  snapped(point) {
    return {x: snap(point.x, this.grid()), y: snap(point.y, this.grid())}
  },

  rectangleOf(zoneId, index) {
    const element = this.svg().querySelector(`rect[data-zone="${zoneId}"][data-index="${index}"]:not([data-handle])`)
    return {
      x: Number(element.getAttribute("x")),
      y: Number(element.getAttribute("y")),
      width: Number(element.getAttribute("width")),
      depth: Number(element.getAttribute("height"))
    }
  },

  start(event) {
    if (!this.svg()?.contains(event.target)) return

    if (event.button === MIDDLE_BUTTON || (event.button === 0 && this.spaceHeld)) {
      event.preventDefault()
      this.begin(event, {kind: "pan", client: {x: event.clientX, y: event.clientY}, view: [...this.view]})
      return
    }

    if (event.button !== 0) return
    const tool = this.el.dataset.tool
    const point = this.point(event)
    const target = event.target

    if (tool === "select") {
      const handle = target.closest("[data-handle]")
      const device = target.closest("[data-placement]")
      const extend = target.closest("[data-extend]")

      if (extend) {
        this.pushEvent("extend-room", {zone_id: extend.dataset.extend, index: Number(extend.dataset.sideIndex)})
        return
      }
      const zoneRectangle = target.closest("rect[data-zone]")
      const opening = target.closest("[data-opening-index]")

      if (device) {
        this.begin(event, {kind: "device", device: device.dataset.placement, origin: point, moved: false})
      } else if (handle) {
        const {zone, index, handle: corner} = handle.dataset
        this.begin(event, {kind: "resize", zone, index, corner, rectangle: this.rectangleOf(zone, index), origin: point})
      } else if (opening) {
        this.pushEvent("select-opening", {index: Number(opening.dataset.openingIndex)})
      } else if (zoneRectangle) {
        const {zone, index} = zoneRectangle.dataset
        const rectangles = this.svg().querySelectorAll(`rect[data-zone="${zone}"]:not([data-handle])`).length
        this.begin(event, {
          kind: "move", zone, index, whole: event.shiftKey || rectangles === 1,
          rectangle: this.rectangleOf(zone, index), origin: point
        })
      } else {
        this.pushEvent("deselect", {})
      }
    } else if (tool === "draw" || tool === "rectangle") {
      this.begin(event, {kind: "draw", origin: this.snapped(point)})
    } else if (tool === "split") {
      const zoneRectangle = target.closest("rect[data-zone]")
      if (zoneRectangle) this.pushEvent("split", {zone_id: zoneRectangle.dataset.zone, ...this.snapped(point)})
    } else if (tool === "door" || tool === "opening") {
      this.pushEvent("add-opening", point)
    } else if (tool === "place") {
      this.pushEvent("place", point)
    }
  },

  begin(event, gesture) {
    this.gesture = gesture
    this.el.setPointerCapture(event.pointerId)
  },

  current(event) {
    const gesture = this.gesture
    const point = this.point(event)
    const grid = this.grid()

    if (gesture.kind === "device") {
      const moved = Math.hypot(point.x - gesture.origin.x, point.y - gesture.origin.y) >= grid
      return {...point, moved: gesture.moved || moved}
    }

    if (gesture.kind === "draw") {
      const end = this.snapped(point)
      return {
        x: Math.min(gesture.origin.x, end.x), y: Math.min(gesture.origin.y, end.y),
        width: Math.abs(end.x - gesture.origin.x), depth: Math.abs(end.y - gesture.origin.y)
      }
    }

    const deltaX = snap(point.x - gesture.origin.x, grid)
    const deltaY = snap(point.y - gesture.origin.y, grid)
    const {x, y, width, depth} = gesture.rectangle

    if (gesture.kind === "move") return {x: x + deltaX, y: y + deltaY, width, depth, deltaX, deltaY}

    // Resize: the dragged corner moves, the opposite one stays.
    const west = gesture.corner.includes("w")
    const north = gesture.corner.includes("n")
    const left = west ? x + deltaX : x
    const right = west ? x + width : x + width + deltaX
    const top = north ? y + deltaY : y
    const bottom = north ? y + depth : y + depth + deltaY
    return {x: Math.min(left, right), y: Math.min(top, bottom), width: Math.abs(right - left), depth: Math.abs(bottom - top)}
  },

  move(event) {
    if (!this.gesture) return
    if (this.gesture.kind === "pan") return this.pan(event)
    const current = this.current(event)
    if (this.gesture.kind === "device") {
      this.gesture.moved = current.moved
      return this.previewDevice(current)
    }
    this.preview(current)
  },

  previewDevice({x, y}) {
    const overlay = this.overlay()
    if (!overlay) return
    let marker = overlay.firstElementChild
    if (!marker) {
      marker = document.createElementNS(SVG_NAMESPACE, "circle")
      marker.setAttribute("class", "fill-accent/40 stroke-accent")
      marker.setAttribute("r", this.grid() * 2)
      marker.setAttribute("stroke-width", this.grid() / 2)
      overlay.appendChild(marker)
    }
    marker.setAttribute("cx", x)
    marker.setAttribute("cy", y)
  },

  // Moves the view by the dragged distance, converted from screen pixels.
  pan(event) {
    const {client, view} = this.gesture
    // The drawing keeps its proportions: the larger ratio is the one applied.
    const {width, height} = this.svg().getBoundingClientRect()
    const scale = Math.max(view[2] / width, view[3] / height)
    this.view = [
      view[0] - (event.clientX - client.x) * scale, view[1] - (event.clientY - client.y) * scale,
      view[2], view[3]
    ]
    this.applyView()
  },

  finish(event) {
    if (!this.gesture) return
    if (this.gesture.kind === "pan") return this.cancel()
    const gesture = this.gesture
    const result = this.current(event)
    const minimum = this.grid() * MINIMUM_SIZE_STEPS
    this.cancel()

    if (gesture.kind === "device") {
      if (result.moved) {
        this.pushEvent("move-placement", {device_id: gesture.device, x: result.x, y: result.y})
      } else {
        this.pushEvent("select-placement", {device_id: gesture.device})
      }
    } else if (gesture.kind === "draw" && result.width >= minimum && result.depth >= minimum) {
      this.pushEvent("draw", result)
    } else if (gesture.kind === "move") {
      if (result.deltaX === 0 && result.deltaY === 0) {
        this.pushEvent("select-zone", {zone_id: gesture.zone, index: Number(gesture.index)})
      } else {
        this.pushEvent("move", {
          zone_id: gesture.zone, index: Number(gesture.index), whole: gesture.whole,
          delta_x: result.deltaX, delta_y: result.deltaY
        })
      }
    } else if (gesture.kind === "resize" && result.width >= minimum && result.depth >= minimum) {
      this.pushEvent("set-rectangle", {zone_id: gesture.zone, index: Number(gesture.index), ...result})
    }
  },

  cancel() {
    this.gesture = null
    this.overlay()?.replaceChildren()
  },

  overlay() {
    return this.svg()?.querySelector("#plan-editor-overlay")
  },

  preview({x, y, width, depth}) {
    const overlay = this.overlay()
    if (!overlay) return
    let shape = overlay.firstElementChild
    if (!shape) {
      shape = document.createElementNS(SVG_NAMESPACE, "rect")
      shape.setAttribute("class", "fill-accent/20 stroke-accent")
      shape.setAttribute("stroke-width", this.grid() / 2)
      shape.setAttribute("stroke-dasharray", this.grid() * 2)
      overlay.appendChild(shape)
    }
    shape.setAttribute("x", x)
    shape.setAttribute("y", y)
    shape.setAttribute("width", width)
    shape.setAttribute("height", depth)
  }
}
