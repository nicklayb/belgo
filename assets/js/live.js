import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import Hooks from "./hooks"
import {storedLocale, syncLocaleCookie} from "./locale"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
syncLocaleCookie()
const liveSocket = new LiveSocket("/live", Socket, {
  params: () => ({
    _csrf_token: csrfToken,
    locale: storedLocale()
  }),
  hooks: Hooks,
  metadata: {
    click: (e, _el) => ({
      ctrl_key: e.ctrlKey,
      meta_key: e.metaKey,
      shift_key: e.shiftKey
    }),
    keydown: (e, _el) => ({
      key: e.key,
      ctrl_key: e.ctrlKey,
      meta_key: e.metaKey,
      shift_key: e.shiftKey
    }),
  }
})

liveSocket.connect()

window.liveSocket = liveSocket
