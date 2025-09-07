--=== Player Piece Script (chess piece version) ===============================
-- No tinting is applied anymore.
-- Kept a "green" tint constant in code comments for reference only.
-- Exposes: setFlag/clearFlag/giveFlag/getFlag and setShield/clearShield/giveShield/getShield.
-- Publishes RR_FlagStatus_<Color> and RR_ShieldStatus_<Color> for compatibility.

-- ── SET THIS PER PIECE ──────────────────────────────────────────────────────
-- White Rook should be "Blue" in your mapping:
local OVERRIDE_COLOR = "Blue"
-- Change per piece:
--   Yellow (White Horse), Orange (White Bishop),
--   Purple (Black Rook),  Pink (Black Horse),  Green (Black Bishop)
-- ────────────────────────────────────────────────────────────────────────────

-- Safety name
local DEFAULT_PAWN_NAME = "Piece"

-- Keep a tint preset ONLY for code purposes; we do not apply it.
local COLOURS = {
  DeepGreen = {label="Deep green", tint={r=0.10,g=0.55,b=0.18}}, -- green for code purposes
}
local DEFAULT_TINT_FOR = {
  Green="DeepGreen", Yellow="DeepGreen", Orange="DeepGreen",
  Blue="DeepGreen",  Pink="DeepGreen",   Purple="DeepGreen",
}

-- Chess-name mapping for the right-click label
local CHESS_NAME_FOR = {
  Green  = "Black Bishop",
  Yellow = "White Horse",
  Orange = "White Bishop",
  Purple = "Black Rook",
  Pink   = "Black Horse",
  Blue   = "White Rook",
}

-- ===== Layout for the red flag panel =======================================
local HEAD_GAP_FRAC     = 0.06
local FLAG_PANEL_WIDTH  = 260
local FLAG_PANEL_HEIGHT = 90
local FLAG_PANEL_COLOR  = {1, 0, 0, 0.9}  -- red with slight transparency
local FLAG_TOOLTIP      = "FlagMarkerPanel"

-- ===== Layout for the cyan shield panel ====================================
local SHIELD_PANEL_WIDTH  = 260
local SHIELD_PANEL_HEIGHT = 90
local SHIELD_PANEL_COLOR  = {0, 0.65, 1, 0.9} -- cyan-ish with slight transparency
local SHIELD_TOOLTIP      = "ShieldMarkerPanel"
local SHIELD_X_OFFSET     = 0.35              -- offset so it doesn't overlap the flag panel

-- ===== Persistent state =====================================================
local S = { pieceColor = OVERRIDE_COLOR, colourKey = "DeepGreen", flagOn = false, shieldOn = false }

-- ---------- tint (disabled) ----------
local function applyPawnTint()
  -- Disabled: do not tint the object anymore.
  -- self.setColorTint(COLOURS.DeepGreen.tint)
end

-- ---------- helpers ----------
local function markerLocalY()
  local ok, bn = pcall(function() return self.getBoundsNormalized() end)
  if ok and bn and bn.size then
    local top = bn.size.y / 2
    return top + (bn.size.y * HEAD_GAP_FRAC)
  end
  return 1.0
end

-- ---------- FLAG panel (red badge) ----------
local function findFlagButtonIndex()
  for _,b in ipairs(self.getButtons() or {}) do
    if b.tooltip == FLAG_TOOLTIP then return b.index end
  end
  return nil
end
local function ensureFlagPanel()
  local idx = findFlagButtonIndex()
  local y   = markerLocalY()
  if idx then
    self.editButton({
      index=idx, position={0,y,0},
      width=FLAG_PANEL_WIDTH, height=FLAG_PANEL_HEIGHT, color=FLAG_PANEL_COLOR
    })
  else
    self.createButton({
      click_function="flagNoop", function_owner=self,
      label="", position={0,y,0}, rotation={0,0,0},
      width=FLAG_PANEL_WIDTH, height=FLAG_PANEL_HEIGHT, font_size=1,
      color=FLAG_PANEL_COLOR, font_color={0,0,0,0},
      tooltip=FLAG_TOOLTIP,
    })
  end
end
local function removeFlagPanel()
  local idx = findFlagButtonIndex()
  if idx then self.removeButton(idx) end
end
function flagNoop() end

-- ---------- SHIELD panel (cyan badge) ----------
local function findShieldButtonIndex()
  for _,b in ipairs(self.getButtons() or {}) do
    if b.tooltip == SHIELD_TOOLTIP then return b.index end
  end
  return nil
end
local function ensureShieldPanel()
  local idx = findShieldButtonIndex()
  local y   = markerLocalY()
  local x   = SHIELD_X_OFFSET
  if idx then
    self.editButton({
      index=idx, position={x,y,0},
      width=SHIELD_PANEL_WIDTH, height=SHIELD_PANEL_HEIGHT, color=SHIELD_PANEL_COLOR
    })
  else
    self.createButton({
      click_function="shieldNoop", function_owner=self,
      label="", position={x,y,0}, rotation={0,0,0},
      width=SHIELD_PANEL_WIDTH, height=SHIELD_PANEL_HEIGHT, font_size=1,
      color=SHIELD_PANEL_COLOR, font_color={0,0,0,0},
      tooltip=SHIELD_TOOLTIP,
    })
  end
end
local function removeShieldPanel()
  local idx = findShieldButtonIndex()
  if idx then self.removeButton(idx) end
end
function shieldNoop() end

-- ---------- Bridge to Global for AI/TurnToken compatibility ----------
local function publishFlagToGlobal()   Global.setVar("RR_FlagStatus_"..S.pieceColor, S.flagOn) end
local function publishShieldToGlobal() Global.setVar("RR_ShieldStatus_"..S.pieceColor, S.shieldOn) end

-- ---------- public API ----------
function setFlag(v)
  S.flagOn = (v == true)
  if S.flagOn then ensureFlagPanel() else removeFlagPanel() end
  buildMenu(); publishFlagToGlobal()
end
function clearFlag() setFlag(false) end
function giveFlag()  setFlag(true)  end
function getFlag()   return S.flagOn end

function setShield(v)
  S.shieldOn = (v == true)
  if S.shieldOn then ensureShieldPanel() else removeShieldPanel() end
  buildMenu(); publishShieldToGlobal()
end
function clearShield() setShield(false) end
function giveShield()  setShield(true)  end
function getShield()   return S.shieldOn end

function getPieceColor() return S.pieceColor end

-- ---------- menu (no colour items) ----------
local function toggleFlag()   setFlag(not S.flagOn)     end
local function toggleShield() setShield(not S.shieldOn) end
function buildMenu()
  self.clearContextMenu()
  self.addContextMenuItem((S.flagOn and "Flag: On" or "Flag: Off").." ("..S.pieceColor..")", toggleFlag)
  self.addContextMenuItem((S.shieldOn and "Shield: On" or "Shield: Off"), toggleShield)
end

-- ---------- persistence ----------
function onSave() return JSON.encode(S) end
function onLoad(saved_state)
  -- fallback name first
  self.setName(DEFAULT_PAWN_NAME)

  -- restore saved state, if any
  if saved_state and saved_state ~= "" then
    local ok, t = pcall(JSON.decode, saved_state)
    if ok and type(t)=="table" then S = t end
  end

  -- Force the logical color for this chess piece
  S.pieceColor = OVERRIDE_COLOR
  if not COLOURS[S.colourKey] then S.colourKey = DEFAULT_TINT_FOR[S.pieceColor] or "DeepGreen" end
  applyPawnTint() -- no-op

  -- Friendly chess name
  self.setName(CHESS_NAME_FOR[S.pieceColor] or ("Piece "..S.pieceColor))

  -- Menus + panels based on current state
  buildMenu()
  if S.flagOn   then ensureFlagPanel()   end
  if S.shieldOn then ensureShieldPanel() end

  -- Publish current states so Global readers see us immediately
  publishFlagToGlobal()
  publishShieldToGlobal()
end

function onScale() end
function onDropped() end
--===========================================================================--
