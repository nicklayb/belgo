// Exposes Heroicons (MIT, https://heroicons.com) as `hero-*` Tailwind classes, from
// the npm package (assets/package.json). Adapted from the Phoenix 1.8 generator.
const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function ({ matchComponents, theme }) {
  const iconsDirectory = path.join(__dirname, "../node_modules/heroicons")
  const values = {}
  const variants = [
    ["", "/24/outline"],
    ["-solid", "/24/solid"],
    ["-mini", "/20/solid"],
    ["-micro", "/16/solid"]
  ]

  variants.forEach(([suffix, directory]) => {
    fs.readdirSync(path.join(iconsDirectory, directory)).forEach(file => {
      const name = path.basename(file, ".svg") + suffix
      values[name] = { name, fullPath: path.join(iconsDirectory, directory, file) }
    })
  })

  matchComponents({
    "hero": ({ name, fullPath }) => {
      const content = encodeURIComponent(fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, ""))
      let size = theme("spacing.6")
      if (name.endsWith("-mini")) {
        size = theme("spacing.5")
      } else if (name.endsWith("-micro")) {
        size = theme("spacing.4")
      }
      return {
        [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--hero-${name})`,
        "mask": `var(--hero-${name})`,
        "mask-repeat": "no-repeat",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "width": size,
        "height": size
      }
    }
  }, { values })
})
