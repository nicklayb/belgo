// xterm.js terminal of the AMT console, in its own chunk (see hooks/amt_console.js).
// Its stylesheet is bundled as text (esbuild `--loader:.css=text`) and added to the
// page once, so other pages never load it either.
import {Terminal} from "@xterm/xterm"
import {FitAddon} from "@xterm/addon-fit"
import styles from "@xterm/xterm/css/xterm.css"

const STYLE_ID = "xterm-styles"
const SCROLLBACK_LINES = 5000
const BYTE_MASK = 0xff
const encoder = new TextEncoder()

const addStyles = () => {
  if (document.getElementById(STYLE_ID)) return
  const style = document.createElement("style")
  style.id = STYLE_ID
  style.textContent = styles
  document.head.appendChild(style)
}

export const createTerminal = (container, {onInput}) => {
  addStyles()
  const terminal = new Terminal({
    cursorBlink: true,
    scrollback: SCROLLBACK_LINES,
    fontFamily: getComputedStyle(document.documentElement).getPropertyValue("--font-mono") || "monospace"
  })
  const fitAddon = new FitAddon()
  terminal.loadAddon(fitAddon)
  terminal.open(container)
  fitAddon.fit()

  terminal.onData(data => onInput(encoder.encode(data)))
  // Some keys (e.g. mouse reports) come as binary strings, one byte per character.
  terminal.onBinary(data => onInput(Uint8Array.from(data, character => character.charCodeAt(0) & BYTE_MASK)))

  const resizeObserver = new ResizeObserver(() => fitAddon.fit())
  resizeObserver.observe(container)

  return {
    write: bytes => terminal.write(bytes),
    reset: () => terminal.reset(),
    focus: () => terminal.focus(),
    blur: () => terminal.blur(),
    dispose: () => {
      resizeObserver.disconnect()
      terminal.dispose()
    }
  }
}
