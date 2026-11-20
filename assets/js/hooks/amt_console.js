// The Intel AMT serial console (`BelgoWeb.Devices.Live.Console`). xterm.js is only
// loaded when this hook mounts (a separate chunk), so other pages never download it.
// Bytes travel in base64: `attach` replies with the scrollback, `amt-output` brings
// new output, keystrokes go out as `input`. A reconnected LiveView attaches again
// (its new process has to subscribe), so the screen is redrawn from the scrollback.
const toBase64 = bytes => {
  let binary = ""
  bytes.forEach(byte => { binary += String.fromCharCode(byte) })
  return btoa(binary)
}

const fromBase64 = data => Uint8Array.from(atob(data), character => character.charCodeAt(0))

export default {
  mounted() {
    this.handleEvent("amt-output", ({data}) => this.terminal?.write(fromBase64(data)))
    this.handleEvent("amt-closed", () => this.terminal?.blur())

    import("../amt/terminal").then(({createTerminal}) => {
      if (!this.el.isConnected) return
      this.terminal = createTerminal(this.el.querySelector("[data-terminal]"), {
        onInput: bytes => this.pushEvent("input", {data: toBase64(bytes)})
      })
      this.attach()
    })
  },

  reconnected() {
    if (!this.terminal) return
    this.terminal.reset()
    this.attach()
  },

  destroyed() {
    this.terminal?.dispose()
  },

  attach() {
    this.pushEvent("attach", {}, ({data}) => {
      this.terminal.write(fromBase64(data))
      this.terminal.focus()
    })
  }
}
