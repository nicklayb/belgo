// Renders a plan scene (see Belgo.Plans.Scene) with three.js: floors, walls with
// their lintels and ghost doors, room names printed on their floors, the exterior
// at ground level and labelled devices
// (a box when they have a shape). The facade (exterior walls) can be hidden and the
// camera read / restored, so the page can remember it. A click on a device (marker,
// box or label) is reported; a network path (see Belgo.Plans.NetworkPath) is drawn
// as tubes between the placed devices, seen through walls (dashed when wireless or
// when hops not on the plan lie between).
// Plan centimetres become metres; the plan's y axis is three's z axis.
import {
  AmbientLight, BoxGeometry, CanvasTexture, CylinderGeometry, DirectionalLight, Group, HemisphereLight, Mesh,
  MeshBasicMaterial, MeshStandardMaterial, PerspectiveCamera, PlaneGeometry, Quaternion,
  Raycaster, Scene,
  SphereGeometry, Vector2, Vector3, WebGLRenderer
} from "three"
import {OrbitControls} from "three/addons/controls/OrbitControls.js"
import {CSS2DObject, CSS2DRenderer} from "three/addons/renderers/CSS2DRenderer.js"

const CENTIMETRES_PER_UNIT = 100
const FLOOR_THICKNESS = 0.04
const DOOR_THICKNESS = 0.04
const DEVICE_RADIUS = 0.12
const DOOR_OPACITY = 0.18
const DEVICE_BOX_OPACITY = 0.45
const EXTERIOR_KEY = "exterior"
const PATH_RADIUS = 0.03
const PATH_DASH = 0.25
const PATH_GAP = 0.15
const PATH_RENDER_ORDER = 10
const CLICK_TOLERANCE_PIXELS = 5
const PRIMARY_BUTTON = 0
const UP = new Vector3(0, 1, 0)
const ROOM_LABEL_FONT_PIXELS = 64
const ROOM_LABEL_PADDING_PIXELS = 16
const ROOM_LABEL_MAXIMUM_HEIGHT = 0.4
const ROOM_LABEL_ROOM_SHARE = 0.8
const ROOM_LABEL_LIFT = 0.005
const ROOM_LABEL_COLOR = "rgba(40, 37, 33, 0.9)"
const PATH_COLORS = {wired: 0x0ea5e9, wireless: 0x0ea5e9, indirect: 0x9ca3af}
const COLORS = {
  floor: 0xd9d4cc,
  exterior: 0x8fbf7f,
  wall: 0xf1efea,
  door: 0xbfd4e6,
  device: 0x5b5bd6,
  unknownDevice: 0xd97706
}

const toUnits = centimetres => centimetres / CENTIMETRES_PER_UNIT

export function createViewer(container) {
  const scene = new Scene()
  const camera = new PerspectiveCamera(45, 1, 0.1, 500)
  const renderer = new WebGLRenderer({antialias: true, alpha: true})
  const labels = new CSS2DRenderer()
  const controls = new OrbitControls(camera, labels.domElement)
  const root = new Group()
  let groups = new Map()
  let facades = []
  let levels = []
  let framed = false
  let facadeVisible = true
  let roomNames = []
  let roomNamesVisible = true
  let markers = new Map()
  let labelElements = new Map()
  let pickables = []
  let networkPath = null
  const pathGroup = new Group()
  const raycaster = new Raycaster()
  let onPointerDown = null
  let onPointerUp = null

  renderer.setPixelRatio(window.devicePixelRatio)
  container.appendChild(renderer.domElement)
  labels.domElement.classList.add("plan3d-labels")
  container.appendChild(labels.domElement)
  scene.add(new HemisphereLight(0xffffff, 0x8a8a8a, 1.6))
  scene.add(new AmbientLight(0xffffff, 0.3))
  const sun = new DirectionalLight(0xffffff, 1.4)
  sun.position.set(20, 40, 10)
  scene.add(sun)
  scene.add(root)
  scene.add(pathGroup)
  controls.enableDamping = true

  const resize = () => {
    const {width, height} = container.getBoundingClientRect()
    renderer.setSize(width, height)
    labels.setSize(width, height)
    camera.aspect = width / Math.max(height, 1)
    camera.updateProjectionMatrix()
  }
  const observer = new ResizeObserver(resize)
  observer.observe(container)
  resize()

  let frame = requestAnimationFrame(function loop() {
    controls.update()
    renderer.render(scene, camera)
    labels.render(scene, camera)
    frame = requestAnimationFrame(loop)
  })

  const groupFor = key => {
    if (!groups.has(key)) {
      const group = new Group()
      groups.set(key, group)
      root.add(group)
    }
    return groups.get(key)
  }

  // Transparent meshes do not write depth, so what stands behind them stays visible.
  const box = (width, height, depth, color, opacity = 1) =>
    new Mesh(
      new BoxGeometry(width, height, depth),
      new MeshStandardMaterial({color, transparent: opacity < 1, opacity, depthWrite: opacity >= 1})
    )

  const addFloor = floor => {
    const mesh = box(
      toUnits(floor.width), FLOOR_THICKNESS, toUnits(floor.depth),
      floor.exterior ? COLORS.exterior : COLORS.floor, floor.exterior ? 0.55 : 1
    )
    mesh.position.set(
      toUnits(floor.x + floor.width / 2),
      toUnits(floor.elevation) - FLOOR_THICKNESS / 2,
      toUnits(floor.y + floor.depth / 2)
    )
    groupFor(floor.level_id || EXTERIOR_KEY).add(mesh)
  }

  // The room name drawn into a texture, laid flat on the floor of its largest
  // rectangle, along its longer side, as large as fits.
  const addRoomLabel = label => {
    const canvas = document.createElement("canvas")
    const context = canvas.getContext("2d")
    const font = `600 ${ROOM_LABEL_FONT_PIXELS}px system-ui, sans-serif`
    context.font = font
    canvas.width = Math.ceil(context.measureText(label.name).width) + ROOM_LABEL_PADDING_PIXELS * 2
    canvas.height = Math.ceil(ROOM_LABEL_FONT_PIXELS * 1.4)
    context.font = font
    context.fillStyle = ROOM_LABEL_COLOR
    context.textAlign = "center"
    context.textBaseline = "middle"
    context.fillText(label.name, canvas.width / 2, canvas.height / 2)

    const turned = label.depth > label.width
    const along = toUnits(Math.max(label.width, label.depth)) * ROOM_LABEL_ROOM_SHARE
    const across = toUnits(Math.min(label.width, label.depth)) * ROOM_LABEL_ROOM_SHARE
    const aspect = canvas.width / canvas.height
    const height = Math.min(ROOM_LABEL_MAXIMUM_HEIGHT, across, along / aspect)

    const texture = new CanvasTexture(canvas)
    texture.anisotropy = renderer.capabilities.getMaxAnisotropy()
    const mesh = new Mesh(
      new PlaneGeometry(height * aspect, height),
      new MeshBasicMaterial({map: texture, transparent: true, depthWrite: false})
    )
    mesh.rotation.set(-Math.PI / 2, 0, turned ? Math.PI / 2 : 0)
    mesh.position.set(
      toUnits(label.x + label.width / 2),
      toUnits(label.elevation) + ROOM_LABEL_LIFT,
      toUnits(label.y + label.depth / 2)
    )
    mesh.visible = roomNamesVisible
    roomNames.push(mesh)
    groupFor(label.level_id).add(mesh)
  }

  const addWall = (wall, thickness) => {
    const horizontal = wall.y1 === wall.y2
    const length = toUnits(horizontal ? wall.x2 - wall.x1 : wall.y2 - wall.y1)
    const height = toUnits(wall.top - wall.bottom)
    const depth = wall.kind === "door" ? DOOR_THICKNESS : toUnits(thickness)
    const door = wall.kind === "door"
    const color = door ? COLORS.door : COLORS.wall
    const opacity = door ? DOOR_OPACITY : 1
    const mesh = horizontal
      ? box(length, height, depth, color, opacity)
      : box(depth, height, length, color, opacity)
    mesh.position.set(
      toUnits((wall.x1 + wall.x2) / 2),
      toUnits((wall.bottom + wall.top) / 2),
      toUnits((wall.y1 + wall.y2) / 2)
    )
    if (wall.exterior) {
      mesh.visible = facadeVisible
      facades.push(mesh)
    }
    groupFor(wall.level_id).add(mesh)
  }

  const addDevice = device => {
    const marker = new Mesh(
      new SphereGeometry(DEVICE_RADIUS, 24, 16),
      new MeshStandardMaterial({color: device.known ? COLORS.device : COLORS.unknownDevice})
    )
    marker.position.set(toUnits(device.x), toUnits(device.elevation) + DEVICE_RADIUS, toUnits(device.y))

    const label = document.createElement("span")
    label.className = "plan3d-label"
    label.textContent = device.name
    label.dataset.deviceId = device.device_id
    marker.userData.deviceId = device.device_id
    markers.set(device.device_id, marker)
    labelElements.set(device.device_id, label)
    pickables.push(marker)
    const labelObject = new CSS2DObject(label)
    labelObject.position.set(0, DEVICE_RADIUS * 2.5, 0)
    marker.add(labelObject)
    const group = groupFor(device.level_id || EXTERIOR_KEY)
    // Filtered out devices stay positioned (for network paths) but are not shown.
    marker.visible = !device.hidden
    group.add(marker)
    if (device.box) {
      const boxMesh = deviceBox(device)
      boxMesh.userData.deviceId = device.device_id
      boxMesh.visible = !device.hidden
      pickables.push(boxMesh)
      group.add(boxMesh)
    }
  }

  const deviceBox = ({box: shape, elevation, known}) => {
    const mesh = box(
      toUnits(shape.width), toUnits(shape.height), toUnits(shape.depth),
      known ? COLORS.device : COLORS.unknownDevice, DEVICE_BOX_OPACITY
    )
    mesh.position.set(
      toUnits(shape.x + shape.width / 2),
      toUnits(elevation + shape.height / 2),
      toUnits(shape.y + shape.depth / 2)
    )
    return mesh
  }

  const clear = () => {
    root.traverse(object => {
      object.geometry?.dispose()
      object.material?.map?.dispose()
      object.material?.dispose()
      if (object.isCSS2DObject) object.element.remove()
    })
    root.clear()
    groups = new Map()
    facades = []
    roomNames = []
    markers = new Map()
    labelElements = new Map()
    pickables = []
  }

  // A tube between two points, drawn over everything else.
  const tube = (from, to, color) => {
    const direction = new Vector3().subVectors(to, from)
    const mesh = new Mesh(
      new CylinderGeometry(PATH_RADIUS, PATH_RADIUS, direction.length(), 12),
      new MeshBasicMaterial({color, depthTest: false, transparent: true, opacity: 0.9})
    )
    mesh.renderOrder = PATH_RENDER_ORDER
    mesh.position.copy(from).add(to).multiplyScalar(0.5)
    mesh.quaternion.copy(new Quaternion().setFromUnitVectors(UP, direction.clone().normalize()))
    return mesh
  }

  const addSegment = (from, to, kind) => {
    const color = PATH_COLORS[kind]
    if (kind === "wired") return pathGroup.add(tube(from, to, color))
    const length = from.distanceTo(to)
    const step = new Vector3().subVectors(to, from).normalize()
    for (let start = 0; start < length; start += PATH_DASH + PATH_GAP) {
      const end = Math.min(start + PATH_DASH, length)
      pathGroup.add(tube(
        from.clone().addScaledVector(step, start), from.clone().addScaledVector(step, end), color
      ))
    }
  }

  const drawPath = () => {
    pathGroup.traverse(object => {
      object.geometry?.dispose()
      object.material?.dispose()
    })
    pathGroup.clear()
    labelElements.forEach(label => {
      delete label.dataset.selected
      delete label.dataset.onPath
    })
    if (!networkPath) return

    for (const {from, to, kind} of networkPath.segments) {
      const fromMarker = markers.get(from)
      const toMarker = markers.get(to)
      if (!fromMarker || !toMarker) continue
      addSegment(fromMarker.getWorldPosition(new Vector3()), toMarker.getWorldPosition(new Vector3()), kind)
      labelElements.get(from).dataset.onPath = ""
      labelElements.get(to).dataset.onPath = ""
    }
    const selected = labelElements.get(networkPath.device_id)
    if (selected) selected.dataset.selected = ""
  }

  const shown = object => {
    for (let current = object; current; current = current.parent)
      if (!current.visible) return false
    return true
  }

  // The device under a click: its label, else the first visible marker or box hit.
  // `target` comes from pointerdown: OrbitControls captures the pointer, so the
  // pointerup target is always the overlay.
  const pickDevice = (event, target) => {
    const label = target.closest?.("[data-device-id]")
    if (label) return label.dataset.deviceId
    const {left, top, width, height} = labels.domElement.getBoundingClientRect()
    const pointer = new Vector2(
      ((event.clientX - left) / width) * 2 - 1, -((event.clientY - top) / height) * 2 + 1
    )
    raycaster.setFromCamera(pointer, camera)
    const hit = raycaster.intersectObjects(pickables, false).find(({object}) => shown(object))
    return hit ? hit.object.userData.deviceId : null
  }

  // Looks at the whole home from above, south east.
  const frameScene = floors => {
    if (floors.length === 0) return
    const left = Math.min(...floors.map(floor => floor.x))
    const right = Math.max(...floors.map(floor => floor.x + floor.width))
    const top = Math.min(...floors.map(floor => floor.y))
    const bottom = Math.max(...floors.map(floor => floor.y + floor.depth))
    const centre = new Vector3(toUnits((left + right) / 2), 1, toUnits((top + bottom) / 2))
    const size = toUnits(Math.max(right - left, bottom - top))
    controls.target.copy(centre)
    camera.position.set(centre.x + size * 0.7, size * 0.75, centre.z + size * 0.95)
    framed = true
  }

  return {
    setScene(sceneData) {
      clear()
      levels = sceneData.levels
      sceneData.floors.forEach(addFloor)
      sceneData.walls.forEach(wall => addWall(wall, sceneData.wall_thickness))
      sceneData.room_labels.forEach(addRoomLabel)
      sceneData.devices.forEach(addDevice)
      root.updateMatrixWorld(true)
      drawPath()
      if (!framed) {
        // The home, not the whole terrain, fills the view.
        const rooms = sceneData.floors.filter(floor => !floor.exterior)
        frameScene(rooms.length > 0 ? rooms : sceneData.floors)
      }
    },

    // Levels above `elevation` (centimetres) are hidden, to look inside lower ones.
    showUpTo(elevation) {
      for (const level of levels) {
        const group = groups.get(level.id)
        if (group) group.visible = elevation === null || level.elevation <= elevation
      }
    },

    // Draws a network path ({device_id, segments}), or removes it (null).
    showPath(path) {
      networkPath = path
      drawPath()
    },

    // Calls back with the clicked device id, or null for a click elsewhere (drags,
    // which turn the camera, are not clicks).
    // Listened in the capture phase (before OrbitControls), pointerup on the window:
    // whatever captures the pointer, the click is seen.
    onDeviceClick(callback) {
      let down = null
      onPointerDown = event => {
        down = event.button === PRIMARY_BUTTON
          ? {x: event.clientX, y: event.clientY, target: event.target}
          : null
      }
      onPointerUp = event => {
        if (!down) return
        const moved = Math.hypot(event.clientX - down.x, event.clientY - down.y)
        const {target} = down
        down = null
        if (moved <= CLICK_TOLERANCE_PIXELS) callback(pickDevice(event, target))
      }
      container.addEventListener("pointerdown", onPointerDown, true)
      window.addEventListener("pointerup", onPointerUp, true)
    },

    showRoomNames(visible) {
      roomNamesVisible = visible
      roomNames.forEach(mesh => { mesh.visible = visible })
    },

    // Device labels; those of the shown network path stay (see app.css).
    showDeviceLabels(visible) {
      labels.domElement.classList.toggle("plan3d-labels-hidden", !visible)
    },

    showFacade(visible) {
      facadeVisible = visible
      facades.forEach(mesh => { mesh.visible = visible })
    },

    // Camera position and the point it orbits, in scene units.
    getView() {
      return {position: camera.position.toArray(), target: controls.target.toArray()}
    },

    setView({position, target}) {
      camera.position.fromArray(position)
      controls.target.fromArray(target)
      controls.update()
      framed = true
    },

    // Called on every camera move, damping included (debounce it).
    onViewChange(callback) {
      controls.addEventListener("change", callback)
    },

    dispose() {
      cancelAnimationFrame(frame)
      observer.disconnect()
      if (onPointerDown) container.removeEventListener("pointerdown", onPointerDown, true)
      if (onPointerUp) window.removeEventListener("pointerup", onPointerUp, true)
      networkPath = null
      drawPath()
      clear()
      controls.dispose()
      renderer.dispose()
      container.replaceChildren()
    }
  }
}
