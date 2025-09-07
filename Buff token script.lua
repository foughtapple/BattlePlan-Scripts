-- Buff Token (Checker) script
-- • Randomizes to a square on the classic chessboard.
-- • If a piece is on the token: draw 1 buff for that piece’s owner, then randomize.
-- • If we land on a piece after randomizing: draw for that owner and randomize again,
--   repeating until we land on an empty square.
-- • Deck handling:
--     - Keep a sticky Buff Deck GUID once found.
--     - If the deck is missing when drawing: look for a discard pile, flip/shuffle it,
--       move it to the deck’s home, adopt its GUID as the new Buff Deck, then draw.
--     - If neither deck nor discard exist: SKIP draw (never pull from player hands).
-- • Automatically unlocks deck/discard as needed.
-- • Provides a compatibility shim: randomizePosition() (called by Turn Token).

------------------------------------------------------------
-- Configuration
------------------------------------------------------------
local chessboardGUID = "c12b07"  -- your chessboard
local TRIGGER_DELAY   = 0.5      -- after a piece lands on token before auto-randomize
local COOLDOWN_SEC    = 0.5
local TOKEN_TOUCH_R2  = (1.4*1.4) -- radius^2 to consider "on the token"
local MAX_CHAIN_TRIES = 24       -- safety bound for chain randomize

------------------------------------------------------------
-- Debug
------------------------------------------------------------
local DEBUG_ON = false
local function LOG(s) if DEBUG_ON then print("[BuffToken] "..tostring(s)) end end
local function LOGF(fmt, ...) if DEBUG_ON then print("[BuffToken] "..string.format(fmt, ...)) end end

------------------------------------------------------------
-- State
------------------------------------------------------------
local boardSquares = {}
local cooldown      = false
local selfJustMoved = false
local chainActive   = false

-- Sticky deck info (survives through draws)
local BUFF_DECK_GUID = nil
local DECK_HOME_POS  = nil
local DECK_HOME_ROT  = nil

------------------------------------------------------------
-- RR constants bridge (piece GUIDs → colors)
------------------------------------------------------------
local RR_CONST = nil
local GUID2COLOR = nil

local function RR_const()
  if not RR_CONST then
    local ok, raw = pcall(function() return Global.call("RR_const_JSON") end)
    if ok and type(raw)=="string" and #raw>0 then
      local ok2, data = pcall(JSON.decode, raw)
      RR_CONST = (ok2 and type(data)=="table") and data or {}
      LOG("Loaded RR_const via JSON.")
    else
      RR_CONST = {}
      LOG("RR_const not available; using empty.")
    end
  end
  return RR_CONST
end

local function rebuildGuidMap()
  GUID2COLOR = {}
  local rr = (RR_const().RR or {})
  local pieces = rr.PIECES or {}
  for color, guid in pairs(pieces) do GUID2COLOR[guid] = color end
end

local function pieceColorFromObject(obj)
  if not obj then return nil end
  if not GUID2COLOR then rebuildGuidMap() end
  local gid = obj.getGUID and obj:getGUID() or nil
  local c = gid and GUID2COLOR[gid] or nil
  LOGF("pieceColorFromObject(%s) → %s", tostring(gid), tostring(c))
  return c
end

local function seatForPieceColor(color)
  if not color then return nil end
  if color=="Blue" or color=="Pink" or color=="Purple" then
    return (RR_const().RR or {}).PLAYER2 or "Blue" -- P2 seat name
  end
  if color=="Green" or color=="Yellow" or color=="Orange" then
    return "White" -- P1 seat
  end
  return nil
end

------------------------------------------------------------
-- Utils
------------------------------------------------------------
local function dist2XZ(a, b) local dx, dz = a.x - b.x, a.z - b.z; return dx*dx + dz*dz end
local function guidOf(o) return tostring(o and o.getGUID and o:getGUID() or "nil") end

local function ensureUnlocked(obj, label)
  if not obj then return end
  local nm = label or (obj.getName and obj:getName() or obj.tag or guidOf(obj))
  local ok, locked = pcall(function() return obj.getLock and obj:getLock() or false end)
  if ok and locked then pcall(function() obj.setLock(false) end); LOGF("Unlocked %s", tostring(nm)) end
  pcall(function() obj.setLock(false) end)
end

------------------------------------------------------------
-- Board squares
------------------------------------------------------------
local function getBoard()
  local b = getObjectFromGUID(chessboardGUID)
  if not b then LOG("getBoard(): Chessboard NOT found. Check GUID.") end
  return b
end

function buildBoardSquares()
  local board = getBoard()
  if not board then return end

  local boardPos = board.getPosition()
  local boardRot = board.getRotation()
  local squareSize = 2
  local half = 8 / 2

  boardSquares = {}
  for i = 0, 7 do
    for j = 0, 7 do
      local offsetX = (i - (half - 0.5)) * squareSize
      local offsetZ = (j - (half - 0.5)) * squareSize

      local rad = math.rad(boardRot.y)
      local worldX = boardPos.x + offsetX * math.cos(rad) - offsetZ * math.sin(rad)
      local worldZ = boardPos.z + offsetX * math.sin(rad) + offsetZ * math.cos(rad)

      table.insert(boardSquares, { x = worldX, y = boardPos.y + 2, z = worldZ })
    end
  end
  LOGF("buildBoardSquares(): %d squares computed.", #boardSquares)
end

------------------------------------------------------------
-- Locate Buff Deck / Discard
------------------------------------------------------------
local function scanByNameOrTag(hints)
  local best, bestd
  local ref = self.getPosition()
  local function matchesName(nm)
    local low = string.lower(nm or "")
    for _,h in ipairs(hints or {}) do if low:find(string.lower(h), 1, true) then return true end end
    return false
  end
  local function matchesTag(o)
    local tags = o.getTags and o:getTags() or {}
    for _,t in ipairs(tags) do
      for _,h in ipairs(hints or {}) do if string.lower(t or "")==string.lower(h) then return true end end
    end
    return false
  end
  for _,o in ipairs(getAllObjects()) do
    if o and (o.tag=="Deck" or o.tag=="Card") then
      if matchesName(o.getName and o:getName() or "") or matchesTag(o) then
        local d2 = dist2XZ(o.getPosition(), ref)
        if (not best) or d2 < bestd then best, bestd = o, d2 end
      end
    end
  end
  LOGF("scanByNameOrTag(%s) → %s (%s)", table.concat(hints or {}, "/"), tostring(best and best.tag or "nil"), guidOf(best))
  return best
end

-- Remember where the deck lives once we see it so we can rebuild to that spot
local function recordDeckHome(deck)
  if not deck then return end
  DECK_HOME_POS = deck.getPosition()
  DECK_HOME_ROT = deck.getRotation()
  BUFF_DECK_GUID = deck.getGUID()
  LOGF("Deck home recorded: GUID=%s pos=(%.2f,%.2f,%.2f)", BUFF_DECK_GUID, DECK_HOME_POS.x, DECK_HOME_POS.y, DECK_HOME_POS.z)
end

local function locateBuffDeckFresh()
  local rr = (RR_const().RR or {})
  local candidates = { rr.BUFF_DECK, rr.BUFFDECK, rr.BUFF, rr.BUFF_DECK_GUID, rr.BUFFGUID }
  for _,g in ipairs(candidates) do
    if type(g)=="string" and #g>0 then
      local o = getObjectFromGUID(g)
      if o and (o.tag=="Deck" or o.tag=="Card") then ensureUnlocked(o, "BUFF_CONST"); recordDeckHome(o); return o, "const" end
    end
  end
  local found = scanByNameOrTag({"buff","buff deck"})
  if found then ensureUnlocked(found, "BUFF_SCAN"); recordDeckHome(found); return found, "scan" end
  return nil, "none"
end

local function getBuffDeckByStickyGUID()
  if BUFF_DECK_GUID then
    local o = getObjectFromGUID(BUFF_DECK_GUID)
    if o and (o.tag=="Deck" or o.tag=="Card") then ensureUnlocked(o, "BUFF_STICKY"); return o, "sticky" end
  end
  return nil, "none"
end

local function locateDiscard()
  local rr = (RR_const().RR or {})
  local candidates = { rr.DISCARD, rr.BUFF_DISCARD, rr.DISCARD_GUID, rr.BUFFDISCARD }
  for _,g in ipairs(candidates) do
    if type(g)=="string" and #g>0 then
      local o = getObjectFromGUID(g)
      if o and (o.tag=="Deck" or o.tag=="Card") then ensureUnlocked(o, "DISCARD_CONST"); return o, "const" end
    end
  end
  local found = scanByNameOrTag({"discard","buff discard"})
  if found then ensureUnlocked(found, "DISCARD_SCAN"); return found, "scan" end
  return nil, "none"
end

-- Make sure we have a live deck: try sticky GUID → fresh locate → rebuild from discard
local function ensureBuffDeck()
  -- Try sticky
  local deck, src = getBuffDeckByStickyGUID()
  if deck then return deck, src end

  -- Try fresh locate
  deck, src = locateBuffDeckFresh()
  if deck then return deck, src end

  -- Rebuild from discard
  local discard, dsrc = locateDiscard()
  if not discard then
    LOG("ensureBuffDeck: no Buff Deck or Discard found → skip draw.")
    return nil, "none"
  end

  LOGF("ensureBuffDeck: rebuilding from DISCARD (src=%s, GUID=%s)", tostring(dsrc), guidOf(discard))
  ensureUnlocked(discard, "DISCARD→DECK")

  -- Flip to face-down (toggle once; we don't try to detect prior state)
  pcall(function() discard.flip() end)

  -- Shuffle if it's a multi-card deck
  if discard.tag=="Deck" then pcall(function() discard.shuffle() end) end

  -- Move to deck home (or near the token if we never had a home yet)
  local destPos = DECK_HOME_POS or (self.getPosition() + Vector(3, 0.2, 0))
  local destRot = DECK_HOME_ROT or {0,180,0}
  discard.setRotationSmooth(destRot, false, true)
  discard.setPositionSmooth(destPos, false, true)

  Wait.time(function()
    if discard.tag=="Deck" then pcall(function() discard.shuffle() end) end
  end, 0.4)

  recordDeckHome(discard)
  return discard, "rebuilt"
end

------------------------------------------------------------
-- Drawing: strictly from deck (never from hands)
------------------------------------------------------------
local function drawOneBuffToSeat(seat)
  if not seat then LOG("drawOneBuffToSeat(nil) → skip"); return false end

  -- First, try Global helpers if present
  local ok, res
  if seat=="White" then ok, res = pcall(function() return Global.call("RR_DealBuff_P1") end)
  else ok, res = pcall(function() return Global.call("RR_DealBuff") end) end
  if ok and (res==true or res==nil) then
    LOGF("Global deal success for %s.", tostring(seat))
    return true
  end

  -- Otherwise: ensure we have a real deck; if not, skip (do NOT take from hands)
  local deck, src = ensureBuffDeck()
  if not deck then
    LOGF("No deck available for %s (src=%s) → SKIP draw.", tostring(seat), tostring(src))
    return false
  end

  ensureUnlocked(deck, "DEAL_SOURCE")
  LOGF("Dealing 1 buff to %s from %s (tag=%s GUID=%s)", tostring(seat), tostring(src), tostring(deck.tag), guidOf(deck))
  local dealtOK = pcall(function() deck.deal(1, seat) end)
  if not dealtOK then
    LOGF("Deck.deal failed for %s → SKIP (no fallbacks).", tostring(seat))
    return false
  end
  return true
end

------------------------------------------------------------
-- Occupancy & randomize
------------------------------------------------------------
local function occupantAtToken()
  local rr = (RR_const().RR or {})
  local pieces = rr.PIECES or {}
  if not pieces or not next(pieces) then return nil, nil, nil end

  local pos = self.getPosition()
  local bestColor, bestGUID, bestD2
  for color, guid in pairs(pieces) do
    local obj = getObjectFromGUID(guid)
    if obj then
      local p = obj.getPosition()
      local d2 = dist2XZ(pos, p)
      if d2 <= TOKEN_TOUCH_R2 and (not bestD2 or d2 < bestD2) then
        bestColor, bestGUID, bestD2 = color, guid, d2
      end
    end
  end
  if bestColor then
    return bestColor, seatForPieceColor(bestColor), math.sqrt(bestD2 or 0)
  end
  return nil, nil, nil
end

local function pickNewSquareFarFrom(currentPos, minDist)
  buildBoardSquares()
  if #boardSquares == 0 then return currentPos end
  local choice = boardSquares[math.random(1, #boardSquares)]
  local tries = 10
  while tries > 0 do
    local dx = choice.x - currentPos.x
    local dz = choice.z - currentPos.z
    if math.sqrt(dx*dx + dz*dz) >= (minDist or 0) then
      return choice
    end
    choice = boardSquares[math.random(1, #boardSquares)]
    tries = tries - 1
  end
  return choice
end

local function randomizeOnce(afterLanded)
  local target = pickNewSquareFarFrom(self.getPosition(), 0.9)
  LOGF("randomizeOnce → (%.2f, %.2f, %.2f)", target.x, target.y, target.z)
  selfJustMoved = true
  self.setPositionSmooth(target, false, true)
  Wait.condition(function()
    selfJustMoved = false
    if afterLanded then afterLanded() end
  end, function() return not self.isSmoothMoving() end)
end

local function startRandomizeChain(maxTries)
  if chainActive then
    LOG("startRandomizeChain: already active; ignoring.")
    return
  end
  chainActive = true
  cooldown = true
  local triesLeft = maxTries or MAX_CHAIN_TRIES

  local function step()
    if triesLeft <= 0 then
      LOG("Randomize chain: max attempts reached; stopping.")
      chainActive = false
      Wait.time(function() cooldown = false end, COOLDOWN_SEC)
      return
    end
    triesLeft = triesLeft - 1
    randomizeOnce(function()
      local occColor, occSeat, dist = occupantAtToken()
      if occSeat then
        LOGF("Landed on %s (d=%.3f) → draw 1 buff to %s, then randomize again. (%d tries left)",
             tostring(occColor), tonumber(dist or 0), tostring(occSeat), triesLeft)
        drawOneBuffToSeat(occSeat)
        Wait.time(step, 0.1)
      else
        LOG("Landed on an empty square — chain finished.")
        chainActive = false
        Wait.time(function() cooldown = false end, COOLDOWN_SEC)
      end
    end)
  end

  step()
end

------------------------------------------------------------
-- Auto-trigger from collisions
------------------------------------------------------------
local function isOnTop(other)
  if not other then return false end
  local a = self.getPosition()
  local b = other.getPosition()
  local above = (b.y > a.y + 0.15)
  local dx, dz = b.x - a.x, b.z - a.z
  local close = (dx*dx + dz*dz) <= TOKEN_TOUCH_R2
  if DEBUG_ON then LOGF("isOnTop? above=%s close=%s (d2=%.3f)", tostring(above), tostring(close), (dx*dx+dz*dz)) end
  return above and close
end

local function otherIsResting(other)
  if not other then return false end
  if other.held_by_color and other.held_by_color ~= "" then return false end
  if other.resting ~= nil then return other.resting end
  local v = other.getVelocity()
  return (v.x*v.x + v.y*v.y + v.z*v.z) < 0.04
end

local function drawForOtherPiece(other)
  local pColor = pieceColorFromObject(other)
  if not pColor then
    LOGF("drawForOtherPiece: unrecognized object %s", guidOf(other))
    return false
  end
  local seat = seatForPieceColor(pColor)
  if not seat then
    LOGF("drawForOtherPiece: no seat for piece color %s.", tostring(pColor))
    return false
  end
  LOGF("Drawing 1 Buff for seat %s (owner of %s).", tostring(seat), tostring(pColor))
  return drawOneBuffToSeat(seat)
end

local function tryAutoRandomize(other)
  if cooldown or selfJustMoved or chainActive then
    LOGF("tryAutoRandomize: ignored (cooldown=%s, selfJustMoved=%s, chainActive=%s)",
         tostring(cooldown), tostring(selfJustMoved), tostring(chainActive))
    return
  end
  if not other or other == self then return end

  LOGF("tryAutoRandomize: candidate %s (%s)", guidOf(other), tostring(other and other.tag or "nil"))

  Wait.time(function()
    if self.isDestroyed() then return end
    if not selfJustMoved and isOnTop(other) and otherIsResting(other) then
      cooldown = true
      LOG("Auto-trigger: piece on token → draw then randomize-until-blank")
      -- Draw BEFORE the randomize chain
      drawForOtherPiece(other)
      startRandomizeChain(MAX_CHAIN_TRIES)
    end
  end, TRIGGER_DELAY)
end

function onCollisionEnter(info) tryAutoRandomize(info.collision_object) end
function onCollisionStay(info)  tryAutoRandomize(info.collision_object) end

------------------------------------------------------------
-- Lifecycle / Menus / Debug
------------------------------------------------------------
function debugDump()
  local rr = (RR_const().RR or {})
  local pieces = rr.PIECES or {}
  LOG("=== DEBUG DUMP ===")
  LOGF("boardSquares=%d cooldown=%s selfJustMoved=%s chainActive=%s", #boardSquares, tostring(cooldown), tostring(selfJustMoved), tostring(chainActive))
  for c,g in pairs(pieces) do
    local o = getObjectFromGUID(g)
    LOGF("Piece %s → %s (%s)", tostring(c), tostring(g), tostring(o and o.tag or "missing"))
  end
  local deck = BUFF_DECK_GUID and getObjectFromGUID(BUFF_DECK_GUID) or nil
  LOGF("BUFF_DECK_GUID=%s (%s)", tostring(BUFF_DECK_GUID), tostring(deck and deck.tag or "nil"))
  if DECK_HOME_POS then LOGF("DECK_HOME_POS=(%.2f,%.2f,%.2f)", DECK_HOME_POS.x, DECK_HOME_POS.y, DECK_HOME_POS.z) end
end

function onDropped(_color)
  LOGF("onDropped by %s", tostring(_color))
  selfJustMoved = true
  Wait.condition(function() selfJustMoved = false end, function() return not self.isSmoothMoving() end)
  Wait.time(function() selfJustMoved = false end, 0.8)
end

function onLoad()
  math.randomseed(os.time())
  self.addContextMenuItem("Randomize", randomizePosition)  -- compatibility shim below
  self.addContextMenuItem("Debug: Dump", debugDump)
  buildBoardSquares()
  RR_const(); rebuildGuidMap()
  LOG("Buff token loaded; debug ON.")
end

------------------------------------------------------------
-- Compatibility shim: called by Turn Token via tok.call("randomizePosition")
------------------------------------------------------------
function randomizePosition(_playerColor)
  startRandomizeChain(MAX_CHAIN_TRIES)
end
