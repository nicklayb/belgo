// The interface language chosen on the settings page lives in localStorage; it is
// mirrored in a cookie so the server renders the first page in it, and sent as the
// LiveView `locale` connect param. No choice: the browser's language applies.
const STORAGE_KEY = "belgo:locale"
const COOKIE = "belgo_locale"
const COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365

export const storedLocale = () => {
  try {
    return localStorage.getItem(STORAGE_KEY) || null
  } catch (_error) {
    return null
  }
}

const writeCookie = locale => {
  document.cookie = locale
    ? `${COOKIE}=${locale}; path=/; max-age=${COOKIE_MAX_AGE_SECONDS}; samesite=lax`
    : `${COOKIE}=; path=/; max-age=0; samesite=lax`
}

// Keeps the cookie in line with localStorage (e.g. after the cookie expired).
export const syncLocaleCookie = () => writeCookie(storedLocale())

export const storeLocale = locale => {
  try {
    if (locale) localStorage.setItem(STORAGE_KEY, locale)
    else localStorage.removeItem(STORAGE_KEY)
  } catch (_error) {
    // Storage disabled: the cookie still carries the choice.
  }
  writeCookie(locale)
}
