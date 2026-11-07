// The language select of the settings page: shows the stored choice, stores a new
// one (localStorage + cookie, see ../locale.js) and reloads the page in it.
import {storeLocale, storedLocale} from "../locale"

export default {
  mounted() {
    this.el.value = storedLocale() || ""
    this.el.addEventListener("change", () => {
      storeLocale(this.el.value || null)
      window.location.reload()
    })
  }
}
