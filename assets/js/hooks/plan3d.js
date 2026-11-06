// The 3D view of a plan. three.js is only loaded when this hook mounts (a separate
// chunk), so other pages never download it. The scene is computed by the server
// (`Belgo.Plans.Scene`) and given as JSON in `data-scene`; `data-visible-up-to`
// (an elevation in centimetres, empty for all) hides the levels above it.
export default {
  mounted() {
    import("../plan3d/viewer").then(({createViewer}) => {
      if (!this.el.isConnected) return
      this.viewer = createViewer(this.el)
      this.render()
    })
  },

  updated() {
    this.render()
  },

  destroyed() {
    this.viewer?.dispose()
  },

  render() {
    if (!this.viewer) return
    this.viewer.setScene(JSON.parse(this.el.dataset.scene))
    const upTo = this.el.dataset.visibleUpTo
    this.viewer.showUpTo(upTo === "" || upTo === undefined ? null : Number(upTo))
  }
}
