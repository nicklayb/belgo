// Renders a plan scene (see Belgo.Plans.Scene) with three.js: floors, walls with
// their lintels and doors, the exterior at ground level and labelled devices.
// Plan centimetres become metres; the plan's y axis is three's z axis.
import {
  AmbientLight, BoxGeometry, DirectionalLight, Group, HemisphereLight, Mesh,
  MeshStandardMaterial, PerspectiveCamera, Scene, SphereGeometry, Vector3, WebGLRenderer
} from "three"
import {OrbitControls} from "three/addons/controls/OrbitControls.js"
import {CSS2DObject, CSS2DRenderer} from "three/addons/renderers/CSS2DRenderer.js"

const CENTIMETRES_PER_UNIT = 100
const FLOOR_THICKNESS = 0.04
const DOOR_THICKNESS = 0.04
const DEVICE_RADIUS = 0.12
const EXTERIOR_KEY = "exterior"
const COLORS = {
  floor: 0xd9d4cc,
  exterior: 0x8fbf7f,
  wall: 0xf1efea,
  door: 0x9a6b43,
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
  let levels = []
  let framed = false

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

  const box = (width, height, depth, color, opacity = 1) =>
    new Mesh(
      new BoxGeometry(width, height, depth),
      new MeshStandardMaterial({color, transparent: opacity < 1, opacity})
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

  const addWall = (wall, thickness) => {
    const horizontal = wall.y1 === wall.y2
    const length = toUnits(horizontal ? wall.x2 - wall.x1 : wall.y2 - wall.y1)
    const height = toUnits(wall.top - wall.bottom)
    const depth = wall.kind === "door" ? DOOR_THICKNESS : toUnits(thickness)
    const color = wall.kind === "door" ? COLORS.door : COLORS.wall
    const mesh = horizontal ? box(length, height, depth, color) : box(depth, height, length, color)
    mesh.position.set(
      toUnits((wall.x1 + wall.x2) / 2),
      toUnits((wall.bottom + wall.top) / 2),
      toUnits((wall.y1 + wall.y2) / 2)
    )
    groupFor(wall.level_id).add(mesh)
  }

  const addDevice = device => {
    const marker = new Mesh(
      new SphereGeometry(DEVICE_RADIUS, 24, 16),
      new MeshStandardMaterial({color: device.known ? COLORS.device : COLORS.unknownDevice})
    )
    marker.position.set(toUnits(device.x), toUnits(device.elevation) + DEVICE_RADIUS, toUnits(device.y))

    const label = document.createElement(device.known ? "a" : "span")
    label.className = "plan3d-label"
    label.textContent = device.name
    if (device.known) label.href = `/devices/${device.device_id}`
    const labelObject = new CSS2DObject(label)
    labelObject.position.set(0, DEVICE_RADIUS * 2.5, 0)
    marker.add(labelObject)
    groupFor(device.level_id || EXTERIOR_KEY).add(marker)
  }

  const clear = () => {
    root.traverse(object => {
      object.geometry?.dispose()
      object.material?.dispose()
      if (object.isCSS2DObject) object.element.remove()
    })
    root.clear()
    groups = new Map()
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
      sceneData.devices.forEach(addDevice)
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

    dispose() {
      cancelAnimationFrame(frame)
      observer.disconnect()
      clear()
      controls.dispose()
      renderer.dispose()
      container.replaceChildren()
    }
  }
}
