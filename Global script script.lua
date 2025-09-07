--[[ Lua code. See documentation: https://api.tabletopsimulator.com/ --]]

----------------------------------------------------------------
--========================== INDEX ============================--
--  1) Dice Display: Config, State, Save/Load, Events, Update
--  2) Dice Tokens: Spawning & Resolution, Utilities
--  3) BattlePlan Core: Constants, Board/Home builders, Classify (verbose)
--  4) Movement: Square → World, Piece/Token movers
--  5) Pawn/Token Classify (quiet, overrides verbose)
--  6) Buff System: Deck finding, dealing, placing, flipping
--  7) Action Cards (P2): Helpers & mass updates
--  8) Action/Buff Read Helpers: Privacy-aware readers
--  9) World Snapshot: Cache + one-call scan
--============================================================--
----------------------------------------------------------------

-- Global script (top level, not local)
SAVE_STATE = true   -- flip to false to disable saving


----------------------------------------------------------------
-- 1) DICE DISPLAY — CONFIG, STATE, SAVE/LOAD, EVENTS, UPDATE --
----------------------------------------------------------------

-- Dice GUIDs (left→right in the display)
local DICE_GUIDS = { "f28006", "3c14ae", "315574" }

-- Face images 1..6
local FACE_URLS = {
  [1] = "https://i.imgur.com/JsujJkF.png",
  [2] = "https://i.imgur.com/tVoWu8n.png",
  [3] = "https://i.imgur.com/ttIkOdi.png",
  [4] = "https://i.imgur.com/dANJkNk.png",
  [5] = "https://i.imgur.com/uxB8ysU.png",
  [6] = "https://i.imgur.com/5L5e1ce.png",
}

-- Display token sizing/placement
local TOKEN_DIAMETER = 0.9
local TOKEN_THICK    = 0.18
local ROW_SPACING    = 2.2
local ROW_Z_OFFSET   = 2.8
local ROW_Y_OFFSET   = 1.1

-- Persistent state (mod-saved)
local STATE = { created = false, tokenGuids = { nil, nil, nil } }

-- Map die GUID → index (1..3)
local function dieIndex(g)
  for i=1,3 do if DICE_GUIDS[i] == g then return i end end
  return nil
end

--==== SAVE / LOAD PERSISTENCE ====--
local SAVE_STATE = false

function onSave()
  -- Persist the STATE table so tokens don’t keep respawning
  return JSON.encode(STATE)
end

function onLoad(saved_data)
  if saved_data and saved_data ~= "" then
    local ok, data = pcall(JSON.decode, saved_data)
    if ok and type(data) == "table" then
      STATE = data
    end
  end

  if not STATE.created then
    spawnTokensOnce(function()
      STATE.created = true
      STATE.tokenGuids = STATE.tokenGuids or { nil, nil, nil }
      Wait.time(updateAllDisplays, 0.4)
    end)
  else
    -- Re-resolve existing tokens by GUIDs/notes
    Wait.time(updateAllDisplays, 0.4)
  end

  -- Build caches as plain tables (no cross-script vectors)
  RR_BuildBoardSquares()
  RR_BuildHomeSnaps()


  RR_World_InitDefaults()
  Wait.time(function() RR_Read_All() end, 0.6)
end

--==== AI status builder (Turn Token) =========================================
--==== AI status builder (Turn Token) =========================================
function BuildStatusForAI()
  -- Base snapshot from Global (has pieces/flags, dice, stacks, etc.)
  local W = RR_Read_All() or {}
  local stacks = RR_Read_Stacks() or { P2={}, P1={} }

  -- Buff zones + flip status
  local z2 = RR_ReadP2BuffZones() or {}
  local z1 = RR_ReadP1BuffZones() or {}
  local zs = RR_Read_BuffZoneStatus() or {
    Blue="None", Pink="None", Purple="None", Green="None", Yellow="None", Orange="None",
  }

  -- Hand counts
  local function _countP1Buff()
    local n = 0
    if Player.White then
      for _,obj in ipairs(Player.White.getHandObjects() or {}) do
        if obj.tag=="Card" then
          for _,t in ipairs(obj.getTags() or {}) do
            if RR_BUFF_TAGS and RR_BUFF_TAGS[t] then n=n+1; break end
          end
        end
      end
    end
    return n
  end

  -- Per-piece flags/shields (derive maps for convenience)
  local flags, shields = {}, {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    local e = (W.pieces or {})[c] or {}
    flags[c]   = (e.flag == true)
    shields[c] = (e.shield == true) or (e.hasShield == true) -- pass-through if present
  end

  -- Token bridge (AI expects status.token)
  local token = {
    square = (W.buff_token and W.buff_token.square) or nil,
    loc    = (W.buff_token and W.buff_token.loc)    or "UNKNOWN",
  }

  -- Meta (nice-to-have hints for the AI; safe defaults)
  local rules = RR_rules_const() or {}
  local meta = {
    round       = W.round or 1,
    phase       = W.game_state or "Waiting_To_Start_Game",
    currentTurn = (W.initiative == 2 and 2 or 1),
    firstPlayer = W.initiative or 1,
    difficulty  = 3,
    initiative  = W.initiative or 1,
    homes       = rules.Homes,
  }

  return {
    meta   = meta,
    dice   = W.dice or {nil,nil,nil},
    token  = token,

    pieces = W.pieces or {},          -- carries loc/square + flag/shield booleans
    flags  = flags,
    shields= shields,

    stacks = stacks,

    buffs  = {
      hand       = { P2 = tonumber(W.p2_buff_hand_count or 0) or 0, P1 = _countP1Buff() },
      zones      = {
        Blue   = z2.Blue   or "None",
        Pink   = z2.Pink   or "None",
        Purple = z2.Purple or "None",
        Green  = z1.Green  or "None",
        Yellow = z1.Yellow or "None",
        Orange = z1.Orange or "None",
      },
      zoneStatus = {
        Blue   = zs.Blue   or "None",
        Pink   = zs.Pink   or "None",
        Purple = zs.Purple or "None",
        Green  = zs.Green  or "None",
        Yellow = zs.Yellow or "None",
        Orange = zs.Orange or "None",
      }
    },

    -- Optional planning hint; keep simple (how many unrevealed slots remain this round)
    budgets = { P2 = 0, P1 = 0 },
  }
end
--=============================================================================


--==== EVENT HOOKS (dice settle → update display) ====--
function onObjectRandomize(obj, _)
  local i = dieIndex(obj.getGUID()); if not i then return end
  waitUntilRest(obj, function() updateOneDisplay(i) end)
end

function onObjectDrop(_, obj)
  local i = dieIndex(obj.getGUID()); if not i then return end
  waitUntilRest(obj, function() updateOneDisplay(i) end)
end

--==== CORE UPDATE LOGIC (read die → apply image token) ====--
local function safeGetValue(die)
  if not die or not die.getValue then return nil end
  local v = die.getValue()
  if type(v) == "number" and v >= 1 and v <= 6 then return v end
end

function updateAllDisplays()
  for i=1,3 do updateOneDisplay(i) end
end

function updateOneDisplay(i)
  local die = getObjectFromGUID(DICE_GUIDS[i]); if not die then return end
  local v = safeGetValue(die); if not v then return end
  local tok = resolveToken(i); if not tok then return end

  local url = FACE_URLS[v]; if not url then return end

  local cfg = tok.getCustomObject() or {}
  if cfg.image ~= url or (cfg.thickness or 0) ~= TOKEN_THICK then
    tok.setLock(false)
    tok.setCustomObject({ image = url, thickness = TOKEN_THICK })
    tok.reload()
    tok.setLock(true)
  end
  tok.setName("D"..i.." = "..v)
end



--------------------------------------------------------------
-- 2) DICE TOKENS — SPAWN/RESOLVE + SUPPORT UTILITIES        --
--------------------------------------------------------------

-- Token lookup tag (GM notes)
local TOKEN_NOTE_PREFIX = "DiceImgToken_"

-- Roll all game dice, wait for settle, update display + RR.World.dice.
-- Optional usage: RR_RollGameDice({ after=0.25, onDone=function(values) ... end })
function RR_RollGameDice(opts)
  opts = opts or {}
  local extraSettle = tonumber(opts.after or 0.25)   -- small buffer after "rest"
  local onDone      = opts.onDone

  local pending, rolledAny = 0, false

  for i, guid in ipairs(DICE_GUIDS) do
    local die = getObjectFromGUID(guid)
    if die then
      rolledAny = true
      pending = pending + 1
      local ii = i

      -- gentle randomize + micro-nudge (soft roll)
      pcall(function()
        -- prefer randomize() to avoid the built-in hard impulse
        if die.randomize then die.randomize() else die.roll() end
      end)

      local p = die.getPosition()
      -- small lift (not a throw)
      die.setPosition({p.x, p.y + 0.3, p.z})

      -- clear any existing motion, then apply a tiny wobble
      pcall(function() die.setVelocity({0,0,0}) end)
      pcall(function() die.setAngularVelocity({0,0,0}) end)

      -- tiny torque/force so physics resolves naturally
      die.addTorque({0, math.random(-150,150), 0})
      die.addForce({math.random(-0.75,0.75), 3, math.random(-0.75,0.75)})


      -- when this die rests, wait a hair, then update its token
      waitUntilRest(die, function()
        Wait.time(function()
          updateOneDisplay(ii)
          pending = pending - 1
          if pending == 0 then
            -- all dice done: cache values in RR.World
            local d1 = getObjectFromGUID(DICE_GUIDS[1])
            local d2 = getObjectFromGUID(DICE_GUIDS[2])
            local d3 = getObjectFromGUID(DICE_GUIDS[3])
            local v1 = (d1 and d1.getValue and d1.getValue()) or nil
            local v2 = (d2 and d2.getValue and d2.getValue()) or nil
            local v3 = (d3 and d3.getValue and d3.getValue()) or nil
            RR.World.dice = { v1, v2, v3 }
            if onDone then pcall(onDone, {v1, v2, v3}) end
          end
        end, extraSettle)
      end)
    end
  end

  if not rolledAny and onDone then
    -- no dice found; still return whatever we can read
    local d1 = getObjectFromGUID(DICE_GUIDS[1])
    local d2 = getObjectFromGUID(DICE_GUIDS[2])
    local d3 = getObjectFromGUID(DICE_GUIDS[3])
    local v1 = (d1 and d1.getValue and d1.getValue()) or nil
    local v2 = (d2 and d2.getValue and d2.getValue()) or nil
    local v3 = (d3 and d3.getValue and d3.getValue()) or nil
    RR.World.dice = { v1, v2, v3 }
    pcall(onDone, {v1, v2, v3})
  end
end

-- Convenience: roll dice, then read everything once they settle.
function RR_RollThenReadAll()
  RR_RollGameDice({
    after = 0.25,
    onDone = function(_) RR_Read_All() end
  })
end


-- Spawn 3 display tokens once, then callback
function spawnTokensOnce(cb)
  local pos = averageDicePosition() or {0, ROW_Y_OFFSET, 0}
  local baseX, baseY, baseZ = pos[1], pos[2], pos[3] + ROW_Z_OFFSET
  local xs = { baseX - ROW_SPACING, baseX, baseX + ROW_SPACING }

  local remaining = 3
  for i=1,3 do
    spawnObject({
      type     = "Custom_Token",
      position = { xs[i], baseY, baseZ },
      rotation = { 0, 0, 0 },
      scale    = { TOKEN_DIAMETER, 1.0, TOKEN_DIAMETER },
      callback_function = function(o)
        if o then
          STATE.tokenGuids[i] = o.getGUID()
          o.setGMNotes(TOKEN_NOTE_PREFIX..i)
          o.setName("D"..i)
          o.setLock(true)
          o.setCustomObject({ image = FACE_URLS[1], thickness = TOKEN_THICK })
          o.reload()
        end
        remaining = remaining - 1
        if remaining == 0 and cb then cb() end
      end
    })
  end
end

-- Resolve token for die index (GUID cache → GM note fallback)
function resolveToken(i)
  local g = STATE.tokenGuids and STATE.tokenGuids[i] or nil
  if g then
    local o = getObjectFromGUID(g)
    if o then return o end
  end
  local note = TOKEN_NOTE_PREFIX..i
  for _,o in ipairs(getAllObjects()) do
    if o.tag == "Custom_Token" and o.getGMNotes() == note then
      STATE.tokenGuids[i] = o.getGUID()
      return o
    end
  end
  return nil
end

-- Wait until die is resting (or timeout) then run callback
function waitUntilRest(die, fn)
  local tries = 120
  local function step()
    if not die or die.resting or tries <= 0 then fn()
    else tries = tries - 1; Wait.time(step, 0.1) end
  end
  step()
end

-- Average the dice positions (center the token row there)
function averageDicePosition()
  local sx, sy, sz, n = 0, 0, 0, 0
  for _,g in ipairs(DICE_GUIDS) do
    local d = getObjectFromGUID(g)
    if d then
      local p = d.getPosition()
      sx, sy, sz = sx + p.x, sy + p.y, sz + p.z
      n = n + 1
    end
  end
  if n == 0 then return nil end
  return { sx/n, (sy/n) + ROW_Y_OFFSET, sz/n }
end



----------------------------------------------------------------
-- 3) BattlePlan CORE — CONSTANTS, BOARD/HOME BUILDERS, CLASSIFY
----------------------------------------------------------------

RR = {}

-- Tabletop object references
RR.BOARD      = "c12b07"  -- Chessboard GUID
RR.TOKEN      = "374070"  -- Buff token GUID
RR.PIECES     = {
  Purple="bd11dd", Pink="0cbb71", Blue="f42b52",
  Green="8b6689", Yellow="3f7ec0", Orange="c98136"
}

-- Board coordinates
RR.BOARD_FILES = {"A","B","C","D","E","F","G","H"}
RR.BOARD_RANKS = {"1","2","3","4","5","6","7","8"}

-- =========================
-- RR — Hard-mapped GUIDs
-- =========================

-- Player 2 (Computer) action stacks (slot 1..6)
RR_STACKS_P2 = {
  Blue   = { "0539ff", "9c93c2", "ef9edc", "0d6c9c", "0b488f", "ebd75c" },
  Pink   = { "03205e", "3b6c40", "2c022c", "c3fa45", "6f46f3", "52b966" },
  Purple = { "df7c00", "2b5d3f", "a7daf5", "74a055", "7ab5a9", "d3e641" },
}

-- Player 1 (Human / White) action stacks (slot 1..6)
RR_STACKS_P1 = {
  Green  = { "10255a", "8f7eec", "645383", "6759e0", "c3b4a7", "7b035e" },
  Yellow = { "ec284c", "79d4f1", "4151d4", "bec202", "3d36a7", "16f803" },
  Orange = { "84ce3c", "f3d70d", "1f45a7", "2466d6", "d54b37", "7528c9" },
}


-- Snap tag names for homes
RR.HOME_TAGS   = {
  Token="Token Home", Green="Green", Yellow="Yellow",
  Orange="Orange", Purple="Purple", Blue="Blue", Pink="Pink"
}

-- Live caches
Board = { squares = {}, step=1.0, version=0 }
Homes = {}

-- Small local helpers (kept local)
local function vdist(a,b) local dx,dy,dz=a.x-b.x,a.y-b.y,a.z-b.z; return math.sqrt(dx*dx+dy*dy+dz*dz) end
local function dist2_xz(a,b) local dx,dz=a.x-b.x,a.z-b.z; return dx*dx+dz*dz end
local function sq(ix,iy) return RR.BOARD_FILES[ix]..RR.BOARD_RANKS[iy] end
local function _norm(s) return string.lower((s or ""):gsub("%s+","")) end

-- helper: copy a TTS Vector into a plain Lua table
local function V3(v) return { x = v.x, y = v.y, z = v.z } end

function RR_BuildBoardSquares()
  Board.squares = {}

  local board = getObjectFromGUID(RR.BOARD)
  if not board then print("[RR] Board not found"); return false end

  local snaps = board.getSnapPoints() or {}
  local xs, zs = {}, {}

  for _, sp in ipairs(snaps) do
    xs[#xs+1] = sp.position.x
    zs[#zs+1] = sp.position.z
  end

  -- dedupe with tolerance so we get 8 unique lines per axis
  local function uniqSorted(t, eps)
    table.sort(t)
    local out = {}
    for _,v in ipairs(t) do
      if #out == 0 or math.abs(v - out[#out]) > (eps or 1e-3) then
        out[#out+1] = v
      end
    end
    return out
  end

  xs = uniqSorted(xs, 1e-3)
  zs = uniqSorted(zs, 1e-3)

  if #xs < 8 or #zs < 8 then
    print(string.format("[RR] WARNING: unique snap lines: x=%d z=%d (expected 8)", #xs, #zs))
  end

  for ix = 1, math.min(8, #xs) do
    for iy = 1, math.min(8, #zs) do
      local x, z = xs[ix], zs[iy]
      local wp = board.positionToWorld({ x = x, y = 0, z = z })
      Board.squares[RR.BOARD_FILES[ix]..RR.BOARD_RANKS[iy]] = { x=wp.x, y=wp.y, z=wp.z }
    end
  end

  -- compute step as the smallest positive gap between unique Xs
  local minGap = 9999
  for i = 2, #xs do
    local gap = math.abs(xs[i] - xs[i-1])
    if gap > 1e-6 and gap < minGap then minGap = gap end
  end
  Board.step = (minGap < 9999) and minGap or 2.0  -- safe fallback ~classic square size

Board.version = Board.version + 1
broadcastToAll(
  "Click PLAY AI to verse the computer.\nPreset difficulty 3.",
  {0,0.5,1}  -- blue
)

Board.version = Board.version + 1
broadcastToAll(
  "PVP Tips:\n-Plan Phase: Click action cards to change them\n-End of Plan Phase: Right click any action card and mark ready.\n-Battle Phase: Click action cards to reveal. Right click pieces to toggle shields and flags.\n-End of Battle Phase: Click End round token to reset and respawn.",
  {1,0.55,0}  -- orange
)


  return true
end



function RR_BuildHomeSnaps()
  Homes = {}
  local function _norm(s) return string.lower((s or ""):gsub("%s+","")) end

  for _, obj in ipairs(getAllObjects()) do
    if obj.getSnapPoints then
      for _, sp in ipairs(obj.getSnapPoints() or {}) do
        local tags = sp.tags or {}
        for _, t in ipairs(tags) do
          for col, want in pairs(RR.HOME_TAGS) do
            if _norm(t) == _norm(want) then
              Homes[col] = V3(obj.positionToWorld(sp.position)) -- store as plain table
            end
          end
        end
      end
    end
  end

  for col, _ in pairs(RR.HOME_TAGS) do
    --print(string.format("[RR] Home %-6s : %s", col, Homes[col] and "FOUND" or "MISSING"))
  end
  return Homes
end


-- Export constants + live caches for token scripts
function RR_const()
    return { RR=RR, Board=Board, Homes=Homes }
end



--------------------------------------------------------------
-- 4) MOVEMENT — BOARD GEOMETRY UTILITIES & MOVERS           --
--------------------------------------------------------------

-- Convert "E4" into world position based on board position/rotation
local function RR_SquareToWorld(square)
  if type(square) ~= "string" then return nil end
  local wp = (Board.squares or {})[square]
  if wp then
    return { x = wp.x, y = wp.y + 2.0, z = wp.z }
  end

  -- Fallback: old math if snaps not ready
  local file = string.byte(string.sub(square,1,1)) - string.byte("A") + 1
  local rank = tonumber(string.sub(square,2))
  if not file or not rank or file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end

  local board = getObjectFromGUID(RR.BOARD); if not board then return nil end
  local boardPos = board.getPosition()
  local boardRot = board.getRotation()
  local step = (Board.step and Board.step > 0) and Board.step or 2.0  -- use your measured step
  local half = 8 / 2
  local offsetX = (file - (half + 0.5)) * step
  local offsetZ = (rank - (half + 0.5)) * step
  local rad = math.rad(boardRot.y or 0)
  local worldX = boardPos.x + offsetX * math.cos(rad) - offsetZ * math.sin(rad)
  local worldZ = boardPos.z + offsetX * math.sin(rad) + offsetZ * math.cos(rad)
  return { x = worldX, y = boardPos.y + 2.0, z = worldZ }
end

-- Helper: map a piece GUID back to its color
function RR_ColorFromGuid(guid)
  for color, g in pairs(RR.PIECES or {}) do
    if g == guid then return color end
  end
  return nil
end

-- Helper: send a piece home by GUID (uses cached Home snaps)
function RR_SendGuidHome(guid)
  if not guid then return false end
  if not Homes or (next(Homes) == nil) then RR_BuildHomeSnaps() end

  local color = RR_ColorFromGuid(guid)
  if not color then
    print("[Global][Home] No color mapped for guid "..tostring(guid))
    return false
  end

  local pos  = (Homes or {})[color]
  local o    = getObjectFromGUID(guid)
  if not (o and pos) then
    print("[Global][Home] Missing piece or home snap for "..tostring(color))
    return false
  end

  -- tidy + move
  pcall(function()
    o.setLock(false)
    o.setVelocity({0,0,0}); o.setAngularVelocity({0,0,0})
    o.setRotationSmooth({0,180,0}, false, true)
    o.setPositionSmooth({ x=pos.x, y=pos.y+1.5, z=pos.z }, false, true)
  end)

  return true
end

-- UPDATED: move a piece to a board square, OR to HOME when square=="HOME"
function RR_MovePieceToSquare(params)
  if type(params) ~= "table" then return false end
  local guid   = params.guid   or params[1]
  local square = params.square or params[2]
  if not guid or not square then return false end

  -- Special case: send to Home snap
  if type(square)=="string" and string.upper(square)=="HOME" then
    return RR_SendGuidHome(guid)
  end

  -- Normal board square move
  local o = getObjectFromGUID(guid); if not o then return false end
  local dest = RR_SquareToWorld(square); if not dest then return false end
  pcall(function()
    o.setLock(false)
    o.setVelocity({0,0,0}); o.setAngularVelocity({0,0,0})
    o.setRotationSmooth({0,180,0}, false, true)
    o.setPositionSmooth(dest, false, true)
  end)
  return true
end


-- Move token to a square; if that square is occupied by a piece, trigger its randomizer after move
function RR_MoveTokenToSquareChecked(params)
  local square = params[1]
  local tok = getObjectFromGUID(RR.TOKEN); if not tok then return false end
  local dest = RR_SquareToWorld(square); if not dest then return false end

  -- Check if a piece already occupies target square
  for color,g in pairs(RR.PIECES) do
    local info = RR_ClassifyObject(g)
    if info.type=="BOARD" and info.square==square then
      tok.setPositionSmooth(dest, false, true)
      Wait.time(function()
        local t2 = getObjectFromGUID(RR.TOKEN)
        if t2 then t2.call("randomizePosition") end
      end, 0.55)
      return true
    end
  end

  -- Not occupied: just move the token
  tok.setPositionSmooth(dest, false, true)
  return true
end



----------------------------------------------------------------
-- 5) PAWN/TOKEN CLASSIFY (QUIET VERSION) — OVERRIDES VERBOSE --
----------------------------------------------------------------

-- Quiet, thresholded classification used by game logic
function RR_ClassifyObject(guid)
    local o = getObjectFromGUID(guid)
    if not o then return {type="UNKNOWN"} end
    local pos = o.getPosition()

    -- Home proximity check
    local homeR = math.max(2.0, (Board.step or 1.0) * 0.6)
    for who,hp in pairs(Homes) do
        local dx,dy,dz = pos.x-hp.x, pos.y-hp.y, pos.z-hp.z
        local dist = math.sqrt(dx*dx+dy*dy+dz*dz)
        if dist <= homeR then
            return {type="HOME", who=who}
        end
    end

    -- Nearest board square (XZ)
    local best,bd
    for sq,wp in pairs(Board.squares) do
        local dx,dz = pos.x-wp.x, pos.z-wp.z
        local d = dx*dx + dz*dz
        if not bd or d < bd then best, bd = sq, d end
    end
    local step = (Board.step and Board.step > 0) and Board.step or 2.0
if best and math.sqrt(bd) < math.max(1.0, step * 0.75) then
        return {type="BOARD", square=best}
    end

    return {type="UNKNOWN"}
end



--------------------------------------------------------------
-- 6) BUFF SYSTEM — GLOBAL (NO LOGS)                         --
--------------------------------------------------------------

-- Seat color used as Player 2
RR.PLAYER2 = RR.PLAYER2 or "Blue"

-- Allowed Buff tags on cards
local RR_BUFF_TAGS = {
  ["Extra Move"]   = true,
  ["Extra Attack"] = true,
  ["Extra Defend"] = true,
  ["Diagonal Move"]= true,
}



-- Find the world position of the snap tagged "Buff Deck", then return the nearest Deck/Card
function RR_FindBuffDeck()
  local snapPos = nil
  for _,obj in ipairs(getAllObjects()) do
    if obj.getSnapPoints then
      for _,sp in ipairs(obj.getSnapPoints() or {}) do
        for _,t in ipairs(sp.tags or {}) do
          if string.lower(t) == "buff deck" then
            snapPos = obj.positionToWorld(sp.position)
            break
          end
        end
      end
    end
  end
  if not snapPos then return nil end

  local nearest, best
  for _,o in ipairs(getAllObjects()) do
    if o.tag == "Deck" or o.tag == "Card" then
      local p = o.getPosition()
      local d = (p.x - snapPos.x)^2 + (p.z - snapPos.z)^2
      if not best or d < best then nearest, best = o, d end
    end
  end
  return nearest
end

-- Deal 1 Buff card to Player 2
function RR_DealBuff()
  local deck = RR_FindBuffDeck()
  if not deck then return end
  if deck.tag == "Deck" or deck.tag == "Card" then
    deck.deal(1, RR.PLAYER2)
  end
end

function RR_DealBuff_P1()
  -- Prefer explicit GUID if present; otherwise auto-find near snap tagged "Buff Deck"
  local deck
  local RRc = RR_const().RR
  if RRc and RRc.BUFF_DECK then deck = getObjectFromGUID(RRc.BUFF_DECK) end
  if not deck then deck = RR_FindBuffDeck() end
  if not deck then
    print("[Global] RR_DealBuff_P1: Buff deck not found (no GUID and auto-find failed).")
    return false
  end

  local hand = Player.White and Player.White.getHandTransform()
  if not hand then
    print("[Global] RR_DealBuff_P1: White hand transform missing.")
    return false
  end

  local p = hand.position
  local dealPos = { x = p.x + 2, y = p.y + 1, z = p.z } -- plain-table math only

  if deck.held_by_color and deck.held_by_color ~= "" then
    print("[Global] RR_DealBuff_P1: Deck is held by "..deck.held_by_color.."; cannot deal.")
    return false
  end

  local card = deck.takeObject({
    position = dealPos,
    rotation = { 0, 180, 0 },
    smooth   = false
  })

  if card then
    card.setName("Buff Card (P1)")
    print("[Global] Dealt 1 Buff to Player 1 (White).")
    return true
  else
    print("[Global] RR_DealBuff_P1: takeObject failed.")
    return false
  end
end



-- List (guid,type) of Buff cards currently in Player 2’s hand
function RR_ListBuffCardsInHand()
  local out = {}
  local p = Player[RR.PLAYER2]; if not p then return out end
  local handObjs = p.getHandObjects() or {}
  for _,obj in ipairs(handObjs) do
    if obj.tag == "Card" then
      local tags = obj.getTags() or {}
      for _,t in ipairs(tags) do
        if RR_BUFF_TAGS[t] then
          out[#out+1] = { guid = obj.getGUID(), type = t }
          break
        end
      end
    end
  end
  return out
end

-- Internal: find world position of snap tagged "<Color> Buff"
local function _RR_FindBuffZonePos(color)
  local want = string.lower((color or "").." buff")
  for _,obj in ipairs(getAllObjects()) do
    if obj.getSnapPoints then
      for _,sp in ipairs(obj.getSnapPoints() or {}) do
        for _,t in ipairs(sp.tags or {}) do
          if string.lower(t) == want then
            return obj.positionToWorld(sp.position)
          end
        end
      end
    end
  end
  return nil
end

-- Place a Buff card of type `buffType` from Player 2’s hand into `<color> Buff` snap (face-down, locked)
function RR_PlaceBuffCardAt(color, buffType)
  local found = RR_ListBuffCardsInHand()
  local cardObj = nil
  for _,c in ipairs(found) do
    if c.type == buffType then
      cardObj = getObjectFromGUID(c.guid)
      break
    end
  end
  if not cardObj then return end

  local targetPos = _RR_FindBuffZonePos(color)
  if not targetPos then return end

  -- Pre-orient face-down, pull from hand, then move to snap
  cardObj.setLock(false)
  cardObj.setRotation({0,180,0})

  local guid = cardObj.getGUID()
  cardObj.setPosition({targetPos.x, targetPos.y + 3, targetPos.z})

  Wait.time(function()
    local c = getObjectFromGUID(guid); if not c then return end
    c.setPositionSmooth({targetPos.x, targetPos.y + 1.5, targetPos.z}, false, true)
    c.setRotationSmooth({0,180,0}, false, true)

    -- After movement settles, ensure face-down and lock
    Wait.condition(function()
      local cc = getObjectFromGUID(guid); if not cc then return end
      if not cc.is_face_down then cc.flip() end
      cc.setLock(true)
    end, function()
      local cc = getObjectFromGUID(guid)
      if not cc then return false end
      if cc.held_by_color and cc.held_by_color ~= "" then return false end
      return not cc.isSmoothMoving()
    end)
  end, 0.3)
end

-- Flip (reveal/hide) the card in `<color> Buff` zone (nearest Card to that snap)
function RR_FlipBuffAt(color)
  local targetPos = _RR_FindBuffZonePos(color); if not targetPos then return end
  local nearest, best
  for _,o in ipairs(getAllObjects()) do
    if o.tag == "Card" then
      local p = o.getPosition()
      local d = (p.x - targetPos.x)^2 + (p.z - targetPos.z)^2
      if not best or d < best then nearest, best = o, d end
    end
  end
  if not nearest then return end
  nearest.setLock(false)
  nearest.flip()
end

-- Convenience: place the first Buff found in hand into `<color> Buff` zone
function RR_PlaceFirstBuff(color)
  local found = RR_ListBuffCardsInHand()
  if #found == 0 then return end
  local first = found[1]
  RR_PlaceBuffCardAt(color, first.type)
end

-- Global: Shuffle the Buff Deck found by RR_FindBuffDeck()
function RR_ShuffleBuffDeck()
  local deck = RR_FindBuffDeck()
  if not deck then
    print("[RR] Buff deck not found near snap tagged 'Buff Deck'.")
    return false
  end

  -- If it's a single card, there's nothing to shuffle (but not an error)
  if deck.tag == "Card" then
    print("[RR] Only one Buff card present; nothing to shuffle.")
    return true
  end

  if deck.tag ~= "Deck" then
    print("[RR] RR_ShuffleBuffDeck: Found object is not a Deck/Card.")
    return false
  end

  -- Don't try to shuffle if someone is holding it
  local held = deck.held_by_color
  if held and held ~= "" then
    print("[RR] Buff deck is currently held by "..tostring(held).."; cannot shuffle.")
    return false
  end

  -- Briefly unlock, shuffle, then relock
  deck.setLock(false)
  pcall(function() deck.shuffle() end)
  deck.setLock(true)

  print("[RR] Buff deck shuffled.")
  return true
end



----------------------------------------------------------------
-- 7) ACTION CARDS (PLAYER 2) — GLOBAL HELPERS & MASS UPDATES
----------------------------------------------------------------

-- Tag used to identify your action cards in TTS
RR.ACTION_P2_TAG = RR.ACTION_P2_TAG or "Player 2"

-- Local helpers for card tagging/notes
local function _RR_hasTag(obj, wanted)
  wanted = string.lower(wanted)
  for _,t in ipairs(obj.getTags() or {}) do
    if string.lower(t) == wanted then return true end
  end
  return false
end

local function _RR_noteGet(obj, key)
  local s = obj.getGMNotes() or ""
  local pat = "%["..key:gsub("(%W)","%%%1")..":([^%]]+)%]"
  return s:match(pat)
end

local function _RR_noteSet(obj, key, value)
  local s = obj.getGMNotes() or ""
  local pat = "%["..key:gsub("(%W)","%%%1")..":[^%]]+%]"
  if s:find(pat) then s = s:gsub(pat, "["..key..":"..value.."]", 1)
  else s = (s~="" and s.."\n" or "").."["..key..":"..value.."]" end
  obj.setGMNotes(s)
end

local function _RR_isP2ActionCard(o)
  return o and o.tag == "Card" and _RR_hasTag(o, RR.ACTION_P2_TAG)
end

local function _RR_allP2Cards()
  local out = {}
  for _,o in ipairs(getAllObjects()) do
    if _RR_isP2ActionCard(o) then out[#out+1] = o end
  end
  return out
end

local function _RR_refreshCard(o)
  if not o or o.tag ~= "Card" then return end

  local funcs = { "enforceVisibility", "applyFaceForState", "addMenu" }
  for _,fn in ipairs(funcs) do
    if o.getVar(fn) ~= nil then   -- check if card script actually has it
      pcall(function() o.call(fn) end)
    else
      -- Optional: log once
      -- print("[Global] Skipped "..fn.." on "..o.getGUID().." (not present).")
    end
  end
end



-- Replace your existing RR_P2_SetReadyAll with this one:
function RR_P2_SetReadyAll(on)
  local flag = on and "1" or "0"
  local want = string.lower(RR.ACTION_P2_TAG or "Player 2")
  for _,o in ipairs(getAllObjects()) do
    if o.tag == "Card" then
      local has=false
      for _,t in ipairs(o.getTags() or {}) do
        if string.lower(t)==want then has=true break end
      end
      if has then
        local s = o.getGMNotes() or ""
        local pat = "%[ReadyGlobal:[^%]]+%]"
        if s:find(pat) then s = s:gsub(pat, "[ReadyGlobal:"..flag.."]", 1)
        else s = (s~="" and s.."\n" or "").."[ReadyGlobal:"..flag.."]" end
        o.setGMNotes(s)
        if o.getVar("applyFaceForState") ~= nil then pcall(function() o.call("applyFaceForState") end) end
        if o.getVar("addMenu")           ~= nil then pcall(function() o.call("addMenu")           end) end
      end
    end
  end
end


-- 1) Set ALL Player 2 cards to one of: "MOVE" | "ATTACK" | "DEFEND" | "BLANK"
function RR_P2_SetAll(faceKind)
  local cards = _RR_allP2Cards()
  for _,o in ipairs(cards) do
    _RR_noteSet(o, "FaceKind", faceKind)
    _RR_refreshCard(o)
  end
end




-- 3) REVEAL all Player 2 cards (on/off)
function RR_P2_RevealAll(on)
  local flag = on and "1" or "0"
  for _,o in ipairs(_RR_allP2Cards()) do
    _RR_noteSet(o, "Revealed", flag)
    _RR_refreshCard(o)
  end
end

-- 4) Reset all Player 2 cards (Ready off, Reveal off, set to ACTION)
function RR_P2_ResetAll()
  RR_P2_SetReadyAll(false)
  for _,o in ipairs(_RR_allP2Cards()) do
    _RR_noteSet(o, "Revealed", "0")
    _RR_noteSet(o, "FaceKind", "ACTION")
    _RR_refreshCard(o)
  end
end



----------------------------------------------------------------
-- 8) ACTION/BUFF READ HELPERS — PRIVACY-AWARE READERS        --
----------------------------------------------------------------

-- Tags you put on action cards (re-affirm)
RR.ACTION_P2_TAG = RR.ACTION_P2_TAG or "Player 2"
RR.ACTION_P1_TAG = RR.ACTION_P1_TAG or "Player 1"

-- Local helpers scoped to this section
local function _RR_hasTag(obj, wanted)
  wanted = string.lower(wanted or "")
  for _,t in ipairs(obj.getTags() or {}) do
    if string.lower(t) == wanted then return true end
  end
  return false
end

local function _RR_noteGet(obj, key)
  local s = obj.getGMNotes() or ""
  local pat = "%["..key:gsub("(%W)","%%%1")..":([^%]]+)%]"
  return s:match(pat)
end

local function _RR_isP2ActionCard(o) return o and o.tag=="Card" and _RR_hasTag(o, RR.ACTION_P2_TAG) end
local function _RR_isP1ActionCard(o) return o and o.tag=="Card" and _RR_hasTag(o, RR.ACTION_P1_TAG) end

local function _RR_faceToStatus(kind)
  kind = string.upper(kind or "")
  if     kind=="MOVE"   then return "move"
  elseif kind=="ATTACK" then return "attack"
  elseif kind=="DEFEND" then return "defend"
  else return "blank" -- ACTION or BLANK -> blank
  end
end

-- Recognized Buff tags (local scope)
local _RR_BUFF_NAMES = {
  ["Extra Move"]=true, ["Extra Attack"]=true, ["Extra Defend"]=true, ["Diagonal Move"]=true,
}

local function _RR_cardTypeFromTags(card)
  for _,t in ipairs(card.getTags() or {}) do
    if _RR_BUFF_NAMES[t] then return t end
  end
  return "unknown"
end

-- Nearest Card to a world position (XZ)
local function _RR_nearestCardTo(pos)
  local nearest, best
  for _,o in ipairs(getAllObjects()) do
    if o.tag=="Card" then
      local p=o.getPosition()
      local d=(p.x-pos.x)^2 + (p.z-pos.z)^2
      if not best or d<best then nearest,best=o,d end
    end
  end
  return nearest
end

-- READ: Player 2 action cards (always readable)
function RR_P2_ReadStatus()
  local out = {}
  for _,o in ipairs(getAllObjects()) do
    if _RR_isP2ActionCard(o) then
      local kind = _RR_noteGet(o, "FaceKind") or "ACTION"
      out[#out+1] = { guid=o.getGUID(), status=_RR_faceToStatus(kind) }
    end
  end
  return out
end

-- READ: Player 1 action cards (privacy rules)
-- If Revealed=1 -> real face; else ACTION/BLANK => blank; else unrevealed
function RR_P1_ReadStatus()
  local out = {}
  for _,o in ipairs(getAllObjects()) do
    if _RR_isP1ActionCard(o) then
      local revealed = (_RR_noteGet(o,"Revealed") == "1")
      local kind     = _RR_noteGet(o,"FaceKind") or "ACTION"
      local status
      if revealed then
        status = _RR_faceToStatus(kind)
      else
        status = (kind=="ACTION" or kind=="BLANK") and "blank" or "unrevealed"
      end
      out[#out+1] = { guid=o.getGUID(), status=status }
    end
  end
  return out
end

-- READ: Buff zones (Blue/Pink/Purple = always; Green/Yellow/Orange = only if face-up)
function RR_ReadBuffZone(color)
  local pos = (_RR_FindBuffZonePos and _RR_FindBuffZonePos(color)) or nil
  if not pos then return "zone_missing" end

  local card = _RR_nearestCardTo(pos)
  if not card then return "no_card" end

  local isP2 = (color=="Blue" or color=="Pink" or color=="Purple")
  if isP2 then
    return _RR_cardTypeFromTags(card)
  else
    if card.is_face_down then return "unrevealed" end
    return _RR_cardTypeFromTags(card)
  end
end

-- Put this in Global (anywhere after your _RR_FindBuffZonePos helper):

function RR_Read_BuffZoneStatus()
  local function one(color)
    -- Find the zone’s world pos
    local want = string.lower((color or "").." buff")
    local pos = nil
    for _,obj in ipairs(getAllObjects()) do
      if obj.getSnapPoints then
        for _,sp in ipairs(obj.getSnapPoints() or {}) do
          for _,t in ipairs(sp.tags or {}) do
            if string.lower(t) == want then
              pos = obj.positionToWorld(sp.position); break
            end
          end
        end
      end
    end
    if not pos then return "None" end

    -- Find nearest card to that pos
    local nearest, best
    for _,o in ipairs(getAllObjects()) do
      if o.tag=="Card" then
        local p=o.getPosition()
        local d=(p.x-pos.x)^2 + (p.z-pos.z)^2
        if not best or d<best then nearest,best=o,d end
      end
    end
    if not nearest then return "None" end
    return (nearest.is_face_down and "Unrevealed") or "Revealed"
  end

  return {
    Blue   = one("Blue"),
    Pink   = one("Pink"),
    Purple = one("Purple"),
    Green  = one("Green"),
    Yellow = one("Yellow"),
    Orange = one("Orange"),
  }
end


function RR_ReadP1BuffZones()
  return {
    Green  = RR_ReadBuffZone("Green"),
    Yellow = RR_ReadBuffZone("Yellow"),
    Orange = RR_ReadBuffZone("Orange"),
  }
end

function RR_ReadP2BuffZones()
  return {
    Blue   = RR_ReadBuffZone("Blue"),
    Pink   = RR_ReadBuffZone("Pink"),
    Purple = RR_ReadBuffZone("Purple"),
  }
end



----------------------------------------------------------------
-- 9) WORLD SNAPSHOT — CACHE + ONE-CALL SCAN                  --
----------------------------------------------------------------

-- Persistent snapshot
RR.World = RR.World or {
  pieces = {},                   -- [color] = {loc="HOME/BOARD/UNKNOWN", square=?, flag=false}
  buff_token = {},               -- {loc=..., square=?, who=?}
  p2_buff_hand = {},             -- { {guid,type}, ... }
  p2_buff_zones = {},            -- {Blue=..., Pink=..., Purple=...}
  p1_buff_zones = {},            -- {Green=..., Yellow=..., Orange=...}
  p2_buff_hand_count = 0,
  actions = { P2={}, P1={} },    -- lists of {guid,status}
  initiative = 1,                -- 1 = P1 first, 2 = P2 first
  dice = { nil, nil, nil },      -- 3 values
  game_state = "Waiting_To_Start_Game",
  version = 0
}

-- Helpers for dice/flag detection (local)
local function _RR_safeDieValue(guid)
  local d = getObjectFromGUID(guid)
  if d and d.getValue then
    local ok, v = pcall(function() return d.getValue() end)
    if ok and type(v)=="number" and v>=1 and v<=6 then return v end
  end
  return nil
end

-- Detect a nearby token tagged "Flag" (~1.25u radius)
local function _RR_hasNearbyFlag(pos)
  for _,o in ipairs(getAllObjects()) do
    local tags = o.getTags() or {}
    for _,t in ipairs(tags) do
      if string.lower(t)=="flag" then
        local p = o.getPosition()
        local dx,dy,dz = p.x-pos.x, p.y-pos.y, p.z-pos.z
        if (dx*dx + dy*dy + dz*dz) <= 1.56 then return true end
      end
    end
  end
  return false
end

-- Defaults (safe to call anytime)
function RR_World_InitDefaults()
  RR.World.pieces = {}
  for color,_ in pairs(RR.PIECES or {}) do
    RR.World.pieces[color] = { loc="UNKNOWN", flag=false }
  end

  RR.World.buff_token = { loc="UNKNOWN" }
  RR.World.p2_buff_hand = {}
  RR.World.p2_buff_zones = { Blue="None", Pink="None", Purple="None" }
  RR.World.p1_buff_zones = { Green="None", Yellow="None", Orange="None" }
  RR.World.p2_buff_hand_count = 0
  RR.World.actions = { P2={}, P1={} }
  RR.World.initiative = 1
  RR.World.dice = {
    _RR_safeDieValue((DICE_GUIDS or {})[1]),
    _RR_safeDieValue((DICE_GUIDS or {})[2]),
    _RR_safeDieValue((DICE_GUIDS or {})[3]),
  }
  RR.World.game_state = "Waiting_To_Start_Game"
  RR.World.version = (RR.World.version or 0) + 1
end

-- One-call scan: fills RR.World and returns it
function RR_Read_All()
  local W = RR.World
  if not W then RR_World_InitDefaults(); W = RR.World end

  -- 1) Pieces + flag
  for color,g in pairs(RR.PIECES or {}) do
    local info = RR_ClassifyObject(g) or {type="UNKNOWN"}
    local entry = { loc=info.type, flag=false }
    if info.square then entry.square = info.square end
    local o = getObjectFromGUID(g); if o then entry.flag = _RR_hasNearbyFlag(o.getPosition()) end
    W.pieces[color] = entry
  end

  -- 2) Buff token location
  if RR.TOKEN then
    local ti = RR_ClassifyObject(RR.TOKEN) or {type="UNKNOWN"}
    W.buff_token = { loc=ti.type, square=ti.square, who=ti.who }
  end

  -- 3 & 6) P2 buff hand + count
  W.p2_buff_hand = RR_ListBuffCardsInHand() or {}
  W.p2_buff_hand_count = #W.p2_buff_hand

  -- 4 & 5) Buff zones
  W.p2_buff_zones = RR_ReadP2BuffZones() or {}
  W.p1_buff_zones = RR_ReadP1BuffZones() or {}

  -- 7) Action cards (privacy handled inside the readers)
  W.actions.P2 = RR_P2_ReadStatus() or {}
  W.actions.P1 = RR_P1_ReadStatus() or {}

  -- 8) Initiative (retain if already set)
  W.initiative = W.initiative or 1

  -- 9) Dice (refresh on each read)
  W.dice = {
    _RR_safeDieValue((DICE_GUIDS or {})[1]),
    _RR_safeDieValue((DICE_GUIDS or {})[2]),
    _RR_safeDieValue((DICE_GUIDS or {})[3]),
  }

  -- 10) Game state (leave as-is if already present)
  W.game_state = W.game_state or "Waiting_To_Start_Game"

  W.version = (W.version or 0) + 1
  return W
end

-- Tiny world accessors
function RR_SetInitiative(who) RR.World.initiative = (who==2) and 2 or 1 end
function RR_SetGameState(s) RR.World.game_state = tostring(s or "Waiting_To_Start_Game") end
function RR_GetWorld() return RR.World end


-- Return constants the token needs, as JSON
function RR_const_JSON()
  return JSON.encode({
    RR = { TOKEN = RR.TOKEN, PIECES = RR.PIECES, PLAYER2 = RR.PLAYER2 }
  })
end

-- Return the full world snapshot, as JSON
function RR_Read_All_JSON()
  return JSON.encode(RR_Read_All())
end

-- Return P2 stack GUIDs, as JSON
function RR_GetStacksP2_JSON()
  return JSON.encode(RR_STACKS_P2)
end


function RR_SetInitiative_JSON(who)
  if not RR.World then RR_World_InitDefaults() end
  RR_SetInitiative(who)
  return JSON.encode(RR.World or {})
end


-- ============================================================================
-- Send one piece home by color (using pre-cached Homes snap points)
-- ============================================================================
function RR_SendPieceHome(color)
  local guid = (RR.PIECES or {})[color]
  local pos  = (Homes or {})[color]
  local o    = guid and getObjectFromGUID(guid) or nil
  if o and pos then
    print("[Global][Home] Sending "..color.." → home snap")
    o.setLock(false)
    o.setPositionSmooth({ x=pos.x, y=pos.y+1.5, z=pos.z }, false, true)
    return true
  else
    print("[Global][Home] FAIL: missing guid or snap for "..tostring(color))
    return false
  end
end

-- === HARD RESET: send pieces/token home, rebuild Buff Deck, reset both players' cards ===
function Reset_Board()
  print("[Global] Reset_Board() starting…")

  -- Make sure Home snap cache exists
  RR_BuildHomeSnaps()

  ----------------------------------------------------------------
  -- 1) Send all pieces to their Home snaps
  ----------------------------------------------------------------
  local orderPieces = { "Blue","Pink","Purple","Green","Yellow","Orange" }
  for _,color in ipairs(orderPieces) do
    local guid = (RR.PIECES or {})[color]
    local pos  = (Homes or {})[color]
    local o    = guid and getObjectFromGUID(guid) or nil
    if o and pos then
      o.setLock(false)
      o.setPositionSmooth({ x=pos.x, y=pos.y+1.5, z=pos.z }, false, true)
    end
  end

  ----------------------------------------------------------------
  -- 2) Send Buff TOKEN to its Home snap
  ----------------------------------------------------------------
  do
    local tokHome = (Homes or {}).Token
    local tok     = RR.TOKEN and getObjectFromGUID(RR.TOKEN) or nil
    if tok and tokHome then
      tok.setLock(false)
      tok.setPositionSmooth({ x=tokHome.x, y=tokHome.y+1.5, z=tokHome.z }, false, true)
    end
  end

  ----------------------------------------------------------------
  -- 3) Collect ALL Buff cards back to the Buff Deck snap
  ----------------------------------------------------------------
  local function _findBuffDeckSnapPos()
    for _,obj in ipairs(getAllObjects()) do
      if obj.getSnapPoints then
        for _,sp in ipairs(obj.getSnapPoints() or {}) do
          for _,t in ipairs(sp.tags or {}) do
            if string.lower(t) == "buff deck" then
              return obj.positionToWorld(sp.position)
            end
          end
        end
      end
    end
    return nil
  end

  -- Bring a single Buff card to deck home (face-down) and stack it.
  -- If a deck already exists at the snap: UNLOCK it, then putObject.
  -- If no deck exists yet: just park the card at the snap (no unlock needed).
  local function _pullBuffCardToDeck(o, deckPos)
    if not o or o.tag ~= "Card" or not deckPos then return end
    o.setLock(false)
    o.setRotation({0,180,0})

    local deck = RR_FindBuffDeck()  -- nearest to the "Buff Deck" snap
    if deck and deck.tag == "Deck" and (not deck.held_by_color or deck.held_by_color=="") then
      deck.setLock(false)                       -- key: unlock existing deck so it accepts cards
      pcall(function() deck.putObject(o) end)   -- merge into the deck
      deck.setName("Buff Deck")
      return
    end

    -- No deck there yet (or it's a single card): just park it at the snap to form one
    o.setPosition({ x=deckPos.x, y=deckPos.y+3.0, z=deckPos.z })
  end

  local deckPos = _findBuffDeckSnapPos()
  if deckPos then
    -- Pre-unlock existing DECK at the snap (if any) so incoming cards merge
    do
      local pre = RR_FindBuffDeck()
      if pre and pre.tag == "Deck" and (not pre.held_by_color or pre.held_by_color=="") then
        pre.setLock(false)
      end
    end

    -- From P2 (computer) hand
    for _,rec in ipairs(RR_ListBuffCardsInHand() or {}) do
      _pullBuffCardToDeck(getObjectFromGUID(rec.guid), deckPos)
    end

    -- From White (P1) hand
    if Player.White then
      for _,obj in ipairs(Player.White.getHandObjects() or {}) do
        if obj.tag == "Card" then
          local tags = obj.getTags() or {}
          for _,t in ipairs(tags) do
            if RR_BUFF_TAGS[t] then _pullBuffCardToDeck(obj, deckPos) break end
          end
        end
      end
    end

    -- From the table (any loose Buff-tagged cards)
    for _,obj in ipairs(getAllObjects()) do
      if obj.tag == "Card" then
        local isBuff = false
        for _,t in ipairs(obj.getTags() or {}) do
          if RR_BUFF_TAGS[t] then isBuff = true; break end
        end
        if isBuff then _pullBuffCardToDeck(obj, deckPos) end
      end
    end

    -- Finalize: after cards settle, shuffle & lock if a DECK exists
    Wait.time(function()
      local deck = RR_FindBuffDeck()
      if deck then
        if deck.tag == "Deck" then
          deck.setLock(false)
          pcall(function() deck.shuffle() end)
          deck.setLock(true)
          deck.setName("Buff Deck")
        else
          -- Only a single card at the snap
          deck.setLock(true)
        end
      end
    end, 1.2)
  else
    print("[Global] Reset_Board: No snap tagged 'Buff Deck' found; skipped card collection.")
  end

  ----------------------------------------------------------------
  -- 4) Reset Player 2 (Computer) action cards (uses existing helper)
  ----------------------------------------------------------------
  pcall(function() RR_P2_ResetAll() end)

  ----------------------------------------------------------------
  -- 5) Reset Player 1 action cards (scan by tag "Player 1")
  ----------------------------------------------------------------
  do
    local P1_TAG = RR.ACTION_P1_TAG or "Player 1"

    local function _hasTag(o, wanted)
      wanted = string.lower(wanted or "")
      for _,t in ipairs(o.getTags() or {}) do
        if string.lower(t) == wanted then return true end
      end
      return false
    end

    local function _setNote(o, key, val, s)
      local pat = "%["..key:gsub("(%W)","%%%1")..":[^%]]+%]"
      if s:find(pat) then
        return s:gsub(pat, "["..key..":"..val.."]", 1)
      else
        return (s~="" and s.."\n" or "").."["..key..":"..val.."]"
      end
    end

    for _,o in ipairs(getAllObjects()) do
      if o.tag == "Card" and _hasTag(o, P1_TAG) then
        local s = o.getGMNotes() or ""
        s = _setNote(o, "Revealed",   "0", s)
        s = _setNote(o, "FaceKind",   "ACTION", s)
        s = _setNote(o, "ReadyGlobal","0", s)
        o.setGMNotes(s)
        if o.getVar("applyFaceForState") ~= nil then pcall(function() o.call("applyFaceForState") end) end
        if o.getVar("addMenu")           ~= nil then pcall(function() o.call("addMenu")           end) end
      end
    end
  end

  ----------------------------------------------------------------
  -- 6) Reset world snapshot + status back to Waiting
  ----------------------------------------------------------------
  RR_World_InitDefaults()
  RR_SetGameState("Waiting_To_Start_Game")
  RR_SetInitiative(1)
  RR_Read_All()
  pcall(updateAllDisplays)

  print("[Global] Reset_Board() done.")
  return true
end


--=============================================================================
--== PLAYER 1 READY ALL =======================================================
--=============================================================================
function RR_P1_SetReadyAll(flag)
  --print("[Global] RR_P1_SetReadyAll("..tostring(flag)..")")
  local function _hasTag(o, wanted)
    wanted = string.lower(wanted or "")
    for _,t in ipairs(o.getTags() or {}) do
      if string.lower(t) == wanted then return true end
    end
    return false
  end
  local function _setNoteStr(s, key, val)
    local pat = "%["..key:gsub("(%W)","%%%1")..":[^%]]+%]"
    if s:find(pat) then
      return s:gsub(pat, "["..key..":"..val.."]", 1)
    else
      return (s~="" and s.."\n" or "").."["..key..":"..val.."]"
    end
  end

  local readyVal = (flag == false or flag == "0") and "0" or "1"

  for _,o in ipairs(getAllObjects()) do
    if o.tag=="Card" and _hasTag(o, "Player 1") then
      local s = o.getGMNotes() or ""
      s = _setNoteStr(s, "ReadyGlobal", readyVal)
      -- Always keep [Revealed:0] when setting ready
      s = _setNoteStr(s, "Revealed", "0")
      o.setGMNotes(s)
      if o.getVar("applyFaceForState") ~= nil then pcall(function() o.call("applyFaceForState") end) end
      if o.getVar("addMenu")           ~= nil then pcall(function() o.call("addMenu")           end) end
    end
  end
end



-- Global
-- Rules/layout constants for UI/helpers (renamed to avoid clobbering the primary RR_const)
function RR_rules_const()
  return {
    Homes = {
      P1 = {"A1","B1","C1","D1","E1","F1","G1","H1"},
      P2 = {"A8","B8","C8","D8","E8","F8","G8","H8"},
    },
    DZ   = { P1 = {rank=1}, P2 = {rank=8} },
    Win  = { P1 = {rank=1}, P2 = {rank=8} },
  }
end



--=============================================================================
--== FLAG CONTROL (Global functions callable from Turn Token) =================
--=============================================================================

-- Give a flag to a pawn of this color (spawns a Flag marker and attaches it)
function RR_GiveFlag(color)
  local guid = (RR.PIECES or {})[color]
  local piece = guid and getObjectFromGUID(guid) or nil
  if not piece then return false end

  -- If a Flag already exists nearby, don’t double-spawn
  local pos = piece.getPosition()
  for _,o in ipairs(getAllObjects()) do
    local tags = o.getTags() or {}
    for _,t in ipairs(tags) do
      if string.lower(t)=="flag" then
        local p=o.getPosition()
        local dx,dy,dz = p.x-pos.x, p.y-pos.y, p.z-pos.z
        if (dx*dx+dy*dy+dz*dz) <= 1.56 then return true end
      end
    end
  end

  -- Spawn a simple Flag token just above the pawn
  local spawnPos = { x=pos.x, y=pos.y+2.0, z=pos.z }
  spawnObject({
    type = "Custom_Token",
    position = spawnPos,
    rotation = {0,0,0},
    scale    = {0.5,0.5,0.5},
    callback_function = function(o)
      o.setName(color.." Flag")
      o.addTag("Flag")
      o.setLock(true)
    end
  })
  return true
end

-- Remove any Flag markers near this pawn
function RR_RemoveFlag(color)
  local guid = (RR.PIECES or {})[color]
  local piece = guid and getObjectFromGUID(guid) or nil
  if not piece then return false end

  local pos = piece.getPosition()
  for _,o in ipairs(getAllObjects()) do
    local tags=o.getTags() or {}
    for _,t in ipairs(tags) do
      if string.lower(t)=="flag" then
        local p=o.getPosition()
        local dx,dy,dz = p.x-pos.x, p.y-pos.y, p.z-pos.z
        if (dx*dx+dy*dy+dz*dz) <= 1.56 then
          o.destruct()
        end
      end
    end
  end
  return true
end



----------------------------------------------------------------
-- X) ACTION STACK SNAPSHOT — AI CONTRACT SHAPE (by color/slot)
----------------------------------------------------------------
function RR_Read_Stacks()
  local out = { P2 = {}, P1 = {} }

-- fixed
local function _noteGet(o, key)
  local s = (o and o.getGMNotes and (o.getGMNotes() or "")) or ""
  local pat = "%["..key:gsub("(%W)","%%%1")..":([^%]]+)%]"
  return s:match(pat)
end


  local function pack(side, map)
    for color, guids in pairs(map or {}) do
      local arr = {}
      for i = 1, 6 do
        local g = guids[i]
        local o = g and getObjectFromGUID(g) or nil
        local face = "ACTION"
        local revealed = false
        if o and o.tag == "Card" then
          face = _noteGet(o, "FaceKind") or "ACTION"
          revealed = (_noteGet(o, "Revealed") == "1")
        end
        arr[i] = { face = face, revealed = revealed }
      end
      out[side][color] = arr
    end
  end

  pack("P2", RR_STACKS_P2)
  pack("P1", RR_STACKS_P1)
  return out
end

function RR_Read_Stacks_JSON()
  return JSON.encode(RR_Read_Stacks())
end


-- Place a specific buff by name (exact tag) into <color> Buff zone.
function RR_PlaceBuffByName(arg)
  local color, name
  if type(arg)=="table" then color, name = arg.color, arg.name
  else color, name = nil, arg end
  if not color or not name then return false end
  return pcall(function() RR_PlaceBuffCardAt(color, name) end) and true or false
end

-- Convenience aliases so any caller name will work.
function RR_FlipBuffZone(arg)
  local color = (type(arg)=="table" and arg.color) or arg
  if not color then return false end
  RR_FlipBuffAt(color); return true
end

function RR_RevealBuffZone(arg)
  local color = (type(arg)=="table" and arg.color) or arg
  if not color then return false end
  RR_FlipBuffAt(color); return true
end

-- === Unified End-of-Round Function (callable from any token) ===
function RR_EndRound()
  local tok = getObjectFromGUID("a9c4f3")
  if not tok then
    broadcastToAll("[Global] Turn Token not found; cannot end round.", {1,0,0})
    return
  end
  tok.call("end_round")
end
