-- Conformance cases: each saved as <name>.aseprite in /tmp/asetest/cases
-- Run by tools/aseprite_conformance.sh: OUT is the folder the cases go in
local out = os.getenv("OUT") or "./"
local rgba = app.pixelColor.rgba

local function fill(img, f)
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      img:drawPixel(x, y, f(x, y))
    end
  end
end

local function save(spr, name)
  spr:saveAs(out .. name .. ".aseprite")
  spr:close()
end

-- 1. Every blend mode: a gradient under a gradient, with layer and cel opacity
local modes = {
  NORMAL=BlendMode.NORMAL, MULTIPLY=BlendMode.MULTIPLY, SCREEN=BlendMode.SCREEN, OVERLAY=BlendMode.OVERLAY,
  DARKEN=BlendMode.DARKEN, LIGHTEN=BlendMode.LIGHTEN, COLOR_DODGE=BlendMode.COLOR_DODGE, COLOR_BURN=BlendMode.COLOR_BURN,
  HARD_LIGHT=BlendMode.HARD_LIGHT, SOFT_LIGHT=BlendMode.SOFT_LIGHT, DIFFERENCE=BlendMode.DIFFERENCE, EXCLUSION=BlendMode.EXCLUSION,
  HSL_HUE=BlendMode.HSL_HUE, HSL_SATURATION=BlendMode.HSL_SATURATION, HSL_COLOR=BlendMode.HSL_COLOR, HSL_LUMINOSITY=BlendMode.HSL_LUMINOSITY,
  ADDITION=BlendMode.ADDITION, SUBTRACT=BlendMode.SUBTRACT, DIVIDE=BlendMode.DIVIDE,
}
for name, mode in pairs(modes) do
  local spr = Sprite(32, 32)
  local bottom = spr.layers[1]
  fill(spr.cels[1].image, function(x, y) return rgba(x * 8, 255 - y * 8, (x * y) % 256, 128 + x * 4) end)
  local top = spr:newLayer()
  top.blendMode = mode
  top.opacity = 200
  local img = Image(32, 32)
  fill(img, function(x, y) return rgba(255 - x * 7, y * 8, 128, y < 16 and 255 or 90 + y * 5) end)
  local cel = spr:newCel(top, 1, img, Point(0, 0))
  cel.opacity = 220
  save(spr, "blend_" .. name)
end

-- 2. Groups, hidden layers, a reference layer, z-index, cel offsets
do
  local spr = Sprite(24, 24)
  fill(spr.cels[1].image, function(x, y) return rgba(40, 40, 40, 255) end)
  local group = spr:newGroup()
  group.name = "Group"
  group.opacity = 150
  group.blendMode = BlendMode.SCREEN
  local a = spr:newLayer()
  a.name = "A"
  a.parent = group
  local ia = Image(10, 10)
  fill(ia, function(x, y) return rgba(255, 0, 0, 255) end)
  spr:newCel(a, 1, ia, Point(3, 4))
  local b = spr:newLayer()
  b.name = "B"
  b.parent = group
  local ib = Image(10, 10)
  fill(ib, function(x, y) return rgba(0, 0, 255, 200) end)
  local cb = spr:newCel(b, 1, ib, Point(8, 8))
  local hidden = spr:newLayer()
  hidden.name = "Hidden"
  hidden.isVisible = false
  local ih = Image(24, 24)
  fill(ih, function(x, y) return rgba(0, 255, 0, 255) end)
  spr:newCel(hidden, 1, ih, Point(0, 0))
  local z = spr:newLayer()
  z.name = "Z"
  local iz = Image(6, 6)
  fill(iz, function(x, y) return rgba(255, 255, 0, 255) end)
  local cz = spr:newCel(z, 1, iz, Point(9, 9))
  cz.zIndex = -2
  save(spr, "groups")
end

-- 3. Indexed with a transparent index and a background layer; grayscale
do
  local spr = Sprite(16, 16, ColorMode.INDEXED)
  local pal = Palette(8)
  for i = 0, 7 do pal:setColor(i, Color{ r = i * 36, g = 255 - i * 30, b = (i * 70) % 256, a = 255 }) end
  spr:setPalette(pal)
  spr.transparentColor = 3
  fill(spr.cels[1].image, function(x, y) return (x + y) % 8 end)
  local top = spr:newLayer()
  local img = Image(16, 16, ColorMode.INDEXED)
  fill(img, function(x, y) return (x * 3 + y) % 8 end)
  spr:newCel(top, 1, img, Point(0, 0))
  save(spr, "indexed")

  local g = Sprite(16, 16, ColorMode.GRAYSCALE)
  fill(g.cels[1].image, function(x, y) return app.pixelColor.graya(x * 16, 128 + y * 8) end)
  save(g, "grayscale")
end
do
  local spr = Sprite(12, 12, ColorMode.INDEXED)
  app.command.BackgroundFromLayer()
  fill(spr.cels[1].image, function(x, y) return (x * y) % 5 end)
  save(spr, "background")
end

-- 4. Frames: durations, linked cels, cel opacity, tags of every direction with repeats
do
  local spr = Sprite(8, 8)
  fill(spr.cels[1].image, function(x, y) return rgba(255, x * 30, y * 30, 255) end)
  spr.frames[1].duration = 0.05
  for i = 2, 6 do
    spr:newFrame()
    spr.frames[i].duration = 0.04 * i
    local img = Image(8, 8)
    fill(img, function(x, y) return rgba(i * 40, x * 30, y * 30, 120 + i * 20) end)
    spr:newCel(spr.layers[1], i, img, Point(0, 0)).opacity = 100 + i * 25
  end
  -- Frame 7 links frame 2's cel
  app.frame = spr.frames[2]
  app.command.NewFrame{ content = "cellinked" }
  local t1 = spr:newTag(1, 3) t1.name = "walk"
  local t2 = spr:newTag(2, 4) t2.name = "back" t2.aniDir = AniDir.REVERSE t2.repeats = 2
  local t3 = spr:newTag(3, 6) t3.name = "bounce" t3.aniDir = AniDir.PING_PONG t3.repeats = 3
  local t4 = spr:newTag(4, 7) t4.name = "rebound" t4.aniDir = AniDir.PING_PONG_REVERSE
  save(spr, "frames")
end

-- 5. Tilemaps: one tile with four different quarters, placed with every flip; tile properties
do
  local spr = Sprite(16, 8, ColorMode.RGB)
  app.command.NewLayer{ tilemap = true, gridBounds = Rectangle{ 0, 0, 4, 4 } }
  local mapLay = app.layer
  mapLay.name = "Ground"
  spr:deleteLayer(spr.layers[1])
  local tile = spr:newTile(mapLay.tileset, 1)
  fill(tile.image, function(x, y)
    if x < 2 and y < 2 then return rgba(255, 0, 0, 255) end
    if y < 2 then return rgba(0, 255, 0, 255) end
    if x < 2 then return rgba(0, 0, 255, 255) end
    return rgba(255, 255, 0, x == 3 and y == 3 and 120 or 255)
  end)
  local tile2 = spr:newTile(mapLay.tileset, 2)
  fill(tile2.image, function(x, y) return rgba(x * 60, 200, y * 60, 255) end)
  mapLay.tileset:tile(1).properties.collision = "solid"
  mapLay.tileset:tile(2).properties.area = "spikes"
  mapLay.tileset.properties.kind = "terrain"
  local map = Image{ width = 4, height = 2, colorMode = ColorMode.TILEMAP }
  spr:newCel(mapLay, 1, map, Point(0, 0))
  map = mapLay:cel(1).image
  local x, y, d = app.pixelColor.TILE_XFLIP, app.pixelColor.TILE_YFLIP, app.pixelColor.TILE_DFLIP
  local flags = { 0, x, y, x | y, d, x | d, y | d, x | y | d }
  for i, f in ipairs(flags) do
    map:drawPixel((i - 1) % 4, (i - 1) // 4, 1 | f)
  end
  save(spr, "tilemap_flips")
end

-- 6. User data of several types, slices with 9-patches and pivots
do
  local spr = Sprite(16, 16)
  spr.properties.text = "hello"
  spr.properties.count = 42
  spr.properties.ratio = 0.25
  spr.properties.on = true
  spr.properties.where = Point(3, 4)
  spr.layers[1].properties.layerProp = "L"
  spr.layers[1].data = "layer text"
  local s = spr:newSlice(Rectangle(2, 3, 10, 8))
  s.name = "hitbox"
  s.center = Rectangle(2, 2, 6, 4)
  s.pivot = Point(5, 7)
  s.properties.damage = 3
  save(spr, "userdata")
end

-- 7. A big noisy image: real compression
do
  local spr = Sprite(96, 96)
  local seed = 12345
  fill(spr.cels[1].image, function(x, y)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return rgba(seed % 256, (seed // 256) % 256, (x + y) % 256, 255)
  end)
  save(spr, "noise")
end
print("cases written")

-- 8. Features games use: a hitbox slice that moves (and hides), a pivot slice, a 9-patch slice,
-- frame events (a cel's text and `event` property on a hidden layer), Body and Sword layers
do
  local spr = Sprite(16, 16)
  spr.layers[1].name = "Body"
  fill(spr.cels[1].image, function(x, y) return (x >= 4 and x < 12 and y >= 2) and rgba(200, 120, 60, 255) or rgba(0, 0, 0, 0) end)
  local sword = spr:newLayer() sword.name = "Sword"
  local events = spr:newLayer() events.name = "events" events.isVisible = false
  for f = 2, 3 do spr:newFrame() end
  for f = 1, 3 do
    spr.frames[f].duration = 0.1
    local img = Image(16, 16)
    fill(img, function(x, y) return (y == 8 and x >= 8 + f) and rgba(220, 220, 255, 255) or rgba(0, 0, 0, 0) end)
    spr:newCel(sword, f, img, Point(0, 0))
  end
  local c2 = spr:newCel(events, 2, Image(1, 1), Point(0, 0)) c2.data = "step"
  local c3 = spr:newCel(events, 3, Image(1, 1), Point(0, 0)) c3.properties.event = "hit"
  local tag = spr:newTag(1, 3) tag.name = "attack"
  -- (Aseprite's Lua sets a slice's first key only: slices that move are in its own
  -- slices-moving.aseprite, testdata/aseprite)
  local hit = spr:newSlice(Rectangle(10, 6, 4, 4)) hit.name = "hitbox"
  local feet = spr:newSlice(Rectangle(4, 12, 8, 4)) feet.name = "feet" feet.pivot = Point(4, 4)
  local panel = spr:newSlice(Rectangle(0, 0, 16, 16)) panel.name = "panel" panel.center = Rectangle(4, 4, 8, 8)
  save(spr, "features")
end

-- 9. An animated tilemap: two frames, the water tile swapping, with a tag
do
  local spr = Sprite(8, 4, ColorMode.RGB)
  app.command.NewLayer{ tilemap = true, gridBounds = Rectangle{ 0, 0, 4, 4 } }
  local mapLay = app.layer
  mapLay.name = "Water"
  spr:deleteLayer(spr.layers[1])
  local a = spr:newTile(mapLay.tileset, 1) fill(a.image, function(x, y) return rgba(0, 0, 255, 255) end)
  local b = spr:newTile(mapLay.tileset, 2) fill(b.image, function(x, y) return rgba(0, 200, 255, 255) end)
  spr:newFrame()
  spr.frames[1].duration = 0.2
  spr.frames[2].duration = 0.3
  for f = 1, 2 do
    local map = Image{ width = 2, height = 1, colorMode = ColorMode.TILEMAP }
    spr:newCel(mapLay, f, map, Point(0, 0))
    map = mapLay:cel(f).image
    map:drawPixel(0, 0, f)
    map:drawPixel(1, 0, 3 - f)
  end
  local tag = spr:newTag(1, 2) tag.name = "flow"
  save(spr, "tilemap_animated")
end
print("feature cases written")
