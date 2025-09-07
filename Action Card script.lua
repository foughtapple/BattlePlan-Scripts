-- =========================================
-- RoboRaid Card — owner privacy, group Ready, Reveal ON/OFF, REVEALED faces
-- (patched: TTS owner colors, ResetAll fixes + resets Ready/Reveal, menu order)
-- + "Blank" option (menu + tap-cycle). Ready click now toggles reveal.
-- =========================================

-- ===== GROUP MARKER =====
local OWNER_MARKER  = "RoboRaid:P1"   -- change to "RoboRaid:P2" for another group
local CARD_TYPE_TAG = "RoboRaidCard"

-- ===== ART (normal faces) =====
local CARD_BACK   = "https://i.imgur.com/XyP1IAy.png"
local ATTACK_FACE = "https://i.imgur.com/xlAkVIs.png"
local DEFEND_FACE = "https://i.imgur.com/KyX8luh.png"
local MOVE_FACE   = "https://i.imgur.com/otpexvI.png"

-- ===== ART (REVEALED faces) =====
local ATTACK_FACE_REV = "https://i.imgur.com/kWxbNAM.png"
local DEFEND_FACE_REV = "https://i.imgur.com/ydUbIew.png"
local MOVE_FACE_REV   = "https://i.imgur.com/ptHju55.png"

-- ===== BLANK faces =====
local BLANK_FACE     = "https://i.imgur.com/25FeCAz.png"
local BLANK_FACE_REV = "https://i.imgur.com/cLBtD1E.png"

-- ===== tap cycle params =====
local tapStartTime, tapStartPos = nil, nil
local TAP_MAX_DT, TAP_MAX_DIST = 0.25, 0.30

-- ===== state guards =====
local justReloaded = false   -- prevents spawn→reload→spawn loops

-- ======= Token tint control (conditional per OWNER_MARKER) =======
local GREEN_TINT  = {r=0.10, g=0.80, b=0.20}
local NO_TINT     = {r=1,    g=1,    b=1}

local function _selectedTokenGUIDs()
  -- If this card group is for P1, tint a9c4f3; if for P2, tint 773b16; otherwise none.
  if OWNER_MARKER == "RoboRaid:P1" then
    return {"a9c4f3"}
  elseif OWNER_MARKER == "RoboRaid:P2" then
    return {"773b16"}
  else
    return {}
  end
end

local function _setTokensTint(isOn)
  local col = isOn and GREEN_TINT or NO_TINT
  for _, gid in ipairs(_selectedTokenGUIDs()) do
    local o = getObjectFromGUID(gid)
    if o and o.setColorTint then
      pcall(function() o.setColorTint(col) end)
    end
  end
end
-- ===================================================================

-- ===== GM Notes helpers =====
local function getNotes() return self.getGMNotes() or "" end
local function setNotes(s) self.setGMNotes(s) end
local function getTag(key) return (getNotes():match("%["..key:gsub("(%W)","%%%1")..":([^%]]+)%]")) end
local function setTag(key, value)
  local notes = getNotes()
  local pat = "%["..key:gsub("(%W)","%%%1")..":[^%]]+%]"
  if notes:find(pat) then notes = notes:gsub(pat, "["..key..":"..value.."]", 1)
  else notes = (notes~="" and notes.."\n" or "").."["..key..":"..value.."]" end
  setNotes(notes)
end

local function ensureTags()
  setTag("TYPE",  CARD_TYPE_TAG)
  setTag("OWNER", OWNER_MARKER)
  if not getTag("OwnerColor")  then setTag("OwnerColor","None")  end  -- public until you pick Owner
  if not getTag("ReadyGlobal") then setTag("ReadyGlobal","0")     end
  if not getTag("Revealed")    then setTag("Revealed","0")        end
  if not getTag("FaceKind")    then setTag("FaceKind","ACTION")   end
end

local function ownerColor()     return getTag("OwnerColor") or "None" end
local function groupReadyFlag() return (getTag("ReadyGlobal") == "1") end
local function revealedFlag()   return (getTag("Revealed")    == "1") end
local function getFaceKind()    return getTag("FaceKind") or "ACTION" end
local function setFaceKind(k)   setTag("FaceKind", k) end

-- ===== visibility =====
local function othersExcept(color)
  local out, seated = {}, getSeatedPlayers()
  for _,c in ipairs(seated) do if c ~= color then table.insert(out, c) end end
  return out
end

-- (PATCH: make global so o.call can reach it)
function enforceVisibility()
  local col = ownerColor()
  if revealedFlag() or col == "None" then
    self.setHiddenFrom({})
  else
    self.setHiddenFrom(othersExcept(col))
  end
end

-- ===== faces (reload only when URL changes) =====
local function currentFaceURL()
  local co = self.getCustomObject() or {}
  return co.face
end

function applyFaceForState()
  local kind, rev = getFaceKind(), revealedFlag()
  local want = CARD_BACK
  if     kind == "MOVE"    then want = rev and MOVE_FACE_REV   or MOVE_FACE
  elseif kind == "ATTACK"  then want = rev and ATTACK_FACE_REV or ATTACK_FACE
  elseif kind == "DEFEND"  then want = rev and DEFEND_FACE_REV or DEFEND_FACE
  elseif kind == "BLANK"   then want = rev and BLANK_FACE_REV  or BLANK_FACE
  else want = CARD_BACK end

  if currentFaceURL() ~= want then
    justReloaded = true
    self.setCustomObject({face=want, back=CARD_BACK})
    self.reload()
  end
end

local function setReveal(on)
  setTag("Revealed", on and "1" or "0")
  enforceVisibility()
  applyFaceForState()
  Wait.time(function() addMenu() end, 0.1)
end

local function resetThis()
  setTag("Revealed","0")
  setFaceKind("ACTION")
  enforceVisibility()
  applyFaceForState()
  Wait.time(function() addMenu() end, 0.1)
end

local function setMove()   setFaceKind("MOVE");   enforceVisibility(); applyFaceForState() end
local function setAttack() setFaceKind("ATTACK"); enforceVisibility(); applyFaceForState() end
local function setDefend() setFaceKind("DEFEND"); enforceVisibility(); applyFaceForState() end
local function setBlank()  setFaceKind("BLANK");  enforceVisibility(); applyFaceForState() end

-- ===== group ops =====
local function isSameGroupCard(obj)
  if not obj or obj.tag ~= "Card" then return false end
  local s = obj.getGMNotes() or ""
  return s:find("%[TYPE:"..CARD_TYPE_TAG.."%]") and s:find("%[OWNER:"..OWNER_MARKER.."%]")
end

local function getOwnerColorFromNotes(obj)
  local s = obj.getGMNotes() or ""
  return s:match("%[OwnerColor:([^%]]+)%]") or "None"
end

-- (helper: read a tag value from raw notes string, default if missing)
local function _readTag(notes, key, defaultVal)
  local v = notes:match("%["..key..":([^%]]+)%]")
  return v or defaultVal
end

-- (helper: write/replace a tag in a raw notes string)
local function _writeTag(notes, key, value)
  local pat = "%["..key..":[^%]]+%]"
  if notes:find(pat) then
    return notes:gsub(pat, "["..key..":"..value.."]", 1)
  else
    return (notes~="" and notes.."\n" or "").."["..key..":"..value.."]"
  end
end

local function setReadyGlobal(on)
  local flag = on and "1" or "0"

  -- 1) Set ReadyGlobal on all group cards (unchanged)
  for _,o in ipairs(getAllObjects()) do
    if isSameGroupCard(o) then
      local s = o.getGMNotes() or ""
      s = _writeTag(s, "ReadyGlobal", flag)
      o.setGMNotes(s)
      o.call("addMenu")
    end
  end

  -- 2) When turning Ready ON: ACTION or BLANK -> BLANK + REVEALED (forced ON)
  if on then
    local changed = 0
    for _,o in ipairs(getAllObjects()) do
      if isSameGroupCard(o) then
        local s = o.getGMNotes() or ""
        local faceKind = _readTag(s, "FaceKind", "ACTION")
        if faceKind == "ACTION" or faceKind == "BLANK" then
          s = _writeTag(s, "FaceKind", "BLANK")
          s = _writeTag(s, "Revealed", "1")   -- force reveal ON (no toggle)
          o.setGMNotes(s)
          o.call("enforceVisibility")
          o.call("applyFaceForState")
          o.call("addMenu")
          changed = changed + 1
        end
      end
    end
    if changed > 0 then
      print(("Ready (All): %d card(s) forced to BLANK and REVEALED."):format(changed))
    end
  end

  -- 3) Tint the selected token when Ready ON; clear tint when OFF (unchanged)
  _setTokensTint(on)

  print("Ready (All) set to "..(on and "ON" or "OFF").." for this group.")
end


-- (PATCH: TTS standard seat colors + None/public)
local TTS_OWNER_COLORS = {
  "None", "White","Brown","Red","Orange","Yellow","Green","Teal","Blue","Purple","Pink","Grey","Black"
}

local function setOwnerOnAll(colorName)
  for _,o in ipairs(getAllObjects()) do
    if isSameGroupCard(o) then
      local s = o.getGMNotes() or ""
      s = _writeTag(s, "OwnerColor", colorName)
      o.setGMNotes(s)
      -- update visibility immediately if unrevealed
      local rv = (s:match("%[Revealed:(%d)%]") == "1")
      if not rv then
        if colorName == "None" then o.setHiddenFrom({}) else
          -- respect seat list
          local out, seated = {}, getSeatedPlayers()
          for _,c in ipairs(seated) do if c ~= colorName then table.insert(out, c) end end
          o.setHiddenFrom(out)
        end
      end
      o.call("applyFaceForState")
      o.call("addMenu")
    end
  end
  print("Owner set to "..colorName.." for all cards in this group.")
end

-- (PATCH: Reset All now also clears ReadyGlobal and Revealed on each card)
local function resetAllGroup()
  -- turn Ready (All) OFF first
  setReadyGlobal(false)

  local n=0
  for _,o in ipairs(getAllObjects()) do
    if isSameGroupCard(o) then
      local s = o.getGMNotes() or ""
      s = _writeTag(s, "Revealed", "0")
      s = _writeTag(s, "FaceKind", "ACTION")
      o.setGMNotes(s)
      o.call("enforceVisibility")
      o.call("applyFaceForState")
      o.call("addMenu")
      n=n+1
    end
  end
  print("Reset All: "..n.." cards set to Action; Reveal OFF; Ready (All) OFF.")
end

-- ===== tap detection =====
function onPickUp(player_color)
  tapStartTime = Time.time
  tapStartPos  = self.getPosition()
end

-- (ADJUSTED) Click toggles reveal when Ready is ON; cycles when not Ready & unrevealed
function onDropped(player_color)
  if not tapStartTime then return end
  local dt = Time.time - tapStartTime
  local p  = self.getPosition()
  local dx = p.x - tapStartPos.x
  local dz = p.z - tapStartPos.z
  local dist = math.sqrt(dx*dx + dz*dz)
  tapStartTime, tapStartPos = nil, nil
  if dt <= TAP_MAX_DT and dist <= TAP_MAX_DIST then
    if groupReadyFlag() then
      -- toggle reveal ON/OFF
      setReveal(not revealedFlag())
    elseif not revealedFlag() then
      -- cycle when Ready OFF & unrevealed
      local k = getFaceKind()
      if     k == "ACTION" then setMove()
      elseif k == "MOVE"   then setAttack()
      elseif k == "ATTACK" then setDefend()
      elseif k == "DEFEND" then setBlank()
      else resetThis() end
    end
  end
end

-- ===== menu =====
function addMenu()
  self.clearContextMenu()

  -- (PATCH: Ready at top, Reset All second)
  local readyLabel = groupReadyFlag() and "Ready (All): ON" or "Ready (All): OFF"
  self.addContextMenuItem(readyLabel, function() setReadyGlobal(not groupReadyFlag()) end)

  self.addContextMenuItem("Reset All", function() resetAllGroup() end)

  local revLabel = revealedFlag() and "Reveal: ON" or "Reveal: OFF"
  self.addContextMenuItem(revLabel, function() setReveal(not revealedFlag()) end)

  self.addContextMenuItem("Reset this one", function() resetThis() end)
  self.addContextMenuItem("Move",   function() setMove()   end)
  self.addContextMenuItem("Attack", function() setAttack() end)
  self.addContextMenuItem("Defend", function() setDefend() end)
  self.addContextMenuItem("Blank",  function() setBlank()  end)

  -- flat Owner color list (TTS standard + None/public)
  for _,c in ipairs(TTS_OWNER_COLORS) do
    local label = (c == "None") and "Owner: None (public)" or ("Owner: "..c)
    self.addContextMenuItem(label, function() setOwnerOnAll(c) end)
  end
end

-- ===== lifecycle =====
function onLoad()
  -- force a stable display name for this card (as requested)

  ensureTags()
  local co = self.getCustomObject()
  if not co or not co.face or not co.back then
    justReloaded = true
    self.setCustomObject({face=CARD_BACK, back=CARD_BACK})
    self.reload()
  end
  Wait.time(function()
    enforceVisibility()
    applyFaceForState()
    addMenu()
  end, 0.25)
end

function onObjectSpawn(obj)
  if obj ~= self then return end
  if justReloaded then
    justReloaded = false
    Wait.time(function()
      enforceVisibility()
      addMenu()
    end, 0.05)
  end
end
