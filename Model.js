function emptyStatus() {
  return {
    emulator: { found: false, binary: "", name: "", ui: "", packageHint: "vice-sdl2" },
    running: { active: false, pid: 0, image: "", title: "", mode: "", paused: false },
    gamesDir: "",
    gamesDirExists: false,
    joystickPort: 2,
    joystick: "auto",
    warp: true,
    video: "pal",
    drive8: "",
    drive8Exists: false,
    cart: "",
    cartExists: false,
    lastMode: "",
    joysticks: [],
    lastError: ""
  }
}

function parseStatus(raw) {
  var status = emptyStatus()
  try {
    var parsed = raw ? JSON.parse(String(raw)) : null
    if (!parsed || typeof parsed !== "object") return status
    if (parsed.emulator && typeof parsed.emulator === "object") {
      status.emulator.found = parsed.emulator.found === true
      status.emulator.binary = parsed.emulator.binary || ""
      status.emulator.name = parsed.emulator.name || ""
      status.emulator.ui = parsed.emulator.ui || ""
      status.emulator.packageHint = parsed.emulator.packageHint || "vice-sdl2"
    }
    if (parsed.running && typeof parsed.running === "object") {
      status.running.active = parsed.running.active === true
      status.running.pid = parsed.running.pid || 0
      status.running.image = parsed.running.image || ""
      status.running.title = parsed.running.title || ""
      status.running.mode = parsed.running.mode || ""
      status.running.paused = parsed.running.paused === true
    }
    status.gamesDir = parsed.gamesDir || ""
    status.gamesDirExists = parsed.gamesDirExists === true
    status.joystickPort = parseInt(parsed.joystickPort, 10) === 1 ? 1 : 2
    status.joystick = parsed.joystick || "auto"
    status.warp = parsed.warp !== false
    status.video = parsed.video === "ntsc" ? "ntsc" : "pal"
    status.drive8 = parsed.drive8 || ""
    status.drive8Exists = parsed.drive8Exists === true
    status.cart = parsed.cart || ""
    status.cartExists = parsed.cartExists === true
    status.lastMode = parsed.lastMode || ""
    status.joysticks = Array.isArray(parsed.joysticks) ? parsed.joysticks : []
    status.lastError = parsed.lastError || ""
    return status
  } catch (e) {
    return status
  }
}

function basename(path) {
  var s = String(path || "")
  var slash = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"))
  return slash >= 0 ? s.substring(slash + 1) : s
}

function prettyName(path) {
  var base = basename(path)
  var dot = base.lastIndexOf(".")
  if (dot > 0) base = base.substring(0, dot)
  base = base.replace(/[_\-]+/g, " ").replace(/\s+/g, " ").trim()
  if (!base) return "Unknown"
  if (base === base.toLowerCase()) {
    var parts = base.split(" ")
    var out = []
    for (var i = 0; i < parts.length; i++) {
      if (!parts[i]) continue
      out.push(parts[i].charAt(0).toUpperCase() + parts[i].substring(1))
    }
    return out.join(" ")
  }
  return base
}

function portOptions() {
  return [
    { value: "2", label: "Port 2" },
    { value: "1", label: "Port 1" }
  ]
}

function videoOptions() {
  return [
    { value: "pal", label: "PAL" },
    { value: "ntsc", label: "NTSC" }
  ]
}

function joystickOptions(status) {
  var options = [
    { value: "auto", label: "Auto" },
    { value: "keyset", label: "Keyboard" },
    { value: "none", label: "None" }
  ]
  var pads = status && status.joysticks ? status.joysticks : []
  for (var i = 0; i < pads.length; i++) {
    var pad = pads[i]
    if (!pad || !pad.id) continue
    options.push({
      value: String(pad.id),
      label: pad.name || ("Pad " + (i + 1))
    })
  }
  return options
}

function videoLabel(status) {
  return (status && status.video === "ntsc") ? "NTSC" : "PAL"
}

function heroMeta(status) {
  if (!status || !status.emulator || !status.emulator.found) return "NO EMULATOR"
  var video = videoLabel(status)
  if (status.running && status.running.active) {
    if (status.running.paused) {
      var pausedTitle = status.running.title || prettyName(status.running.image) || prettyName(status.cart)
      return pausedTitle ? ("PAUSED · " + pausedTitle.toUpperCase()) : "PAUSED"
    }
    if (status.running.mode === "autostart") {
      var title = status.running.title || prettyName(status.running.image)
      return title ? ("PLAYING · " + title.toUpperCase()) : ("PLAYING · " + video)
    }
    if (status.cart) return "CART · " + prettyName(status.cart).toUpperCase()
    if (status.drive8) return "READY. · DRIVE 8"
    return "READY. · " + video
  }
  return "READY. · " + video
}

function drive8Label(status) {
  if (status && status.drive8) {
    var disk = prettyName(status.drive8)
    return status.drive8Exists === false ? (disk + " — missing") : disk
  }
  return "Empty. Choose a disk; does not start VICE."
}

function cartLabel(status) {
  if (status && status.cart) {
    var cart = prettyName(status.cart)
    return status.cartExists === false ? (cart + " — missing") : cart
  }
  return "Empty. Choose a cartridge; does not start VICE."
}

function cursorItems(status) {
  var items = []
  var found = status && status.emulator && status.emulator.found
  if (!found) return items
  items.push({ kind: "drive8" })
  if (status.drive8) items.push({ kind: "eject" })
  items.push({ kind: "cart" })
  if (status.cart) items.push({ kind: "ejectCart" })
  items.push({ kind: "play" })
  items.push({ kind: "power" })
  if (status.running && status.running.active) {
    items.push({ kind: "pause" })
    items.push({ kind: "reset" })
  }
  items.push({ kind: "joystick" })
  items.push({ kind: "port" })
  items.push({ kind: "video" })
  return items
}

function clampIndex(index, count) {
  if (count <= 0) return 0
  if (index < 0) return 0
  if (index > count - 1) return count - 1
  return index
}

function nextPort(current) {
  return parseInt(current, 10) === 1 ? "2" : "1"
}

function nextVideo(current) {
  return current === "ntsc" ? "pal" : "ntsc"
}
