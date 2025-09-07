--#region Initialise
--[[============================================================================
Battleplan — AI Token (Region 0: Initialise / Normalise / Router) — AIV2
This region:
  • Defines public namespace, logging, RNG, constants
  • Normalises Turn Token status → world/CTX
  • Provides shared helpers used by all regions
  • Handles dynamic finish squares (AIV2: symmetric sane defaults)
  • Adds deterministic per-turn RNG seeding + tiny transposition cache
  • Routes requests and packages strict Turn-Token shapes
  • Consolidates difficulty knobs (linear d1→d5) for all regions

House rules for this refactor:
  • Debug toggles default OFF (flip locally when you need them).
  • Single canonical buff normaliser (_canonBuff) used everywhere.
  • D1 plays safe-but-sound, D5 plays elite; Profiles are strictly linear.
=============================================================================]]


--=========================== Public namespace =================================
AI     = AI     or {}
RR_AI  = RR_AI  or AI
_AIENV = _AIENV or {}


--========================== 🔵 Logging & JSON =================================
local AI_LOG_ON = false           -- set false to silence
-- Flip this to enable/disable plan-phase debug logs (AI planning only)
-- 🔧 DEBUG: force assigning & spending buffs to exercise the pipeline
local DEBUG_FORCE_BUFF = false
local PLAN_DEBUG_ON    = false
-- 🔧 Battle-only hard debug toggles
local DEBUG_FORCE_SPEND_ALWAYS   = false   -- when true, only pick buffed options if any exist
local DEBUG_IGNORE_ZONE_REVEALED = false   -- when true, treat zones as open even if "Revealed"

-- === Right-click debug menu (AI token) =======================================
local function _onoff(b) return b and "ON" or "OFF" end

-- Rebuild the context menu to reflect current states
function _ai_menu_update()
  if not self or not self.clearContextMenu then return end
  self.clearContextMenu()
  self.addContextMenuItem(("AI Log: %s"):format(_onoff(AI_LOG_ON)), _ai_menu_toggle_log, true)
  self.addContextMenuItem(("Force Buff Selection: %s"):format(_onoff(DEBUG_FORCE_BUFF)), _ai_menu_toggle_forcebuff, true)
  self.addContextMenuItem(("Force Buff Spend: %s"):format(_onoff(DEBUG_FORCE_SPEND_ALWAYS)), _ai_menu_toggle_forcespend, true)
end


function _ai_menu_toggle_log(player_color)
  AI_LOG_ON = not AI_LOG_ON
  printToColor(("AI Log → %s"):format(_onoff(AI_LOG_ON)), player_color, {0.3,0.9,1})
  _ai_menu_update()
end

function _ai_menu_toggle_forcebuff(player_color)
  DEBUG_FORCE_BUFF = not DEBUG_FORCE_BUFF
  printToColor(("Force Buff Selection → %s"):format(_onoff(DEBUG_FORCE_BUFF)), player_color, {0.3,0.9,1})
  _ai_menu_update()
end

function _ai_menu_toggle_forcespend(player_color)
  DEBUG_FORCE_SPEND_ALWAYS = not DEBUG_FORCE_SPEND_ALWAYS
  printToColor(("Force Buff Spend → %s"):format(_onoff(DEBUG_FORCE_SPEND_ALWAYS)), player_color, {0.3,0.9,1})
  _ai_menu_update()
end

-- Hook into onLoad safely (chain any existing onLoad)
local _prev_onLoad = onLoad
function onLoad(save_state)
  if _prev_onLoad then pcall(_prev_onLoad, save_state) end
  _ai_menu_update()
end
-- ============================================================================


local function _try_json(x)
  local ok, s = pcall(function() return (JSON and JSON.encode and JSON.encode(x)) end)
  return ok and s or nil
end

if type(log) ~= "function" then
  function log(x)
    if type(x) == "table" then
      local s = _try_json(x) or "<table>"
      print("[AI] "..s)
    else
      print(tostring(x))
    end
  end
end

local function AILOG(msg)
  if not AI_LOG_ON then return end
  if type(msg) == "table" then
    log({ tag = "[AI]", payload = msg })
  else
    log("[AI] "..tostring(msg))
  end
end


-- ===================== PLAN-phase debug switch ======================

local function PLANLOG(tag, data)
  if not PLAN_DEBUG_ON then return end
  AILOG({ tag = "[PLAN]"..tostring(tag), payload = data })
end
-- ===================================================================


--======================= Lua 5.1/5.2 unpack shim ==============================
if not _G.unpack and type(table.unpack) == "function" then
  _G.unpack = table.unpack
end


--================================ RNG =========================================
-- AIV2: We keep a base seed, plus a per-turn deterministic seeding helper.
local function _seed(n)
  local ok = pcall(function() math.randomseed(n or os.time()) end)
  if not ok then math.randomseed(1234567) end
end
_seed()

-- Simple 32-bit-ish rolling hash for strings/numbers (no bit ops required)
local _MOD = 2^31 - 1
local function _hstep(h, b) return ((h * 33 + b) % _MOD) end
local function _sdbm(s)
  local h = 5381
  for i = 1, #s do h = _hstep(h, string.byte(s, i)) end
  return h % _MOD
end
local function _num_to_str(n) return tostring(n or 0) end

-- Seed RNG deterministically from (side, dice, board hash, optional tag)
local function _deterministic_seed(side, dice, bh, tag)
  local s = table.concat(dice or {}, ",").."|"..tostring(bh or 0).."|"..tostring(tag or "")
  return _sdbm(s)
end


--======================== P1<->P2 Normalisation ===============================
local _A = string.byte("A")

local function _sqParse(sq)
  if type(sq)~="string" or #sq<2 then return nil end
  local f = string.byte(sq:sub(1,1):upper()) - _A + 1
  local r = tonumber(sq:match("%d+"))
  if not f or not r or f<1 or f>8 or r<1 or r>8 then return nil end
  return f,r
end

local function _sqMake(f,r)
  if not f or not r or f<1 or f>8 or r<1 or r>8 then return nil end
  return string.char(_A+f-1)..tostring(r)
end

local function _inBounds(f,r) return f>=1 and f<=8 and r>=1 and r<=8 end

local function _orth(sq)
  local f,r=_sqParse(sq); if not f then return {} end
  local t={}
  if _inBounds(f+1,r) then t[#t+1]=_sqMake(f+1,r) end
  if _inBounds(f-1,r) then t[#t+1]=_sqMake(f-1,r) end
  if _inBounds(f,r+1) then t[#t+1]=_sqMake(f,r+1) end
  if _inBounds(f,r-1) then t[#t+1]=_sqMake(f,r-1) end
  return t
end

local function _diag(sq)
  local f,r=_sqParse(sq); if not f then return {} end
  local t={}
  for df=-1,1,2 do
    for dr=-1,1,2 do
      if _inBounds(f+df,r+dr) then t[#t+1]=_sqMake(f+df,r+dr) end
    end
  end
  return t
end

local function _isOrthStep(a,b)
  local af,ar=_sqParse(a); local bf,br=_sqParse(b)
  if not af or not bf then return false end
  local dx,dy = math.abs(af-bf), math.abs(ar-br)
  return (dx+dy) == 1
end


local function _copy(t) local r={}; for k,v in pairs(t or {}) do r[k]=v end; return r end
local function _manhattan(a,b)
  local af,ar=_sqParse(a); local bf,br=_sqParse(b); if not af or not bf then return 99 end
  return math.abs(af-bf)+math.abs(ar-br)
end

local function _flipRank(sq)
  local f,r=_sqParse(sq); if not f then return sq end
  return _sqMake(f, 9 - r)
end

local function _toP2Color(c)
  if c=="Green"  then return "Blue"
  elseif c=="Yellow" then return "Pink"
  elseif c=="Orange" then return "Purple"
  else return c end
end

local function _fromP2Color(c)
  if c=="Blue"   then return "Green"
  elseif c=="Pink"  then return "Yellow"
  elseif c=="Purple" then return "Orange"
  else return c end
end


--======================= Status remap P1 → P2 view ============================
local function _statusAsP2(status, side)
  side = tostring(side or "P2"):upper()
  if side ~= "P1" then return status end

  local s, src = {}, status or {}

  -- pieces (recolor + rank-flip squares)
  s.pieces = {}
  local P = (src.pieces or {})
  local function copyPiece(e)
    local flag   = (e and (e.flag==true or e.hasFlag==true)) or false
    local shield = (e and (e.shield==true or e.hasShield==true)) or false
    local loc    = (e and e.loc) or ((e and e.square) and "BOARD" or "HOME")
    local sq     = (e and e.square) and _flipRank(e.square) or nil
    return { loc=loc, square=sq, flag=flag, shield=shield }
  end
  -- ours (P1→P2 slots)
  s.pieces.Blue   = copyPiece(P.Green  or {})
  s.pieces.Pink   = copyPiece(P.Yellow or {})
  s.pieces.Purple = copyPiece(P.Orange or {})
  -- theirs (P2→P1 slots)
  s.pieces.Green  = copyPiece(P.Blue   or {})
  s.pieces.Yellow = copyPiece(P.Pink   or {})
  s.pieces.Orange = copyPiece(P.Purple or {})

  -- token
  local sqT = (src.token and src.token.square) and _flipRank(src.token.square) or nil
  s.token = { square = sqT }
  s.dice  = src.dice or src.diceValues or {0,0,0}

  -- stacks: swap P1<->P2 groups
  local stacks = src.stacks or {}
  s.stacks = { P2 = stacks.P1 or {}, P1 = stacks.P2 or {} }

  -- flags & shields (recolor)
  local F, SH = (src.flags or {}), (src.shields or {})
  s.flags   = {
    Blue   = (F.Green  == true), Pink   = (F.Yellow == true), Purple = (F.Orange == true),
    Green  = (F.Blue   == true), Yellow = (F.Pink   == true), Orange = (F.Purple == true),
  }
  s.shields = {
    Blue   = (SH.Green == true), Pink   = (SH.Yellow== true), Purple = (SH.Orange== true),
    Green  = (SH.Blue  == true), Yellow = (SH.Pink  == true), Orange = (SH.Purple == true),
  }

  -- buffs (zones, zoneStatus, hand sizes)
  local _b  = _BUFFS(src)
  local bz  = (_b.zones)      or {}
  local bs  = (_b.zoneStatus) or {}
  local bh  = (_b.hand)       or {}
  local bht = (_b.handTypes)  or {}
  local bhc = (_b.handCards)  or {}

  local function _handCount(v, fallback)
    if type(v) == "table" then return #v end
    return tonumber(v or fallback or 0) or 0
  end

  s.buffs = {
    zones = {
      Blue   = bz.Green,  Pink   = bz.Yellow, Purple = bz.Orange,
      Green  = bz.Blue,   Yellow = bz.Pink,   Orange = bz.Purple,
    },
    zoneStatus = {
      Blue   = bs.Green,  Pink   = bs.Yellow, Purple = bs.Orange,
      Green  = bs.Blue,   Yellow = bs.Pink,   Orange = bs.Purple,
    },
    -- keep legacy numeric "hand" for UI/heuristics (size only)
    hand = {
      P2 = _handCount(bh.P1, src.p1_buff_hand_count),
      P1 = _handCount(bh.P2, src.p2_buff_hand_count),
    },
    -- pass through types and cards, swapping sides
    handTypes = {
      P2 = bht.P1,
      P1 = bht.P2,
    },
    handCards = {
      P2 = bhc.P1 or (type(bh.P1)=="table" and bh.P1 or nil),
      P1 = bhc.P2 or (type(bh.P2)=="table" and bh.P2 or nil),
    },
  }


  -- meta (finish + homes): swap sides and rank-flip squares
  local meta = src.meta or {}
  local function flipList(t)
    local out={}; for _,sq in ipairs(t or {}) do out[#out+1]=_flipRank(sq) end; return out
  end
  local finish = {
    P2 = flipList(((meta.finish or {}).P1) or {}),
    P1 = flipList(((meta.finish or {}).P2) or {}),
  }
  local homes
  if meta.homes then
    homes = {
      P2 = flipList(((meta.homes or {}).P1) or {}),
      P1 = flipList(((meta.homes or {}).P2) or {}),
    }
  end
  s.meta = { difficulty = meta.difficulty, finish = finish, homes = homes }

  return s
end

local function _outFromP2(out, side)
  side = tostring(side or "P2"):upper()
  if side ~= "P1" then return out end
  local o = {}
  for k,v in pairs(out or {}) do o[k]=v end
  if o.color then o.color = _fromP2Color(o.color) end
  if o.attackTarget and o.attackTarget~="None" then o.attackTarget = _fromP2Color(o.attackTarget) end
  if o.type=="Placement" and o.square then o.square = _flipRank(o.square) end
  if o.type=="Action" then
    if o.location     then o.location     = _flipRank(o.location)     end
    if o.location_to  then o.location_to  = _flipRank(o.location_to)  end
    if o.buffTarget and o.buffTarget~="None" then o.buffTarget = _flipRank(o.buffTarget) end
  end
  return o
end


--========================== Dynamic finish squares ============================
AI_STATE = AI_STATE or { finish = { P2=nil, P1=nil } }

-- AIV2: symmetric sane defaults if meta.finish missing.
--  • P2 default finishes = all A8..H8
--  • P1 default finishes = all A1..H1
local function _ensureFinishes(meta)
  local function full_rank(rank)
    local t = {}
    for f=1,8 do t[#t+1] = _sqMake(f, rank) end
    return t
  end

  local p2, p1
  if meta and meta.finish and type(meta.finish.P2)=="table" and #meta.finish.P2>0 then
    p2 = meta.finish.P2
  else
    p2 = full_rank(8)
  end
  if meta and meta.finish and type(meta.finish.P1)=="table" and #meta.finish.P1>0 then
    p1 = meta.finish.P1
  else
    p1 = full_rank(1)
  end

  AI_STATE.finish.P2, AI_STATE.finish.P1 = p2, p1
end

local function _in_list(list, sq)
  if not sq then return false end
  for _,s in ipairs(list or {}) do if s==sq then return true end end
  return false
end

local function _distTo(list, sq)
  local best = 99
  for _,s in ipairs(list or {}) do best = math.min(best, _manhattan(sq, s)) end
  return best
end

function isP2Finish(sq) return _in_list(AI_STATE.finish.P2 or {}, sq) end
function isP1Finish(sq) return _in_list(AI_STATE.finish.P1 or {}, sq) end
function distToP2Finish(sq) return _distTo(AI_STATE.finish.P2 or {}, sq) end
function distToP1Finish(sq) return _distTo(AI_STATE.finish.P1 or {}, sq) end


--=========================== Scores & heuristics ==============================
local function blockingValue(sq)
  local f,_r=_sqParse(sq); if not f then return 0 end
  local centerDist = math.abs(f-4.5)
  return 1/(1+centerDist)
end

local function progressScore(color, fromSq, world)
  if not fromSq then return 0 end
  local carrying = (world.Flags[color]==true)
  local d = carrying and distToP2Finish(fromSq) or distToP1Finish(fromSq)
  return 1/(1+(d or 99))
end

local function threatMap(world, knobs)
  local danger={}
  local p1sq=world.P1Squares or {}
  for _,sq in pairs(p1sq) do
    local f,r=_sqParse(sq)
    for df=-1,1 do for dr=-1,1 do
      if not (df==0 and dr==0) then
        local ff,rr=f+df,r+dr
        if _inBounds(ff,rr) then danger[_sqMake(ff,rr)] = true end
      end
    end end
  end
  if (knobs and (knobs.oppModel or 0)) >= 1 then
    for _,sq in pairs(p1sq) do for _,n in ipairs(_orth(sq)) do danger[n]=true end end
  end
  return danger
end


--=========================== Difficulty profiles ==============================
-- AIV2 unified knobs (linear d1→d5). Keep backward-compatible fields.
local Profiles = {
  [1] = { replyDepth=0, beamImmediate=2, beamSearch=0, quiescence="none",
          oppModel=0, risk=0.15, noise=0.25, buffSpend=0.10, spendCost=25,
          tokenBias=0.80, blockBias=0.40 },
  [2] = { replyDepth=0, beamImmediate=3, beamSearch=0, quiescence="none",
          oppModel=0, risk=0.20, noise=0.18, buffSpend=0.25, spendCost=22,
          tokenBias=0.90, blockBias=0.55 },
  [3] = { replyDepth=1, beamImmediate=4, beamSearch=3, quiescence="captures",
          oppModel=1, risk=0.35, noise=0.10, buffSpend=0.50, spendCost=16,
          tokenBias=1.00, blockBias=0.70 },
  [4] = { replyDepth=2, beamImmediate=5, beamSearch=4, quiescence="captures",
          oppModel=2, risk=0.55, noise=0.05, buffSpend=0.70, spendCost=10,
          tokenBias=1.10, blockBias=0.85 },
  [5] = { replyDepth=3, beamImmediate=6, beamSearch=5, quiescence="captures+finishes",
          oppModel=2, risk=0.75, noise=0.02, buffSpend=0.90, spendCost=6,
          tokenBias=1.25, blockBias=1.00 },
}

local function Knobs(diff)
  diff = math.max(1, math.min(5, tonumber(diff or 3) or 3))
  local src = Profiles[diff] or Profiles[3]
  local k = _copy(src)

  -- Back-compat aliases used by current regions
  k.depth    = k.replyDepth
  k.beam     = k.beamImmediate

  -- Core weights (unchanged semantics)
  k._killW        = 100
  k._carrierKillW = 175
  k._flagGrabW    = 500
  k._progressW    = 10
  k._tokenW       = math.floor(40 * (k.tokenBias or 1.0) + 0.5)
  k._blockW       = math.floor(25 * (k.blockBias or 1.0) + 0.5)

  k._dif          = diff   -- raw difficulty for gating
  return k
end


--=================== Request adapters (status -> state) =======================
local function _faceToKind(face)
  face = tostring(face or "ACTION"):upper()
  if face=="MOVE" or face=="ATTACK" or face=="DEFEND" then return face end
  if face=="BLANK" then return "BLANK" end
  return "ACTION"
end

local function _normZoneStatus(zones, zstat, color)
  local zs = zstat and zstat[color]
  if zs == "Revealed" or zs == "Unrevealed" or zs == "None" then
    return zs
  end
  local name = zones and zones[color] or "None"
  if name == "unknown" or name == "Unknown" then name = "Face down" end
  if name == "None" then
    return "None"
  elseif name == "Face down" then
    return "Unrevealed"
  else
    -- if zoneStatus is absent, *default to Unrevealed*, not Revealed
    return "Unrevealed"
  end
end


local function _normZoneName(v)
  v = v or "None"
  if v == "unknown" or v == "Unknown" then return "Face down" end
  return v
end

-- Forward declaration
local _BUFFS

-- Canonical accessor for whatever your payload calls the buff block.
_BUFFS = function(s) return (s and s.buffCards) or (s and s.buffs) or {} end


-- ===== Buff canonicaliser (global, single point of truth) ====================
local function _canonBuff(v)
  local k = tostring(v or "None")
  k = k:gsub("_"," "):gsub("%s+"," "):lower()
  if k=="" or k=="none" then return "None" end
  if k=="unknown" or k=="face down" or k=="facedown" then return "Face down" end
  if k:find("diag") then return "Diagonal Move" end
  if k:find("extra attack") or k:find("attack%+") or k=="atk+" or k=="a+" then
    return "Extra Attack"
  end
  if k:find("extra defend") or k:find("extra defense") or k:find("defend%+") or
     k=="def+" or k=="d+" or k:find("defense") then
    return "Extra Defend"
  end
  if k:find("extra move") or k:find("^move$") or k:find("move%+") or k=="m+" or k=="extramove" then
    return "Extra Move"
  end
  return "None"
end

-- Backward-compat alias used in existing regions
local function _canonBuffName(v) return _canonBuff(v) end

-- ===== Buff knowledge (visibility-safe) ======================================
local _BUFF_KINDS = { "Extra Move", "Diagonal Move", "Extra Attack", "Extra Defend" }

local function _mkDeckTotals()
  local t = {}
  for _,k in ipairs(_BUFF_KINDS) do t[k] = 5 end
  return t
end

local function _countListTypes(list)
  local out = {}
  for _,name in ipairs(list or {}) do
    name = _canonBuffName(name)
    if name ~= "None" and name ~= "Face down" and name ~= "" then
      out[name] = (out[name] or 0) + 1
    end
  end
  return out
end

-- Build the strict, rules-correct buff view from a P2-perspective status.
local function _extractBuffKnowledge(status)
  local b      = _BUFFS(status) or {}
  local zones  = b.zones or {}
  local zstat  = b.zoneStatus or {}
  local hand   = b.hand or {}
  local htypes = b.handTypes or {}
  local hcards = b.handCards or {}

  -- hand counts (payload may be number or array; also legacy p1_/p2_ fields)
  local function _handCount(side)
    local v = hand[side]
    if type(v) == "table" then return #v end
    local fallback = (side=="P2") and (status.p2_buff_hand_count) or (status.p1_buff_hand_count)
    return tonumber(v or fallback or 0) or 0
  end

  -- what we truly know about our own hand composition
  local function _typesForP2()
    local m = {}
    if type(htypes.P2) == "table" then
      for name, cnt in pairs(htypes.P2) do
        local n = tonumber(cnt or 0) or 0
        if n > 0 then
          local k = _canonBuffName(name)
          m[k] = (m[k] or 0) + n
        end
      end
    end
    if next(m) == nil then
      if type(hcards.P2) == "table" then
        local c = _countListTypes(hcards.P2); for k,v in pairs(c) do m[k]=v end
      elseif type(hand.P2) == "table" then
        local c = _countListTypes(hand.P2);   for k,v in pairs(c) do m[k]=v end
      end
    end
    return m
  end

  local function _zoneEntry(color)
    local nm = _canonBuffName(zones[color] or "None")
    local zs = zstat[color]
    if zs ~= "Revealed" and zs ~= "Unrevealed" and zs ~= "None" then
      zs = _normZoneStatus(zones, zstat, color)
    end
    return { name = nm, revealed = zs or "None" }
  end

  -- P2 zones are known; P1 zones are masked unless revealed
  local P2zones = { Blue=_zoneEntry("Blue"), Pink=_zoneEntry("Pink"), Purple=_zoneEntry("Purple") }
  local P1zones = { Green=_zoneEntry("Green"), Yellow=_zoneEntry("Yellow"), Orange=_zoneEntry("Orange") }
  for _,e in pairs(P1zones) do
    if e.revealed ~= "Revealed" then e.name = "" end -- enforce "blank until revealed"
  end

  return {
    deckTotals = _mkDeckTotals(),
    handCount  = { P2 = _handCount("P2"), P1 = _handCount("P1") },
    handTypes  = { P2 = _typesForP2(),    P1 = nil },        -- opponent unknown
    zones      = { P2 = P2zones,          P1 = P1zones },    -- names masked for P1 if unrevealed
  }
end


local function _statusToState(status)
  status = status or {}

  -- Pieces (capture shield/flag too)
  local P = {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    local e = (status.pieces or {})[c] or {}
    local flag   = (e.flag==true) or (e.hasFlag==true)
    local shield = (e.shield==true) or (e.hasShield==true)
    P[c] = {
      loc    = e.loc or ((e.square and "BOARD") or "HOME"),
      square = e.square,
      flag   = flag,
      shield = shield
    }
  end

  -- Token / dice
  local token = { square = (status.token and status.token.square) or nil }
  local dice  = status.dice or {0,0,0}

  -- Action stacks
  local stacks = status.stacks or {}
  local function _mkStack(src)
    local st = {}
    for i=1, math.min(6, #src) do
      st[#st+1] = { kind=_faceToKind(src[i].face), revealed=(src[i].revealed==true) }
    end
    return st
  end
  local P2s, P1s = {}, {}
  for _,c in ipairs({"Blue","Pink","Purple"}) do P2s[c] = { stack=_mkStack(((stacks.P2 or {})[c] or {})) } end
  for _,c in ipairs({"Green","Yellow","Orange"}) do P1s[c] = { stack=_mkStack(((stacks.P1 or {})[c] or {})) } end
  local actionCards = { P2 = P2s, P1 = P1s }

  -- Flags/Shields map (explicit preferred; else derive from pieces)
  local flags, shields = {}, {}
  local F = status.flags   or {}
  local SH= status.shields or {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    flags[c]   = (F[c] ~= nil)  and (F[c]==true)  or ((P[c] and P[c].flag)==true)
    shields[c] = (SH[c] ~= nil) and (SH[c]==true) or ((P[c] and P[c].shield)==true)
  end

  -- Buffs (+ derived zoneStatus when missing)
  local _b = _BUFFS(status)
  local bz = (_b.zones)      or {}
  local bh = (_b.hand)       or {}
  local bs = (_b.zoneStatus) or {}

  local zoneP1 = {
    Green  = _normZoneName(bz.Green),
    Yellow = _normZoneName(bz.Yellow),
    Orange = _normZoneName(bz.Orange),
  }
  local zoneP2 = {
    Blue   = _normZoneName(bz.Blue),
    Pink   = _normZoneName(bz.Pink),
    Purple = _normZoneName(bz.Purple),
  }

  local zstatP1 = {
    Green  = _normZoneStatus(zoneP1, bs, "Green"),
    Yellow = _normZoneStatus(zoneP1, bs, "Yellow"),
    Orange = _normZoneStatus(zoneP1, bs, "Orange"),
  }
  local zstatP2 = {
    Blue   = _normZoneStatus(zoneP2, bs, "Blue"),
    Pink   = _normZoneStatus(zoneP2, bs, "Pink"),
    Purple = _normZoneStatus(zoneP2, bs, "Purple"),
  }

  local handP1 = (type(bh.P1)=="table") and #bh.P1 or (tonumber(bh.P1 or status.p1_buff_hand_count or 0) or 0)
  local handP2 = (type(bh.P2)=="table") and #bh.P2 or (tonumber(bh.P2 or status.p2_buff_hand_count or 0) or 0)


  return {
    pieces=P, token=token, dice=dice,
    actionCards=actionCards,
    flags=flags, shields=shields,
    buffs = {
      P1 = { hand = handP1, zones = zoneP1, zoneStatus=zstatP1 },
      P2 = { hand = handP2, zones = zoneP2, zoneStatus=zstatP2 },
    }
  }
end


--=============================== World read ===================================
local function normWorld(req)
  local status = req.status or {}
  _ensureFinishes((status.meta or {})) -- refresh finishes per request if meta provided

  local S = req.state
  if not S and req.status then S = _statusToState(req.status) end
  S = S or {}

  local P   = S.pieces or {}
  local occ = {}
  local P2sq, P1sq = {}, {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    local e = P[c] or {}
    if e.loc=="BOARD" and e.square then occ[e.square]=c end
    if (c=="Blue" or c=="Pink" or c=="Purple") and e.square then P2sq[c]=e.square end
    if (c=="Green" or c=="Yellow" or c=="Orange") and e.square then P1sq[c]=e.square end
  end
  local tokenSq = (S.token or {}).square or nil

  local flags, shields = {}, {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    flags[c]   = (S.flags and S.flags[c])     or ((P[c] and P[c].flag)==true) or false
    shields[c] = (S.shields and S.shields[c]) or ((P[c] and P[c].shield)==true) or false
  end

  local action = S.actionCards or {}
  local buffs  = S.buffs or {}

  local buffK = _extractBuffKnowledge(status)

  return {
    occ=occ, P2Squares=P2sq, P1Squares=P1sq,
    TokenSq=tokenSq, P=P,
    Flags=flags, Shields=shields,
    dice = S.dice or {0,0,0},
    actionP2 = (action.P2 or {}), actionP1 = (action.P1 or {}),
    buffsP2  = (buffs.P2  or {hand=0, zones={}, zoneStatus={}}),
    buffsP1  = (buffs.P1  or {hand=0, zones={}, zoneStatus={}}),
    buffK    = buffK,
  }
end


--============================ Shared heuristics ===============================
local function enemySquareMap(world)
  local map={}
  for _,sq in pairs(world.P1Squares or {}) do if sq then map[sq] = "ENEMY" end end
  for c,_ in pairs(world.Flags or {}) do
    if (c=="Green" or c=="Yellow" or c=="Orange") and world.P1Squares[c] then
      map[world.P1Squares[c]] = "CARRIER"
    end
  end
  return map
end

local function scoreOption(option, world, knobs)
  local s=0
  if option.winNow           then s = s + 1000000 end
  if option.grabFlagNow      then s = s + (knobs._flagGrabW or 500) end
  if option.kills            then s = s + (option.kills * (knobs._killW or 100)) end
  if option.carrierKills     then s = s + (option.carrierKills * (knobs._carrierKillW or 175)) end
  if option.progress         then s = s + option.progress * (knobs._progressW or 10) end
  if option.getsToken        then s = s + (knobs._tokenW or 40) end
  if option.blocksLane       then s = s + (knobs._blockW or 25) end
  local danger = option.endsInDanger or 0
  if option.kind == "DEFEND" then danger = danger * 0.35 end
  s = s - danger * (60 * (1.0 - (knobs.risk or 0.35)))
  if (knobs.oppModel or 0) >= 1 then s = s - (option.replyDanger or 0) * 45 end
  if knobs.noise and knobs.noise>0 then s = s + math.random()*knobs.noise end
  return s
end

local function projectAndPick(candidates, world, knobs)
  if not candidates or #candidates==0 then return nil end
  local best, bestS=nil, -1e9
  local beam = math.max(2, knobs.beam or 3)
  table.sort(candidates, function(a,b) return (a._pre or 0) > (b._pre or 0) end)
  for i=1, math.min(beam, #candidates) do
    local sc=scoreOption(candidates[i], world, knobs)
    if sc>bestS then best, bestS=candidates[i], sc end
  end
  return best
end


--====================== Hashing & tiny transpo cache (AIV2) ===================
-- Compact board hash for caching / deterministic seeding
local function _world_key(world)
  local parts = {}
  local function add(tag, t)
    local keys = {}
    for k,_ in pairs(t or {}) do keys[#keys+1]=k end
    table.sort(keys)
    for _,k in ipairs(keys) do parts[#parts+1]=tag..k..":"..t[k] end
  end
  add("P2:", world.P2Squares or {})
  add("P1:", world.P1Squares or {})
  add("F:",  world.Flags or {})
  add("S:",  world.Shields or {})
  parts[#parts+1] = "T:"..tostring(world.TokenSq or "None")
  return table.concat(parts, "|")
end

local function boardHash(world) return _sdbm(_world_key(world)) end

-- Deterministic per-turn RNG seeding helper (now honors payload.rng.seed if present).
local function SeedTurnRNG(status_or_payload, side)
  local asPayload = (type(status_or_payload)=="table" and status_or_payload.status~=nil)
  local payload   = asPayload and status_or_payload or { status = status_or_payload }
  local sideU     = tostring(side or (payload.player or payload.side or "P2")):upper()

  local s   = payload.status or {}
  local sP2 = (sideU=="P1") and _statusAsP2(s, "P1") or s
  local w   = normWorld({ status = sP2 })

  local rng = payload.rng or {}

  -- 1) Direct seed provided by sim? Use it and return.
  local provided = rng.seed or rng.turn_seed or rng.turnSeed
                   or (sP2.meta and (sP2.meta.turnSeed or sP2.meta.seed))
  if provided ~= nil then
    local n = tonumber(provided)
    if not n then
      -- accept hex (e.g. "0xDEADBEEF") or any string → hash to int
      local hex = (type(provided)=="string") and provided:match("^0x(%x+)$")
      n = hex and tonumber(hex, 16) or _sdbm(tostring(provided))
    end
    _seed(n)
    return n
  end

  -- 2) Legacy path (compose a seed from parts) — unchanged behavior.
  local dice = (sP2.dice or sP2.diceValues or {0,0,0})
  local d = {
    tonumber(dice[1] or 0) or 0,
    tonumber(dice[2] or 0) or 0,
    tonumber(dice[3] or 0) or 0
  }
  table.sort(d, function(a,b) return a>b end)

  local meta     = sP2.meta or {}
  local gameSeed = rng.game_seed or meta.gameSeed
  local turnTag  = rng.turn or meta.turnTag or ""
  local same     = (rng.same_seed ~= nil) and rng.same_seed or (meta.same_seed or false)
  local aiSalt   = rng.ai_salt or ""
  if same then aiSalt = "" end

  local key = tostring(gameSeed or "").."|"..
              table.concat(d, ",").."|"..
              tostring(boardHash(w) or 0).."|"..
              tostring(turnTag or "").."|"..
              tostring(aiSalt or "")

  local seed = _sdbm(key)
  _seed(seed)
  return seed
end



-- Tiny LRU transposition cache (best-effort, safe on any host)
local TCACHE = { cap = 512, map = {}, order = {} }
local function _touch(key)
  local o = TCACHE.order
  for i=#o,1,-1 do if o[i]==key then table.remove(o,i) break end end
  o[#o+1] = key
  if #o > TCACHE.cap then
    local evict = table.remove(o, 1)
    TCACHE.map[evict] = nil
  end
end
local function tcache_get(key) return TCACHE.map[key] end
local function tcache_put(key, val) TCACHE.map[key]=val; _touch(key) end


--=============================== Entry Points =================================
function AI_Request(payload)
  payload = payload or {}
  local rawType = tostring(payload.type or payload.decision or "Action")
  local t = (rawType == "Battle") and "Action" or rawType

  local side = tostring((payload.player or payload.side or "P2")):upper()

 -- Deterministic RNG per turn (now accepts payload to read external rng settings)
pcall(function() SeedTurnRNG(payload, side) end)


  local safeLog = (function()
    local ok, s = pcall(function() return (JSON and JSON.encode and JSON.encode(payload)) end)
    return ok and s or "<payload>"
  end)()
  AILOG(("Request[%s] → "):format(side)..safeLog)

  -- If we're P1, remap status to a P2-view
  local status = payload.status
  if status and side=="P1" then
    status = _statusAsP2(status, "P1")
  end

  local req = {
    decision   = t,
    difficulty = (status and status.meta and status.meta.difficulty) or 3,
    status     = status
  }

  -- Knobs & world
  local knobs = Knobs(req.difficulty)
  local world = normWorld(req)

  local out
  if t=="Placement" or t=="placement" then
    local r = decidePlacement(req, world, knobs)
    out = { type="Placement", color=r.color, square=r.square }

  elseif t=="plan" or t=="Plan" or t=="PLAN" then
    local r = decideplan(req, world, knobs)
    -- clamp/sanitize wantBuff before returning it (use global canonicaliser)
    local wb = _canonBuff(
      r.wantBuff or r.buffKind or r.buffChoice or r.buff or r.buff_type or r.buffType or r.useBuffKind
    )

    out = { type="Plan", color=r.color, n=r.n, plan=r.plan, wantBuff=wb }

  elseif t=="Flag" or t=="flag" then
    local r = decideFlag(req, world, knobs)
    out = { type="Flag", color=r.color }

  else -- Action
    local r = decideAction(req, world, knobs)

-- MUST-MOVE safeguard: if we chose MOVE/DEFEND but 'to'==from while a legal step
-- exists, force a legal move (orth first; fall back to Diagonal Move if open).
do
  local function _firstOrthLegal(from, carrying)
    local f, rr = _sqParse(from)
    if not f then return nil end
    local dirs = carrying and { {f, rr+1}, {f-1, rr}, {f+1, rr} }
                      or    { {f, rr-1}, {f-1, rr}, {f+1, rr} }
    for _,d in ipairs(dirs) do
      local to = _sqMake(d[1], d[2])
      if to and not (world.occ or {})[to] and _isOrthStep(from, to) then
        return to
      end
    end
    return nil
  end

  if r and (r.actionKind=="move" or r.actionKind=="defend") then
    local from = r.from or ((world.P2Squares or {})[r.color])
    local to   = r.to
    if from and (not to or to==from) then
      local carrying = (world.Flags or {})[r.color] == true
      local step = _firstOrthLegal(from, carrying)

      -- If no orth step exists, try zone Diagonal Move if the zone is still open.
      if not step then
        local b      = _BUFFS(status) or {}
        local zone   = (b.zones or {})[r.color] or "None"
        local open   = ((b.zoneStatus or {})[r.color] ~= "Revealed")
        if open and zone=="Diagonal Move" then
          local f, rr = _sqParse(from)
          local dr = carrying and 1 or -1
          for _,df in ipairs({-1,1}) do
            local to2 = _sqMake(f+df, rr+dr)
            if to2 and not (world.occ or {})[to2] then
              step = to2
              r.useBuff  = true
              r.buffKind = "Diagonal Move"
              r.sequence = "BuffFirst"
              break
            end
          end
        end
      end

      if step then
        r.to = step
        r.burnOnly = false
      end
    end
  end
end


    local moveBuff   = (r.buffKind=="Extra Move" or r.buffKind=="Diagonal Move")
    local buffTarget = "None"
    if r.sequence=="BuffFirst" and moveBuff then
      if r.buffKind=="Extra Move" and r._firstStep then
        buffTarget = r._firstStep
      else
        buffTarget = r.to
      end
    end

    local attackTarget = r.attackTarget
    if (not attackTarget or attackTarget=="None") and r.actionKind=="attack" then
      for _,ec in ipairs({"Green","Yellow","Orange"}) do
        if (world.P1Squares or {})[ec] == r.to then attackTarget = ec; break end
      end
      attackTarget = attackTarget or "None"
    end

    out = {
      type             = (rawType=="Battle") and "Battle" or "Action",
      color            = r.color,
      actionKind       = r.actionKind,
      location         = r.from,
      location_to      = r.to,
      sequence         = r.sequence or "ActionFirst",
      buffCardProvided = (r.useBuff and "Yes" or "No"),
      buffKind         = r.buffKind or "None",
      buffTarget       = buffTarget,
      attackTarget     = attackTarget,
      expectKill       = r.expectKill,
      burnOnly         = (r.burnOnly==true),
    }
  end

  -- Map result back if we were playing P1
  out = _outFromP2(out, side)
  AILOG(("Decision[%s] → "):format(side)..(_try_json(out) or "<out>"))
  return out
end

-- 👇 add this wrapper so simulators calling AI.AI_Request still work
function AI.AI_Request(req) return AI_Request(req) end

-- Low-level entry (supports either state or status inside req)
function AI.Decide(req)
  req = req or {}
  local side = tostring((req.player or req.side or "P2")):upper()
  local R = (side=="P1" and {status=_statusAsP2(req.status or req, "P1")} or req)

  local knobs = Knobs(R.difficulty or ((R.status and R.status.meta and R.status.meta.difficulty) or 3))
  local world = normWorld(R)
  local what  = (R.decision or R.type or R.kind or "Action"); if what=="Battle" then what="Action" end

  local wl = tostring(what or ""):lower()
  local r = (wl=="placement" and decidePlacement(R, world, knobs))
          or (wl=="plan"      and decideplan(R, world, knobs))
          or (wl=="flag"      and decideFlag(R, world, knobs))
          or                        decideAction(R, world, knobs)

  if what=="Placement" then
    return { decision="Placement", color=_fromP2Color(r.color), square=_flipRank(r.square) }
  elseif wl=="plan" then
    return { decision="Plan", color=_fromP2Color(r.color), n=r.n, plan=r.plan, wantBuff=r.wantBuff }
  elseif what=="Flag" then
    return { decision="Flag", color=_fromP2Color(r.color) }
  else
    return r
  end
end

-- Old shims returning Turn-Token shapes (kept for back-compat)
function AI.Placement(req)
  req = req or {}
  local k = Knobs(req.difficulty)
  local w = normWorld(req)
  local r = decidePlacement(req, w, k)
  return { color=r.color, square=r.square }
end

function AI.plan(req)
  req = req or {}
  local k = Knobs(req.difficulty)
  local w = normWorld(req)
  local r = decideplan(req, w, k)
  return { color=r.color, n=r.n, plan=r.plan, wantBuff=r.wantBuff }
end

-- AI.Action(req) is defined in the Action region to return Turn-Token shape.

function AI.Flag(req)
  req = req or {}
  local k = Knobs(req.difficulty)
  local w = normWorld(req)
  local r = decideFlag(req, w, k)
  return { color=r.color }
end

-- Convenience Decide_* wrappers (legacy)
function AI.Decide_Placement(x)   local req=(x and x.state) and x or { decision="Placement", state=x };   return AI.Decide(req) end
function AI.Decide_plan(x)        local req=(x and x.state) and x or { decision="Plan", state=x };        return AI.Decide(req) end
function AI.Decide_Action(x)      local req=(x and x.state) and x or { decision="Action", state=x };      return AI.Decide(req) end
function AI.Decide_Flag(x)        local req=(x and x.state) and x or { decision="Flag", state=x };        return AI.Decide(req) end

-- Optional export of helpers used by other regions
AI._util = AI._util or {
  sqParse=_sqParse, sqMake=_sqMake, inBounds=_inBounds,
  orth=_orth, diag=_diag, copy=_copy, manhattan=_manhattan,
  progressScore=progressScore, blockingValue=blockingValue,
  threatMap=threatMap, Knobs=Knobs, normWorld=normWorld,
  isP2Finish=isP2Finish, isP1Finish=isP1Finish,
  distToP2Finish=distToP2Finish, distToP1Finish=distToP1Finish,
  enemySquareMap=enemySquareMap, projectAndPick=projectAndPick,
  -- AIV2 additions:
  boardHash=boardHash, seedTurnRNG=SeedTurnRNG,
  tcacheGet=tcache_get, tcachePut=tcache_put,
  isOrthStep=_isOrthStep,
  canonBuff=_canonBuff,          -- 🔶 new: exported canonicaliser
}

-- Prep-phase inference helper (unchanged; kept for tooling/UX)
function AI.InferPrepStatus(arg)
  local status = (type(arg)=="table" and (arg.status or ((arg.meta and arg.pieces and arg.stacks) and arg))) or {}
  local stacks = ((status.stacks or {}).P2) or {}
  local _b     = _BUFFS(status)
  local zones  = (_b.zones) or {}
  local zstat  = (_b.zoneStatus) or {}
  local dsrc = ((status.dice and #status.dice>0) and status.dice) or (status.diceValues or {})
  local dice = {
    tonumber(dsrc[1] or 0) or 0,
    tonumber(dsrc[2] or 0) or 0,
    tonumber(dsrc[3] or 0) or 0
  }
  table.sort(dice, function(a,b) return a>b end)
  local pool = { dice[1], dice[2], dice[3] }

  local function removeOnce(v) for i=1,#pool do if pool[i]==v then table.remove(pool,i); return end end end

  local function faceKind(x)
    x=tostring((x and (x.kind or x.face)) or "ACTION"):upper()
    return (x=="MOVE" or x=="ATTACK" or x=="DEFEND") and x or (x=="BLANK" and "BLANK" or "ACTION")
  end
  local function unrevealedRealList(stk)
    local t={}; for i=1,math.min(6,#(stk or {})) do local c=stk[i]; if c and c.revealed~=true then
      local k=faceKind(c); if k=="MOVE" or k=="ATTACK" or k=="DEFEND" then t[#t+1]=k end end end; return t
  end
  local function assignedCount(stk)
    local n=0; for i=1,math.min(6,#(stk or {})) do local c=stk[i]; if c and c.revealed~=true then
      local k=faceKind(c); if k~="ACTION" then n=n+1 end end end; return n
  end

  local per, prepared, none, used = {}, {}, {}, {}
  for _,c in ipairs({"Blue","Pink","Purple"}) do
    local st = (stacks[c] and stacks[c].stack) or stacks[c] or {}
    local a  = assignedCount(st)
    per[c] = {
      assigned=a,
      actionQueue=unrevealedRealList(st),
      zone=zones[c] or "None",
      zoneStatus=(zstat[c]=="Revealed" or zstat[c]=="Unrevealed" or zstat[c]=="None") and zstat[c]
                 or ((zones[c]=="None" and "None") or (zones[c]=="Face down" and "Unrevealed") or "Revealed"),
      buffUsed=(zstat[c]=="Revealed")
    }
    if a>0 then prepared[#prepared+1]=c; used[#used+1]=a else none[#none+1]=c end
  end
  for _,v in ipairs(used) do removeOnce(v) end
  return {
    perColor=per,
    preparedColors=prepared,
    piecesWithoutAssignment=none,
    usedDice=used,
    availableDice=pool,
    moveSelections={
      Blue=per.Blue.actionQueue, Pink=per.Pink.actionQueue, Purple=per.Purple.actionQueue
    }
  }
end

--#endregion Initialise

--#region Placement
--[[============================================================================
Placement — Opening Square Selection (AIV2)
Goals:
  • DIFF-5 plays “elite”: role-aware lanes, token synergy, center control,
    spacing vs allies, and safety vs immediate enemy adjacency.
  • DIFF-1 stays beginner-safe: never places into obvious danger if any safe
    home exists; still takes token-lane/center when uncontested.
  • Linear scaling 1→5 using Initialise.Knobs (risk, blockBias, tokenBias, noise).
Inputs we read: world.occ, world.P2Squares, world.P1Squares, world.TokenSq
Homes source: status.meta.homes.P2 (optional) else all A8..H8.
=============================================================================]]

function decidePlacement(req, world, knobs)
  -- Which P2 color is next?
  local nextColor =
      (req.context and req.context.nextPlacementColor)
      or (not (world.P2Squares or {}).Blue   and "Blue")
      or (not (world.P2Squares or {}).Pink   and "Pink")
      or (not (world.P2Squares or {}).Purple and "Purple")
      or "Blue"

  -- Roles
  local role = (nextColor=="Blue" and "RUNNER")
            or (nextColor=="Pink" and "BLOCKER")
            or "SUPPORT"

  -- Candidate home squares (rank 8) from meta.homes.P2 if provided
  local homesList
  if req and req.status and req.status.meta
     and req.status.meta.homes and req.status.meta.homes.P2 then
    homesList = req.status.meta.homes.P2
  elseif req and req.context and req.context.homes then
    homesList = req.context.homes
  end

  local homes = {}
  if type(homesList)=="table" and #homesList>0 then
    for _,sq in ipairs(homesList) do
      local f,r=_sqParse(sq)
      if f and r==8 then homes[#homes+1]=sq end
    end
  else
    for f=1,8 do homes[#homes+1]=string.char(string.byte("A")+f-1).."8" end
  end

  local occ    = world.occ or {}
  local token  = world.TokenSq
  local danger = threatMap(world, knobs)  -- adjacency to any visible P1 piece
  local dif    = tonumber(knobs._dif or 3) or 3

  -- Already placed own pieces (for spacing penalties)
  local placed = {}
  for _,c in ipairs({"Blue","Pink","Purple"}) do
    local sq = (world.P2Squares or {})[c]
    if sq and c~=nextColor then placed[#placed+1]=sq end
  end

  -- Weights (start from knobs)
  local wProg   = (knobs._progressW or 10)     -- mild (custom homes support)
  local wTok    = (knobs._tokenW    or 40)
  local wBlock  = (knobs._blockW    or 25)
  local wSafety = 55 * (1.0 - (knobs.risk or 0.35))  -- higher at low risk/low diff

  -- Role shaping
  if role=="RUNNER"  then wProg = wProg*1.35; wTok = wTok*1.20 end
  if role=="BLOCKER" then wProg = wProg*0.70; wBlock = wBlock*1.60 end
  -- Support stays balanced

  -- Spacing penalties (scale up with difficulty)
  local crowdScale      = 0.8 + 0.15 * (dif-1)   -- D1≈0.8 … D5≈1.4
  local sameFilePenalty = math.floor(8  * crowdScale + 0.5)
  local touchingPenalty = math.floor(20 * crowdScale + 0.5)

  -- Beginner-safe override: if any safe homes exist, prefer from them first
  local safeFirst = (dif<=2)

  -- Buff synergy nudges for this color (if zones are revealed/known)
  local _b       = _BUFFS(req.status or {})
  local zoneName = (_b.zones or {})[nextColor] or "None"
  local zoneOpen = (_b.zoneStatus or {})[nextColor]
  zoneOpen = (zoneOpen ~= "Revealed") -- “open” means we can still use it later this round
  local zExtraMove    = (zoneName=="Extra Move")
  local zDiagMove     = (zoneName=="Diagonal Move")
  local zExtraDefend  = (zoneName=="Extra Defend")

  local function fileIdx(sq) local f,_r=_sqParse(sq); return f or 1 end

  -- Helper: token-lane shaping by role
  local function laneBoostFor(sq)
    if not token then return 0 end
    local tf,_tr=_sqParse(token); local sf,_sr=_sqParse(sq)
    if not tf or not sf then return 0 end
    local fdelta = math.abs(sf - tf)
    if role=="RUNNER" then
      return (fdelta==0 and 1.00) or (fdelta==1 and 0.65) or (fdelta==2 and 0.25) or 0
    elseif role=="BLOCKER" then
      return (fdelta==0 and 0.80) or (fdelta==1 and 0.55) or (fdelta==2 and 0.20) or 0
    else -- SUPPORT
      return (fdelta==1 and 0.25) or 0
    end
  end

  -- Build list; optionally split safe vs unsafe for D1–D2
  local candidates, safeCands = {}, {}
  for _,sq in ipairs(homes) do
    if not occ[sq] then
      candidates[#candidates+1]=sq
      if not danger[sq] then safeCands[#safeCands+1]=sq end
    end
  end
  local pool = (safeFirst and #safeCands>0) and safeCands or candidates
  if #pool==0 then
    -- Nothing legal? Fallback to rightmost home or any empty back-rank
    for f=8,1,-1 do
      local s=string.char(string.byte("A")+f-1).."8"
      if not occ[s] then return { decision="Placement", color=nextColor, square=s } end
    end
    return { decision="Placement", color=nextColor, square="H8" }
  end

  -- Score candidates on rank 8
  local bestSq, bestScore = nil, -1e9
  for _,sq in ipairs(pool) do
    local sc = 0

    -- (1) Progress potential (minor from back rank; significant if custom homes)
    sc = sc + progressScore(nextColor, sq, world) * wProg

    -- (2) Token proximity / lane shaping
    if token then
      local d = _manhattan(sq, token)
      sc = sc + ((d>0) and (1/(1+d)) or 1.0) * (wTok * 0.80)
      sc = sc + laneBoostFor(sq) * (wTok * 0.25)
    end

    -- (3) Center control (favor D/E files), stronger for blocker
    sc = sc + blockingValue(sq) * (wBlock * ((role=="BLOCKER") and 1.25 or 1.00))

    -- (4) Ally spacing (avoid same/touching files)
    for _,psq in ipairs(placed) do
      if fileIdx(psq)==fileIdx(sq) then sc = sc - sameFilePenalty end
      if math.abs(fileIdx(psq)-fileIdx(sq))==1 then sc = sc - touchingPenalty end
    end

    -- (5) Immediate danger penalty (scaled by difficulty/risk)
    if danger[sq] then
      local zMitigate = (zExtraDefend and zoneOpen) and 0.75 or 1.0
      sc = sc - wSafety * zMitigate
    end

    -- (6) Buff synergy nudges
    if zoneOpen then
      if zExtraMove  then sc = sc + ((role=="RUNNER") and 10 or 6) end
      if zDiagMove   then sc = sc + ((role~="BLOCKER") and 6 or 4) end
      if zExtraDefend then sc = sc + ((role=="BLOCKER") and 8 or 5) end
    end

    -- (7) Light tiebreak noise
    if (knobs.noise or 0)>0 then sc = sc + math.random()*(knobs.noise) end

    if sc>bestScore then bestSq, bestScore = sq, sc end
  end

  bestSq = bestSq or pool[#pool] or "H8"
  return { decision="Placement", color=nextColor, square=bestSq }
end
--#endregion Placement

--#region Plan

local CAP_MOVE, CAP_ATTACK, CAP_DEFEND = 3, 2, 1
_isOrthStep = AI._util.isOrthStep

-- Keep a local debug flag for easy A/B testing of “always assign a buff”.
-- NOTE: The global DEBUG_FORCE_BUFF lives in Initialise and is left as false by default.
local DEBUG_BUFF_AUTOPICK = false

--#region BUFF
-- ─────────────────────────────────────────────────────────────────────────────
-- use_buff_check(req, world, color, planActions, knobs) → "Extra Move" | "Diagonal Move" | "Extra Attack" | "Extra Defend" | "None"
-- Purpose (tuned, more assertive):
--   Pick a buff to ASSIGN in Plan so Battle is far likelier to USE one.
--   This version chooses a buff in most “reasonable” contexts (early synergy,
--   threat, chase/finish windows), while still avoiding nonsense spends.
--
-- Selection policy (high level):
--   1) Hard blocks: zone already occupied → "None"; no buff in P2 hand → "None".
--   2) Score each buff with aggressive but logical values:
--        • Mobility (Extra/Diagonal Move): finishing, intercepting carriers,
--          creating MOVE/DEFEND→ATTACK adjacency, escaping danger, progress.
--        • Extra Attack: early ATTACK with adjacency, shield-pop+kill, carriers.
--        • Extra Defend: threatened starts/entries, carrier safety near finish.
--   3) Burst overrides (always pick): finish-now, intercept-close-carrier,
--      shield-pop+kill, threatened-with-Extra-Defend.
--   4) Threshold gate (LOWER than before). If bestScore clears → pick it.
--   5) Fail-open (NEW): if we have any early synergy (early MOVE/DEFEND/ATTACK,
--      threatened, or carrying), pick the bestAvailable even if just below the bar.
--      This makes assignment much more likely without going “always spend”.
local function use_buff_check(req, world, color, planActions, knobs)
  -- === Utilities (local)
  local function isAdj8(a,b)
    local af,ar=_sqParse(a); local bf,br=_sqParse(b)
    if not af or not bf then return false end
    local dx,dy=math.abs(af-bf),math.abs(ar-br)
    return (dx<=1 and dy<=1) and not (dx==0 and dy==0)
  end
  local function empty(sq) return sq and (world.occ or {})[sq]==nil end
  local function enemyAdjCount(from)
    local n=0
    for _,esq in pairs(world.P1Squares or {}) do if esq and isAdj8(from,esq) then n=n+1 end end
    return n
  end
  local function firstTwoKinds(plan)
    local a=plan or {}
    local f=(a[1] and tostring(a[1]):upper()) or "BLANK"
    local s=(a[2] and tostring(a[2]):upper()) or "BLANK"
    return f,s
  end
  local function hasEarly(kind, f,s) return (f==kind or s==kind) end
  local function idxOf(plan, kind)
    for i=1, math.min(6,#(plan or {})) do
      if tostring(plan[i] or ""):upper()==kind then return i end
    end
    return 99
  end

  -- === Zone availability
  local status = req.status or {}
  local b      = _BUFFS(status) or {}
  local zoneNm = _canonBuffName(((b.zones or {})[color]) or "None")
  local zstat  = (b.zoneStatus or {})[color]
  if zoneNm ~= "None" and zstat ~= "Revealed" then return "None" end

  -- === Hand (P2-known)
  local function readHand()
    local t={}
    local src=(b.handTypes and b.handTypes.P2)
    if type(src)=="table" then
      for name,cnt in pairs(src) do
        local n=math.max(0, math.floor(cnt or 0))
        if n>0 then t[_canonBuffName(name)]=n end
      end
    end
    if next(t)~=nil then return t end
    local cards=(b.handCards and b.handCards.P2) or (b.hand and b.hand.P2)
    if type(cards)=="table" then
      for _,nm in ipairs(cards) do
        local k=_canonBuffName(nm)
        if k~="None" and k~="Face down" and k~="" then t[k]=(t[k] or 0)+1 end
      end
    end
    return t
  end
  local inHand = readHand()
  if not inHand or next(inHand)==nil then return "None" end

  -- === World context & plan digest
  local here = (world.P2Squares or {})[color]
  if not here then return "None" end
  local carrying = (world.Flags[color]==true)
  local danger   = threatMap(world, knobs)
  local toFinish = carrying and (distToP2Finish(here) or 99) or 99

  local f1,f2    = firstTwoKinds(planActions)
  local earlyMoveOrDef = hasEarly("MOVE",f1,f2) or hasEarly("DEFEND",f1,f2)
  local earlyAttack    = hasEarly("ATTACK",f1,f2)
  local atkIdx         = idxOf(planActions,"ATTACK")

  -- Appetite (slightly bolder than before)
  local dif = tonumber(knobs._dif or 3) or 3
  local totalInHand=0 for _,v in pairs(inHand) do totalInHand=totalInHand+v end
  local appetite=(knobs.buffSpend or 0.50)
  appetite = appetite + 0.07*(dif-3) + (totalInHand>=3 and 0.10 or (totalInHand<=1 and -0.08 or 0))
  appetite = appetite + (carrying and 0.10 or 0)
  appetite = math.max(0.10, math.min(0.98, appetite))

  -- === Reach helpers
  local function actionReach(from, isCarrying)
    if not earlyMoveOrDef then return {} end
    local f,r=_sqParse(from); if not f then return {} end
    local dirs = isCarrying and {
      {f, r+1, false}, {f-1,r+1,true}, {f+1,r+1,true}, {f-1,r,false}, {f+1,r,false}
    } or {
      {f, r-1, false}, {f-1,r-1,true}, {f+1,r-1,true}, {f-1,r,false}, {f+1,r,false}
    }
    local out={}
    for _,d in ipairs(dirs) do
      local to=_sqMake(d[1],d[2]); if to and empty(to) then out[#out+1]=to end
    end
    return out
  end
  local function buffReach(from, allowDiag)
    local f,r=_sqParse(from); if not f then return {} end
    local out={}
    -- orth
    for _,d in ipairs({{f+1,r},{f-1,r},{f,r+1},{f,r-1}}) do
      local to=_sqMake(d[1],d[2]); if to and empty(to) then out[#out+1]=to end
    end
    -- diag
    if allowDiag then
      for df=-1,1,2 do for dr=-1,1,2 do
        local to=_sqMake(f+df,r+dr); if to and empty(to) then out[#out+1]=to end
      end end
    end
    return out
  end

  -- === Tactical detectors
  local function canFinishWith(buff)
    if not (carrying and earlyMoveOrDef) then return false end
    -- (A) one-step finish using buff-only (diag)
    if buff=="Diagonal Move" then
      for _,bTo in ipairs(buffReach(here, true)) do if isP2Finish(bTo) then return true end end
    end
    -- (B) two-step finish using Extra Move (orth+orth)
    if buff=="Extra Move" then
      local A = actionReach(here, true) -- action step first
      for _,a1 in ipairs(A) do
        local tf,tr=_sqParse(a1)
        if tf and tr and tr<8 then
          local a2=_sqMake(tf,tr+1)
          if a2 and empty(a2) and _isOrthStep(a1,a2) and isP2Finish(a2) then return true end
        end
      end
      -- Or buff-first then action into finish
      local B = buffReach(here, false)
      for _,b1 in ipairs(B) do
        if isP2Finish(b1) then return true end
        local tf,tr=_sqParse(b1)
        if tf and tr and tr<8 then
          local a2=_sqMake(tf,tr+1)
          if a2 and empty(a2) and _isOrthStep(b1,a2) and isP2Finish(a2) then return true end
        end
      end
    end
    return false
  end

  local function guaranteedShieldPopKill()
    if not earlyAttack then return false end
    for ec,esq in pairs(world.P1Squares or {}) do
      if esq and isAdj8(here, esq) and (world.Shields[ec]==true) then
        return (inHand["Extra Attack"] or 0)>0
      end
    end
    return false
  end

  local function canMakeAdjacencyThisRoundViaMobility(buff)
    if not (earlyMoveOrDef and atkIdx<=2) then return false,false end
    local allowDiag = (buff=="Diagonal Move")
    local A = actionReach(here, carrying)
    local B = buffReach(here, allowDiag)
    local can, hitsCarrier=false,false
    -- Buff then Action
    for _,b1 in ipairs(B) do
      for _,a1 in ipairs(actionReach(b1, carrying)) do
        for ec,esq in pairs(world.P1Squares or {}) do
          if esq and isAdj8(a1, esq) then
            can=true; if world.Flags[ec]==true then hitsCarrier=true end
          end
        end
      end
    end
    -- Action then Buff
    for _,a1 in ipairs(A) do
      for _,b1 in ipairs(buffReach(a1, allowDiag)) do
        for ec,esq in pairs(world.P1Squares or {}) do
          if esq and isAdj8(b1, esq) then
            can=true; if world.Flags[ec]==true then hitsCarrier=true end
          end
        end
      end
    end
    return can, hitsCarrier
  end

  local function enemyCarrierCloseToFinish()
    for _,esq in pairs(world.P1Squares or {}) do
      if esq then
        for ec,_ in pairs(world.Flags or {}) do
          if (ec=="Green" or ec=="Yellow" or ec=="Orange") and world.P1Squares[ec]==esq and world.Flags[ec]==true then
            local df=distToP1Finish(esq) or 99
            if df<=2 then return true end
          end
        end
      end
    end
    return false
  end

  -- === Scoring (numbers chosen to be assertive but sane)
  local scores = { ["Extra Move"]=-1e9, ["Diagonal Move"]=-1e9, ["Extra Attack"]=-1e9, ["Extra Defend"]=-1e9 }

  -- Mobility: Extra Move / Diagonal Move
  for _,mb in ipairs({"Extra Move","Diagonal Move"}) do
    if (inHand[mb] or 0)>0 then
      local s=0
      if canFinishWith(mb) then s = s + 5000 end
      local canAdj,hitsCarrier = canMakeAdjacencyThisRoundViaMobility(mb)
      if canAdj then s = s + (hitsCarrier and 900 or 650) end
      if enemyCarrierCloseToFinish() and canAdj and hitsCarrier then s = s + 1200 end
      if carrying then
        if toFinish<=3 then s = s + 420 end
        if danger[here] then s = s + 140 end
      else
        local baseP = progressScore(color, here, world)
        local bestDelta=0
        local allowDiag=(mb=="Diagonal Move")
        for _,bTo in ipairs(buffReach(here, allowDiag)) do
          local d = progressScore(color, bTo, world) - baseP
          if d>bestDelta then bestDelta=d end
        end
        s = s + math.floor(bestDelta*600 + 0.5)
        if mb=="Diagonal Move" then
          local f,r=_sqParse(here)
          if f then
            local orths={ _sqMake(f, r+(carrying and 1 or -1)), _sqMake(f-1,r), _sqMake(f+1,r) }
            local blocked=0 for _,o in ipairs(orths) do if not (o and empty(o)) then blocked=blocked+1 end end
            if blocked>=2 then s = s + 140 end
          end
        end
      end
      if earlyMoveOrDef then s = s + 120 end
      if danger[here] and earlyMoveOrDef then s = s + 140 end
      scores[mb]=s
    end
  end

  -- Extra Attack
  if (inHand["Extra Attack"] or 0)>0 then
    local s=0
    local adjE = enemyAdjCount(here)
    if earlyAttack and adjE>0 then
      s = s + 500 + adjE*140
      if guaranteedShieldPopKill() then s = s + 900 end
      for ec,esq in pairs(world.P1Squares or {}) do
        if esq and isAdj8(here,esq) and world.Flags[ec]==true then s = s + 700 end
      end
    else
      s = s - ((atkIdx>=3) and 220 or 100)
    end
    scores["Extra Attack"]=s
  end

  -- Extra Defend
  if (inHand["Extra Defend"] or 0)>0 then
    local s=0
    if danger[here] then s = s + 520 end
    if earlyMoveOrDef then s = s + 120 end
    if carrying then
      if toFinish<=3 then s = s + 260 end
      if danger[here] then s = s + 160 end
    end
    if earlyAttack and enemyAdjCount(here)>=1 then s = s + 200 end
    scores["Extra Defend"]=s
  end

  -- Scarcity weighting (slight nudge against spending the last copy)
  local function scarce(n) return (n>=2) and 1.00 or 0.90 end
  for name,sc in pairs(scores) do
    if sc>-1e8 then scores[name] = sc * scarce(inHand[name] or 0) end
  end

  -- === Pick best
  local bestName, bestScore = "None", -1e9
  for name,sc in pairs(scores) do
    if (inHand[name] or 0)>0 and sc>bestScore then bestName,bestScore=name,sc end
  end
  if bestName=="None" then return "None" end

  -- === Burst overrides (always spend)
  if (bestName=="Extra Move" or bestName=="Diagonal Move") and canFinishWith(bestName) then return bestName end
  do
    local canAdj,hitsCarrier = canMakeAdjacencyThisRoundViaMobility(bestName)
    if (bestName=="Extra Move" or bestName=="Diagonal Move") and enemyCarrierCloseToFinish() and canAdj and hitsCarrier then
      return bestName
    end
  end
  if bestName=="Extra Attack" and guaranteedShieldPopKill() then return bestName end
  if bestName=="Extra Defend" and danger[here] then return bestName end

  -- === Threshold (LOW) + fail-open
  local baseThresh = ({[1]=260,[2]=240,[3]=220,[4]=200,[5]=180})[dif] or 220
  local thresh = math.max(100, baseThresh - math.floor(appetite*120 + 0.5))

  if bestScore >= thresh then
    return bestName
  end

  -- Fail-open: if there is any early synergy or urgency, pick the best anyway.
  local hasSynergy = earlyMoveOrDef or earlyAttack or danger[here] or carrying
  if hasSynergy then
    return bestName
  end

  return "None"
end
--#endregion BUFF

-- ─────────────────────────────────────────────────────────────────────────────
-- Utility (unchanged helpers used by the planner)
local function _cardKind(c)
  local k = tostring((c and (c.kind or c.face)) or "ACTION"):upper()
  if k=="MOVE" or k=="ATTACK" or k=="DEFEND" then return k end
  if k=="BLANK" then return "BLANK" end
  return "ACTION"
end
local function _isRealKind(k)
  k = tostring(k or ""):upper()
  return (k=="MOVE" or k=="ATTACK" or k=="DEFEND")
end
local function _firstUnrevealedIndex(stack)
  for i=1, math.min(6, #(stack or {})) do
    local c = stack[i]
    if c and c.revealed ~= true then return i end
  end
  return 7
end
local function _unrevealedRealCounts(stack)
  local m,a,d = 0,0,0
  for i=1, math.min(6, #(stack or {})) do
    local c = stack[i]
    if c and c.revealed ~= true then
      local k = _cardKind(c)
      if     k=="MOVE"   then m = m + 1
      elseif k=="ATTACK" then a = a + 1
      elseif k=="DEFEND" then d = d + 1
      end
    end
  end
  return m,a,d
end
local function _countRealUnrevealed(stack)
  local n=0
  for i=1, math.min(6, #(stack or {})) do
    local c=stack[i]
    if c and c.revealed~=true and _isRealKind(_cardKind(c)) then n=n+1 end
  end
  return n
end

local function _enemyMapFrom(world)
  local map={}
  for _,sq in pairs(world.P1Squares or {}) do if sq then map[sq] = "ENEMY" end end
  for c,_ in pairs(world.Flags or {}) do
    if (c=="Green" or c=="Yellow" or c=="Orange") and world.P1Squares[c] then
      map[world.P1Squares[c]] = "CARRIER"
    end
  end
  return map
end
local function _prep_adj8(sq)
  local t={}; for _,n in ipairs(_orth(sq)) do t[#t+1]=n end; for _,n in ipairs(_diag(sq)) do t[#t+1]=n end
  return t
end
local function _moveCandidates(world, fromSq, carrying)
  local f,r=_sqParse(fromSq); if not f then return {} end
  local dirs
  if carrying then
    dirs = { {f, r+1}, {f-1, r+1}, {f+1, r+1}, {f-1, r}, {f+1, r} }
  else
    dirs = { {f, r-1}, {f-1, r-1}, {f+1, r-1}, {f-1, r}, {f+1, r} }
  end
  local out={}
  for _,d in ipairs(dirs) do
    local to = _sqMake(d[1], d[2])
    if to and (world.occ[to]==nil) then out[#out+1]=to end
  end
  return out
end
local function _snapshotWorld(world)
  return {
    occ       = _copy(world.occ or {}),
    P2Squares = _copy(world.P2Squares or {}),
    P1Squares = _copy(world.P1Squares or {}),
    Flags     = _copy(world.Flags or {}),
    Shields   = _copy(world.Shields or {}),
    TokenSq   = world.TokenSq,
  }
end
local function _dangerFrom(world, knobs)
  return threatMap(world, knobs)
end
local function _applySimStep(W, color, kind, knobs)
  local here = W.P2Squares[color]
  if not here then return end
  if kind=="ATTACK" then
    local emap = _enemyMapFrom(W)
    local victim=nil
    local f,r=_sqParse(here)
    for df=-1,1 do for dr=-1,1 do
      if not (df==0 and dr==0) then
        local t=_sqMake(f+df, r+dr)
        if emap[t] then
          for ec,esq in pairs(W.P1Squares or {}) do
            if esq==t then victim=ec; break end
          end
        end
      end
      if victim then break end
    end end
    if victim then
      if W.Shields[victim]==true then
        W.Shields[victim]=false
      else
        W.occ[ W.P1Squares[victim] ] = nil
        W.P1Squares[victim] = nil
        if W.Flags[victim]==true then W.Flags[victim]=false end
      end
    end
    return
  end
  if kind=="MOVE" or kind=="DEFEND" then
    local carrying = (W.Flags[color]==true)
    local cands = _moveCandidates(W, here, carrying)
    if #cands==0 then return end
    local best, bestS = here, -1e9
    local danger = _dangerFrom(W, knobs)
    for _,to in ipairs(cands) do
      local prog = progressScore(color, to, W) - progressScore(color, here, W)
      local saf  = danger[to] and -1.0 or 0.0
      local tok  = 0
      if W.TokenSq then
        local dnow = _manhattan(here, W.TokenSq)
        local dnew = _manhattan(to,  W.TokenSq)
        tok = (dnow - dnew) * 0.15
      end
      local sc = prog*40 + saf*25 + tok*10 + blockingValue(to)*3
      if carrying and isP2Finish(to) then sc = sc + 1e6 end
      if sc>bestS then bestS=sc; best=to end
    end
    if best and best~=here then
      W.occ[here]=nil
      W.occ[best]=color
      W.P2Squares[color]=best
    end
    if kind=="DEFEND" then W.Shields[color]=true end
  end
end
local function _evalBoard(W, knobs)
  local s=0
  local danger = _dangerFrom(W, knobs)
  for _,c in ipairs({"Blue","Pink","Purple"}) do
    local sq = W.P2Squares[c]
    if sq then
      s = s + progressScore(c, sq, W) * 120
      if danger[sq] then s = s - 55 * (1.0 - (knobs.risk or 0.35)) end
      if W.TokenSq and _manhattan(sq, W.TokenSq)==0 then s = s + 30 end
    end
  end
  for _,c in ipairs({"Blue","Pink","Purple"}) do
    if W.Flags[c]==true and W.P2Squares[c] and isP2Finish(W.P2Squares[c]) then
      s = s + 1e6
    end
  end
  for _,c in ipairs({"Green","Yellow","Orange"}) do
    if W.Flags[c]==true and W.P1Squares[c] and isP1Finish(W.P1Squares[c]) then
      s = s - 1e6
    end
  end
  local p2,p1=0,0
  for _,c in ipairs({"Blue","Pink","Purple"}) do if W.P2Squares[c] then p2=p2+1 end end
  for _,c in ipairs({"Green","Yellow","Orange"}) do if W.P1Squares[c] then p1=p1+1 end end
  s = s + (p2 - p1) * 60
  return s
end

local function _prepBeam(knobs)
  local d = tonumber(knobs._dif or 3) or 3
  local b = math.floor(3 + 0.75 * (d - 1))
  if b < 3 then b = 3 end
  if b > 6 then b = 6 end
  return b
end
local function _prepKeep(knobs)
  local d = tonumber(knobs._dif or 3) or 3
  local k = math.floor(6 + 1.0 * (d - 1))
  if k < 6 then k = 6 end
  if k > 12 then k = 12 end
  return k
end

local function _countListTypes(list)
  local out = {}
  for _,name in ipairs(list or {}) do
    local k = _canonBuffName(name)
    if k ~= "None" and k ~= "Face down" and k ~= "" then
      out[k] = (out[k] or 0) + 1
    end
  end
  return out
end

local function _p2BuffTypesInHand(status)
  local b = _BUFFS(status) or {}
  local m = {}

  local types = (b.handTypes and b.handTypes.P2) or nil
  if type(types) == "table" then
    local sawNumeric = false
    for name, cnt in pairs(types) do
      if type(cnt) == "number" then
        sawNumeric = true
        local n = math.max(0, math.floor(cnt or 0))
        if n > 0 then m[_canonBuffName(name)] = n end
      end
    end
    if sawNumeric and next(m) ~= nil then return m end
  end

  do
    local handsP2 = (b.hands and b.hands.P2) or nil
    local t2 = handsP2 and handsP2.types or nil
    if type(t2) == "table" then
      for name, rec in pairs(t2) do
        local n = tonumber((rec and rec.hand) or (rec and rec.usable) or 0) or 0
        if n > 0 then m[_canonBuffName(name)] = n end
      end
    end
    if next(m) ~= nil then return m end
  end

  local cards = (b.handCards and b.handCards.P2) or (b.hand and b.hand.P2)
  if type(cards) == "table" then
    local c = _countListTypes(cards)
    for k, v in pairs(c) do m[k] = (m[k] or 0) + v end
  end

  return m
end

local function _computeDicePool(status)
  local dsrc = ((status or {}).dice and #status.dice>0) and status.dice or (status and status.diceValues) or {}
  local dice={}
  for i=1,3 do local v=tonumber(dsrc[i] or 0) or 0; if v>=1 and v<=6 then dice[#dice+1]=v end end
  table.sort(dice, function(a,b) return a>b end)
  local pool={dice[1],dice[2],dice[3]}
  local function removeOnce(v)
    for i=1,#pool do if v and pool[i]==v then table.remove(pool,i); return true end end
    return false
  end
  local stacks = ((status or {}).stacks) or {}
  local grpP2 = stacks.P2 or {}
  for _,color in ipairs({"Blue","Pink","Purple"}) do
    local st = (grpP2[color] and grpP2[color].stack) or grpP2[color] or {}
    local used = _countRealUnrevealed(st)
    if used>0 then removeOnce(used) end
  end
  local grpP1 = stacks.P1 or {}
  for _,color in ipairs({"Green","Yellow","Orange"}) do
    local st = (grpP1[color] and grpP1[color].stack) or grpP1[color] or {}
    local used = _countRealUnrevealed(st)
    if used>0 then removeOnce(used) end
  end
  return pool
end

local function _shortestFinishLen(world, color)
  if world.Flags[color] ~= true then return nil end
  local start = (world.P2Squares or {})[color]; if not start then return nil end
  local q, dist = { start }, { [start] = 0 }
  local head = 1
  while q[head] do
    local sq = q[head]; head = head + 1
    if isP2Finish(sq) then return dist[sq] end
    for _,to in ipairs(_moveCandidates(world, sq, true)) do
      if not dist[to] then
        dist[to] = dist[sq] + 1
        q[#q+1] = to
      end
    end
  end
  return nil
end

local function _generatePlansForColor(color, n, world, knobs)
  if n<=0 then return {} end
  local st = (((world.actionP2 or {})[color] or {}).stack) or {}
  local m0,a0,d0 = _unrevealedRealCounts(st)
  local movesLeft   = math.max(0, CAP_MOVE   - m0)
  local attacksLeft = math.max(0, CAP_ATTACK - a0)
  local defendsLeft = math.max(0, CAP_DEFEND - d0)
  local W0 = _snapshotWorld(world)
  local here0 = W0.P2Squares[color]
  if not here0 then return {} end
  local plans = {}
  local function stepBuild(idx, Wsim, usedM, usedA, usedD, seq)
    if idx>n then
      plans[#plans+1] = { actions={table.unpack(seq)}, score=_evalBoard(Wsim, knobs) }
      return
    end
    local options = {}
    if usedM < movesLeft then
      local cands = _moveCandidates(Wsim, Wsim.P2Squares[color], (Wsim.Flags[color]==true))
      if #cands>0 then options[#options+1]="MOVE" end
    end
    if usedA < attacksLeft then
      local here=Wsim.P2Squares[color]
      local emap=_enemyMapFrom(Wsim)
      for _,t in ipairs(_prep_adj8(here)) do if emap[t] then options[#options+1]="ATTACK"; break end end
    end
    if usedD < defendsLeft then
      local cands = _moveCandidates(Wsim, Wsim.P2Squares[color], (Wsim.Flags[color]==true))
      if #cands>0 then options[#options+1]="DEFEND" end
    end
    if #options==0 then
      local seq2={table.unpack(seq)}
      local r=n-#seq2
      local addM=math.min(r, movesLeft-usedM); for i=1,addM do seq2[#seq2+1]="MOVE" end; usedM=usedM+addM; r=n-#seq2
      local addA=math.min(r, attacksLeft-usedA); for i=1,addA do seq2[#seq2+1]="ATTACK" end; usedA=usedA+addA; r=n-#seq2
      local addD=math.min(r, defendsLeft-usedD); for i=1,addD do seq2[#seq2+1]="DEFEND" end; usedD=usedD+addD
      plans[#plans+1] = { actions=seq2, score=_evalBoard(Wsim, knobs) }
      return
    end
    local branches={}
    for _,k in ipairs(options) do
      local Wn = _snapshotWorld(Wsim)
      _applySimStep(Wn, color, k, knobs)
      local sc = _evalBoard(Wn, knobs)
      branches[#branches+1] = { kind=k, score=sc, W=Wn }
    end
    table.sort(branches, function(a,b) return a.score>b.score end)
    local keep = math.min(_prepBeam(knobs), #branches)
    for i=1,keep do
      local br = branches[i]
      local nm,na,nd = usedM,usedA,usedD
      if br.kind=="MOVE"   then nm=nm+1
      elseif br.kind=="ATTACK" then na=na+1
      else nd=nd+1
      end
      local seq2={unpack(seq)}; seq2[#seq2+1]=br.kind
      stepBuild(idx+1, br.W, nm, na, nd, seq2)
    end
  end
  stepBuild(1, W0, 0, 0, 0, {})
  table.sort(plans, function(a,b) return a.score>b.score end)
  local out, seen={}, {}
  for _,p in ipairs(plans) do
    local key=table.concat(p.actions,",")
    if not seen[key] then seen[key]=true; out[#out+1]=p end
    if #out >= _prepKeep(knobs) then break end
  end
  return out
end

local function _scoreColorPriority(color, world, knobs)
  local sq = (world.P2Squares or {})[color]
  if not sq then return -1e9 end
  local s = 0
  s = s + progressScore(color, sq, world) * 100
  if (world.Flags[color]==true) then
    local _f,r=_sqParse(sq); if r then s = s + (r-4)*25 end
    if isP2Finish(sq) then s = s + 1e6 end
  end
  if color=="Pink" then s = s + blockingValue(sq)*20 end
  if world.TokenSq then
    local d=_manhattan(sq, world.TokenSq); s = s + ((d>0) and (1/(1+d)) or 1.0)*20
  end
  if (knobs.noise or 0)>0 then s = s + math.random()*knobs.noise end
  return s
end

local function _planCounts(plan, n)
  local m,a,d=0,0,0
  for i=1, math.min(n or 0, #(plan or {})) do
    local k=_cardKind({face=plan[i]})
    if k=="MOVE"   then m=m+1
    elseif k=="ATTACK" then a=a+1
    elseif k=="DEFEND" then d=d+1
    elseif k~="BLANK" then return nil, ("illegal face at slot %d: %s"):format(i, tostring(k)) end
  end
  return {MOVE=m, ATTACK=a, DEFEND=d}, nil
end

local function _auditPrepLegality(req, world, pick)
  local report = { ok=true, errors={}, warnings={}, fixed=false }
  local status = req.status or {}
  local avail  = _computeDicePool(status)
  local color  = pick.color
  local n      = tonumber(pick.n or 0) or 0
  local plan   = pick.plan or {"BLANK","BLANK","BLANK","BLANK","BLANK","BLANK"}
  local normPlan = {"BLANK","BLANK","BLANK","BLANK","BLANK","BLANK"}
  for i=1, math.min(6, #plan) do normPlan[i] = _cardKind({face=plan[i]}) end
  plan = normPlan
  if not (color=="Blue" or color=="Pink" or color=="Purple") then
    report.ok=false; table.insert(report.errors, "prep color must be one of Blue/Pink/Purple")
    color = "Blue"
  end
  local st = (((world.actionP2 or {})[color] or {}).stack) or {}
  local idx = _firstUnrevealedIndex(st)
  local slotsLeft = math.max(0, 7 - idx)
  if n<0 or n>6 then
    report.ok=false; table.insert(report.errors, ("n out of range: %d"):format(n))
    n=0
  end
  if n>slotsLeft then
    report.ok=false; table.insert(report.errors, ("n=%d exceeds remaining slots=%d"):format(n, slotsLeft))
    n=math.max(0, slotsLeft)
  end
  if n>0 then
    local found=false
    for _,v in ipairs(avail) do if v==n then found=true break end end
    if not found then
      report.ok=false; table.insert(report.errors, ("die %d not available this round"):format(n))
      local fallback=0
      for _,v in ipairs(avail) do if v<=slotsLeft and v>fallback then fallback=v end end
      n=fallback
      if n==0 then table.insert(report.warnings, "no available die fits; switching to no-op (n=0)") end
      report.fixed=true
    end
  end
  local m0,a0,d0 = _unrevealedRealCounts(st)
  local counts, faceErr = _planCounts(plan, n)
  if faceErr then
    report.ok=false; table.insert(report.errors, faceErr)
    for i=1,n do
      local k=_cardKind({face=plan[i]})
      if not (k=="MOVE" or k=="ATTACK" or k=="DEFEND" or k=="BLANK") then plan[i]="BLANK"; report.fixed=true end
    end
    counts = _planCounts(plan, n)
  end
  local mNew = (counts and counts.MOVE) or 0
  local aNew = (counts and counts.ATTACK) or 0
  local dNew = (counts and counts.DEFEND) or 0
  if m0+mNew > CAP_MOVE then
    local over = (m0+mNew) - CAP_MOVE
    for i=n,1,-1 do if over<=0 then break end if _cardKind({face=plan[i]})=="MOVE" then plan[i]="BLANK"; over=over-1; report.fixed=true end end
    mNew = _planCounts(plan, n).MOVE
    report.ok=false; table.insert(report.errors, "MOVE cap exceeded; trimmed")
  end
  if a0+aNew > CAP_ATTACK then
    local over = (a0+aNew) - CAP_ATTACK
    for i=n,1,-1 do if over<=0 then break end if _cardKind({face=plan[i]})=="ATTACK" then plan[i]="BLANK"; over=over-1; report.fixed=true end end
    aNew = _planCounts(plan, n).ATTACK
    report.ok=false; table.insert(report.errors, "ATTACK cap exceeded; trimmed")
  end
  if d0+dNew > CAP_DEFEND then
    local over = (d0+dNew) - CAP_DEFEND
    for i=n,1,-1 do if over<=0 then break end if _cardKind({face=plan[i]})=="DEFEND" then plan[i]="BLANK"; over=over-1; report.fixed=true end end
    dNew = _planCounts(plan, n).DEFEND
    report.ok=false; table.insert(report.errors, "DEFEND cap exceeded; trimmed")
  end
  local function try_fill()
    for i=1,n do
      if plan[i]=="BLANK" then
        if (m0+mNew) < CAP_MOVE   then plan[i]="MOVE";   mNew=mNew+1
        elseif (a0+aNew) < CAP_ATTACK then plan[i]="ATTACK"; aNew=aNew+1
        elseif (d0+dNew) < CAP_DEFEND then plan[i]="DEFEND"; dNew=dNew+1
        end
      end
    end
  end
  try_fill()
  local rc = _planCounts(plan, n)
  local realCount = (rc.MOVE + rc.ATTACK + rc.DEFEND)
  if realCount < n then
    table.insert(report.warnings, ("plan has %d real actions < n=%d after caps; reducing n"):format(realCount, n))
    n = realCount
    report.fixed=true
  end
  local inHand = _p2BuffTypesInHand(status)
  if pick.wantBuff and pick.wantBuff~="None" and (inHand[pick.wantBuff] or 0) == 0 then
    table.insert(report.warnings, ("wantBuff '%s' not in Player 2 hand; setting to None"):format(tostring(pick.wantBuff)))
    pick.wantBuff = "None"
    report.fixed = true
  end
  local fixed = { color=color, n=n, plan=plan, wantBuff=pick.wantBuff }
  return fixed, report
end

local function _firstBuffInP2Hand(status)
  local m = _p2BuffTypesInHand(status or {})
  for _,name in ipairs({"Extra Move","Diagonal Move","Extra Attack","Extra Defend"}) do
    if (m[name] or 0) > 0 then return name end
  end
  return nil
end

function decideplan(req, world, knobs)
  local status   = req.status or req or {}
  local dicePool = _computeDicePool(status)
  table.sort(dicePool, function(a,b) return a>b end)

  -- Colors eligible to receive a new plan (no unrevealed actions yet)
  local eligible={}
  for _,c in ipairs({"Blue","Pink","Purple"}) do
    local st = (((world.actionP2 or {})[c] or {}).stack) or {}
    local assigned = _countRealUnrevealed(st)
    if assigned==0 then eligible[#eligible+1]=c end
  end

  if #dicePool==0 or #eligible==0 then
    local out = { decision="Plan", color=eligible[1] or "Blue", n=0, plan={"BLANK","BLANK","BLANK","BLANK","BLANK","BLANK"}, wantBuff="None" }
    _auditPrepLegality(req, world, out)
    return out
  end

  -- Prioritize most valuable piece to prep
  table.sort(eligible, function(a,b) return _scoreColorPriority(a, world, knobs) > _scoreColorPriority(b, world, knobs) end)

  -- Fast path: if we’re a carrier close to finish, craft a “sprint” plan using smallest viable die
  for _,color in ipairs(eligible) do
    if world.Flags[color] == true then
      local L = _shortestFinishLen(world, color)
      if L and L > 0 then
        local st         = (((world.actionP2 or {})[color] or {}).stack) or {}
        local m0,a0,d0   = _unrevealedRealCounts(st)
        local nextIdx    = _firstUnrevealedIndex(st)
        local slotsLeft  = math.max(0, 7 - nextIdx)
        local movesLeft  = math.max(0, CAP_MOVE - m0)
        local actionsNeeded = L
        if actionsNeeded <= movesLeft and slotsLeft >= actionsNeeded then
          local bestN
          for _,d in ipairs(dicePool) do
            if d and d >= actionsNeeded and d <= slotsLeft and (not bestN or d<bestN) then bestN=d end
          end
          if bestN then
            local plan = {"BLANK","BLANK","BLANK","BLANK","BLANK","BLANK"}
            for i=1,actionsNeeded do plan[i] = "MOVE" end
            local want = use_buff_check(req, world, color, plan, knobs) or "None"
            local fixed = _auditPrepLegality(req, world, { color=color, n=bestN, plan=plan, wantBuff=want })
            if fixed and fixed.n >= actionsNeeded then
              return { decision="Plan", color=fixed.color, n=fixed.n, plan=fixed.plan, wantBuff=fixed.wantBuff }
            end
          end
        end
      end
    end
  end

  -- Full search across candidates and dice options
  local best = { score=-1e9, color=nil, n=0, actions={} }
  for _,color in ipairs(eligible) do
    local st = (((world.actionP2 or {})[color] or {}).stack) or {}
    local nextIdx = _firstUnrevealedIndex(st)
    local slotsLeft = math.max(0, 7 - nextIdx)
    local m0,a0,d0 = _unrevealedRealCounts(st)
    local capSpace = math.max(0, (CAP_MOVE-m0)) + math.max(0, (CAP_ATTACK-a0)) + math.max(0, (CAP_DEFEND-d0))
    local nCand={}
    for _,d in ipairs(dicePool) do
      if d>0 and d<=slotsLeft and d<=capSpace then nCand[#nCand+1]=d end
    end
    table.sort(nCand, function(a,b) return a>b end)
    for _,n in ipairs(nCand) do
      local plans = _generatePlansForColor(color, n, world, knobs)
      if #plans>0 then
        local p = plans[1]
        if #p.actions==n and p.score>best.score then
          best = { score=p.score, color=color, n=n, actions=p.actions }
        end
      end
    end
  end

  if not best.color or best.n<=0 then
    local out = { decision="Plan", color=eligible[1] or "Blue", n=0, plan={"BLANK","BLANK","BLANK","BLANK","BLANK","BLANK"}, wantBuff="None" }
    _auditPrepLegality(req, world, out)
    return out
  end

  local plan = {"BLANK","BLANK","BLANK","BLANK","BLANK","BLANK"}
  for i=1, math.min(best.n, #best.actions) do plan[i] = best.actions[i] end

  -- 🔶 New buff decision path: centralized, assertive, and plan-aware
  local wantBuff = use_buff_check(req, world, best.color, plan, knobs) or "None"

  -- Keep the debug hook: if DEBUG_FORCE_BUFF (global) or local AUTOPICK is on, force “some” buff to exercise the pipeline.
  if DEBUG_FORCE_BUFF or DEBUG_BUFF_AUTOPICK then
    local b = _BUFFS(status) or {}
    local zOpen = ((b.zoneStatus or {})[best.color] ~= "Revealed")
    if zOpen then
      local any = _firstBuffInP2Hand(status)
      if any then wantBuff = any end
    end
  end

  local fixed = _auditPrepLegality(req, world, { color=best.color, n=best.n, plan=plan, wantBuff=wantBuff })
  return { decision = "Plan", color = fixed.color, n = fixed.n, plan = fixed.plan, wantBuff = fixed.wantBuff }
end

--#endregion

--#region Battle
--[[============================================================================
Battle — Action Phase (AIV2)
Goals:
  • Uses assigned buffs aggressively but sensibly — with a clean separation:
    - Generate base (no-buff) options for the current face
    - Ask decide_if_buff once per color+face to produce one buffed overlay
    - Score base vs buffed together and pick the best
  • Keeps forced finishes, must-spend, and debug “force use” logic
  • Linear scaling 1→5 using Initialise.Knobs (risk, oppModel, noise, beam)
Relies on: AI._util (sqParse/Make, manhattan, blockingValue, progressScore,
                      threatMap, isP2Finish/isP1Finish, projectAndPick)
=============================================================================]]


-- === Local helpers: small wrappers around Initialise utilities ===============
local function _isAdj8(a,b)
  local af,ar=AI._util.sqParse(a); local bf,br=AI._util.sqParse(b)
  if not af or not bf then return false end
  local dx,dy=math.abs(af-bf),math.abs(ar-br)
  return (dx<=1 and dy<=1) and not (dx==0 and dy==0)
end

local function _isDiagStep(a,b)
  local af,ar=AI._util.sqParse(a); local bf,br=AI._util.sqParse(b)
  if not af or not bf then return false end
  return (math.abs(af-bf)==1) and (math.abs(ar-br)==1)
end

local _isOrthStep = AI._util.isOrthStep

local function _legal_step(world, from, to, allowDiag)
  if not to or (world.occ or {})[to] then return false end
  if _isOrthStep(from,to) then return true end
  if allowDiag and _isDiagStep(from,to) then return true end
  return false
end

local function _enemyColorAt(world, sq)
  for _,ec in ipairs({"Green","Yellow","Orange"}) do
    if (world.P1Squares or {})[ec]==sq then return ec end
  end
  return nil
end

local function _zoneFor(req, color)
  local b = _BUFFS(req and req.status or {})
  return (b.zones or {})[color] or "None"
end
local function _zoneOpen(req, color)
  if DEBUG_IGNORE_ZONE_REVEALED then return true end
  local b = _BUFFS(req and req.status or {})
  return ((b.zoneStatus or {})[color] ~= "Revealed")
end


-- Pull the next unrevealed REAL card; returns 99,"BLANK",false when none.
local function _nextRealSlot(world, color)
  local st=(((world.actionP2 or {})[color] or {}).stack) or {}
  for i=1,#st do
    local c=st[i]
    if c and c.revealed~=true then
      local k=tostring((c.kind or c.face or "ACTION")):upper()
      if (k=="MOVE" or k=="ATTACK" or k=="DEFEND") then return i,k,true end
    end
  end
  return 99,"BLANK",false
end

-- Colors tied for earliest unrevealed REAL action.
local function _tiesEarliest(world)
  local minPos, ties = 99, {}
  for _,c in ipairs({"Blue","Pink","Purple"}) do
    local pos,_,real=_nextRealSlot(world,c)
    if real and pos<minPos then minPos, ties = pos, {c}
    elseif real and pos==minPos then ties[#ties+1]=c end
  end
  return ties
end

-- Side-aware move candidates (P2 forward = +rank when carrying, -rank when not).
local function _moveCands(world, from, carrying)
  local f,r=AI._util.sqParse(from); if not f then return {} end
  local dirs = carrying and {
    {f, r+1, false}, {f-1,r+1,true}, {f+1,r+1,true}, {f-1,r,false}, {f+1,r,false}
  } or {
    {f, r-1, false}, {f-1,r-1,true}, {f+1,r-1,true}, {f-1,r,false}, {f+1,r,false}
  }
  local out={}; local occ=world.occ or {}
  for _,d in ipairs(dirs) do
    local to=AI._util.sqMake(d[1],d[2])
    if to and not occ[to] then out[#out+1]={to=to,needsDiag=d[3]} end
  end
  return out
end

-- Best adjacent target: prefer carriers, then unshielded.
local function _attackPick(from, world)
  local bestSq,bestCol,bestS=nil,nil,-1e9
  local f,r=AI._util.sqParse(from); if not f then return nil,nil end
  for df=-1,1 do for dr=-1,1 do
    if not (df==0 and dr==0) then
      local t=AI._util.sqMake(f+df,r+dr)
      local victim=_enemyColorAt(world, t)
      if victim then
        local s=(world.Flags[victim] and 120 or 0) + ((world.Shields[victim] and -30) or 15)
        if s>bestS then bestS, bestSq, bestCol=s, t, victim end
      end
    end
  end end
  return bestSq, bestCol
end

local function _finishP2(sq) return isP2Finish(sq) end

-- === Remaining REAL actions for this piece after the current face ============
local function _remainingRealAfter(world, color)
  local st = (((world.actionP2 or {})[color] or {}).stack) or {}
  local curIdx = 99
  for i=1,#st do
    local c = st[i]
    if c and c.revealed ~= true then
      local k = tostring((c.kind or c.face or "ACTION")):upper()
      if (k=="MOVE" or k=="ATTACK" or k=="DEFEND") then curIdx = i; break end
    end
  end
  if curIdx==99 then return 0 end
  local left = 0
  for i=curIdx+1,#st do
    local c = st[i]
    if c and c.revealed ~= true then
      local k = tostring((c.kind or c.face or "ACTION")):upper()
      if (k=="MOVE" or k=="ATTACK" or k=="DEFEND") then left = left + 1 end
    end
  end
  return left
end

-- Count orth-only legal moves (helps detect jammed lanes)
local function _orthLegalMoveCount(world, from, carrying)
  local f,r = AI._util.sqParse(from); if not f then return 0 end
  local dirs = carrying and { {f, r+1}, {f-1,r}, {f+1,r} }
                        or { {f, r-1}, {f-1,r}, {f+1,r} }
  local occ = world.occ or {}
  local n = 0
  for _,d in ipairs(dirs) do
    local to = AI._util.sqMake(d[1], d[2])
    if to and not occ[to] and _isOrthStep(from, to) then n = n + 1 end
  end
  return n
end

-- ✅ Forced finishing move (with Extra/Diagonal Move if available)
local function _forcedWinOption(req, world, color, face)
  if not (face=="MOVE" or face=="DEFEND") then return nil end
  if world.Flags[color] ~= true then return nil end

  local from = (world.P2Squares or {})[color]; if not from then return nil end
  local zone  = ((world.buffsP2 or {}).zones or {})[color]
  local open  = ((((req.status or {}).buffs or {}).zoneStatus or {})[color] ~= "Revealed")
  local diagAvail  = open and (zone=="Diagonal Move")
  local extraMove  = open and (zone=="Extra Move")

  local cands = _moveCands(world, from, true) -- carrying
  for _,c in ipairs(cands) do
    -- direct finish
    if _legal_step(world, from, c.to, (c.needsDiag and diagAvail)) and _finishP2(c.to) then
      if c.needsDiag and diagAvail then
        return {
          color=color, actionKind=(face=="DEFEND") and "defend" or "move",
          from=from, to=c.to, useBuff=true, buffKind="Diagonal Move",
          sequence="BuffFirst", burnOnly=false
        }
      else
        return {
          color=color, actionKind=(face=="DEFEND") and "defend" or "move",
          from=from, to=c.to, useBuff=false, buffKind="None",
          sequence="ActionFirst", burnOnly=false
        }
      end
    end
    -- 2-step finish via Extra Move
    if extraMove and (not c.needsDiag) and _legal_step(world, from, c.to, false) then
      local tf,tr = AI._util.sqParse(c.to)
      if tf and tr and tr<8 then
        local step2 = AI._util.sqMake(tf, tr+1)
        if step2 and not (world.occ or {})[step2] and _finishP2(step2) and _isOrthStep(c.to, step2) then
          return {
            color=color, actionKind="move",
            from=from, to=step2, useBuff=true, buffKind="Extra Move",
            sequence="BuffFirst", _firstStep=c.to, burnOnly=false
          }
        end
      end
    end
  end
  return nil
end

-- === MUST-SPEND gate: when true, we will only consider buff-using options ====
local function _mustSpendNow(req, world, color, face, knobs)
  if not _zoneOpen(req, color) then return false end
  local from = (world.P2Squares or {})[color]; if not from then return false end
  local zone = _zoneFor(req, color)
  local danger = AI._util.threatMap(world, knobs)
  local carrying = (world.Flags[color]==true)
  local nearFinish = carrying and ((distToP2Finish(from) or 99) <= 3)
  local rem = _remainingRealAfter(world, color)

  -- Direct synergy windows
  if face=="ATTACK" and zone=="Extra Attack" then
    local sq,_ = _attackPick(from, world)
    if sq then return true end
  end
  if (face=="MOVE" or face=="DEFEND") and (zone=="Diagonal Move" or zone=="Extra Move") then
    for _,c in ipairs(_moveCands(world, from, carrying)) do
      if (zone=="Diagonal Move" and c.needsDiag and _legal_step(world, from, c.to, true)) then
        return true
      end
      if (zone=="Extra Move" and _legal_step(world, from, c.to, false)) then
        return true
      end
    end
  end
  if zone=="Extra Defend" then
    if danger[from] then return true end
    if face=="ATTACK" then
      local sq,_ = _attackPick(from, world)
      if sq then return true end
    end
  end

  -- Urgency pressure (late in stack, threatened, or carrying near finish)
  if rem<=1 or danger[from] or nearFinish then return true end
  return false
end


-- Manufacture a minimal-but-legal “use my zone now” when needed
local function _manufactureUseOption(req, world, color, face)
  if not _zoneOpen(req, color) then return nil end
  local zone = _zoneFor(req, color)
  local from = (world.P2Squares or {})[color]; if not from then return nil end

  -- ✅ Extra Defend: legal step (orth) if available; defend-in-place otherwise.
  if zone == "Extra Defend" then
    local carrying = (world.Flags[color]==true)

    -- try to take a legal orth step (helps avoid “defend in a jam”)
    local step = nil
    for _,c in ipairs(_moveCands(world, from, carrying)) do
      if _legal_step(world, from, c.to, false) then step = c.to; break end
    end

    if face=="ATTACK" then
      -- BuffFirst so the defend step (if any) happens before the attack
      local toSq, victim = _attackPick(from, world)
      if not toSq then return nil end
      return {
        color=color, actionKind="attack",
        from=from, to=toSq,
        useBuff=true, buffKind="Extra Defend",
        sequence="BuffFirst", _firstStep=step, attackTarget=victim or "None",
        burnOnly=false
      }
    else
      -- DEFEND face: move (if step) or defend in place
      return {
        color=color, actionKind="defend",
        from=from, to=(step or from),
        useBuff=true, buffKind="Extra Defend",
        sequence="ActionFirst", burnOnly=false
      }
    end
  end

  -- Mobility zones on MOVE/DEFEND faces
  if (face=="MOVE" or face=="DEFEND") then
    local carrying = (world.Flags[color]==true)

    -- Diagonal Move
    if zone == "Diagonal Move" then
      for _,c in ipairs(_moveCands(world, from, carrying)) do
        if c.needsDiag and _legal_step(world, from, c.to, true) then
          return {
            color=color, actionKind=(face=="DEFEND") and "defend" or "move",
            from=from, to=c.to, useBuff=true, buffKind="Diagonal Move",
            sequence="BuffFirst", burnOnly=false
          }
        end
      end
    end

    -- Extra Move (prefer a valid two-step if it exists)
    if zone == "Extra Move" then
      for _,c1 in ipairs(_moveCands(world, from, carrying)) do
        if _legal_step(world, from, c1.to, false) then
          local tf,tr = AI._util.sqParse(c1.to)
          if tf and tr then
            local step2 = carrying and AI._util.sqMake(tf, tr+1) or AI._util.sqMake(tf, tr-1)
            if step2 and not (world.occ or {})[step2] and _isOrthStep(c1.to, step2) then
              return {
                color=color, actionKind="move",
                from=from, to=step2,
                useBuff=true, buffKind="Extra Move",
                sequence="BuffFirst", _firstStep=c1.to, burnOnly=false
              }
            end
          end
        end
      end
      -- Fallback: at least take a single orth step with Extra Move
      for _,c1 in ipairs(_moveCands(world, from, carrying)) do
        if _legal_step(world, from, c1.to, false) then
          return {
            color=color, actionKind=(face=="DEFEND") and "defend" or "move",
            from=from, to=c1.to,
            useBuff=true, buffKind="Extra Move",
            sequence="BuffFirst", _firstStep=c1.to, burnOnly=false
          }
        end
      end
    end
  end

  -- Extra Attack (rare: only if attacking makes sense but wasn’t detected elsewhere)
  if zone == "Extra Attack" and face=="ATTACK" then
    local toSq, victim = _attackPick(from, world)
    if toSq then
      return {
        color=color, actionKind="attack",
        from=from, to=toSq,
        useBuff=true, buffKind="Extra Attack",
        sequence="ActionFirst", attackTarget=victim or "None",
        burnOnly=false
      }
    end
  end

  return nil
end


-- Tiny board eval used for immediate-option scoring (shield + reply aware).
local function _scoreImmediate(req, world, color, face, opt, knobs)
  local W = {
    occ=AI._util.copy(world.occ or {}),
    P2Squares=AI._util.copy(world.P2Squares or {}),
    P1Squares=AI._util.copy(world.P1Squares or {}),
    Flags=AI._util.copy(world.Flags or {}),
    Shields=AI._util.copy(world.Shields or {}),
    TokenSq=world.TokenSq
  }

  -- Consume standing shield at action start unless we defend or use Extra Defend
  if not (opt.actionKind=="defend" or opt.buffKind=="Extra Defend") then
    if W.Shields[color] == true then W.Shields[color] = false end
  end

  -- Apply our action concretely
  if opt.actionKind=="attack" then
    -- Extra Defend used BuffFirst before an ATTACK: do the defend step now
if opt.useBuff and opt.buffKind=="Extra Defend" and opt.sequence=="BuffFirst" then
  local from0 = W.P2Squares[color]
  if from0 then
    if opt._firstStep and _legal_step(W, from0, opt._firstStep, false) then
      W.occ[from0]=nil; W.occ[opt._firstStep]=color; W.P2Squares[color]=opt._firstStep
      W.Shields[color] = true
    else
      -- must-move rule: if a legal defend step exists, take one
      local carrying = (W.Flags[color]==true)
      local cands = _moveCands(W, from0, carrying)
      for _,c in ipairs(cands) do
        if _legal_step(W, from0, c.to, false) then
          W.occ[from0]=nil; W.occ[c.to]=color; W.P2Squares[color]=c.to
          W.Shields[color] = true
          break
        end
      end
    end
  end
end

    local to=opt.to
    local victim=_enemyColorAt(W, to)
    if victim then
      if W.Shields[victim]==true then
        W.Shields[victim]=false
      else
        W.occ[to]=nil; W.P1Squares[victim]=nil; if W.Flags[victim]==true then W.Flags[victim]=false end
      end
    end
    -- simulate the second hit for Extra Attack when provided
    if opt.useBuff and opt.buffKind=="Extra Attack" and opt._extraFollow then
      local victim2=_enemyColorAt(W, opt._extraFollow)
      if victim2 then
        if W.Shields[victim2]==true then
          W.Shields[victim2]=false
        else
          W.occ[opt._extraFollow]=nil; W.P1Squares[victim2]=nil; if W.Flags[victim2]==true then W.Flags[victim2]=false end
        end
      end
    end
  else
    local allowDiag=(opt.useBuff and opt.buffKind=="Diagonal Move")
    local from=W.P2Squares[color]

    -- Extra Move two-step
    if opt.buffKind=="Extra Move" and opt._firstStep and from and _legal_step(W, from, opt._firstStep, allowDiag) then
      W.occ[from]=nil; W.occ[opt._firstStep]=color; W.P2Squares[color]=opt._firstStep
      from=opt._firstStep
    end

    -- Normal step (or defend-in-place when to==from is allowed)
    -- only allow to==from when there is truly no legal step
local carrying = (W.Flags[color]==true)
local canStep = false
do
  local cands = _moveCands(W, from, carrying)
  for _,c in ipairs(cands) do
    if _legal_step(W, from, c.to, allowDiag) then canStep = true; break end
  end
end

if from and (_legal_step(W, from, opt.to or to, allowDiag) or ((opt.to or to)==from and not canStep)) then

      if opt.to~=from then
        W.occ[from]=nil; W.occ[opt.to]=color; W.P2Squares[color]=opt.to
      end
    end

    -- If DEFEND (or Extra Defend), end shielded.
    if opt.actionKind=="defend" or opt.buffKind=="Extra Defend" then
      W.Shields[color] = true
    end
  end

  -- Static eval
  local s = 0
  for _, c in ipairs({"Blue","Pink","Purple"}) do
    local sq = W.P2Squares[c]
    if sq then
      s = s + AI._util.progressScore(c, sq, W) * 120 + AI._util.blockingValue(sq) * 8
      if W.TokenSq and AI._util.manhattan(sq, W.TokenSq) == 0 then s = s + 25 end
      if W.Flags[c] == true and isP2Finish(sq) then s = s + 1e6 end
    end
  end
  for _, c in ipairs({"Green","Yellow","Orange"}) do
    if W.P1Squares[c] == nil then s = s + 70 end
    if W.Flags[c] == true and W.P1Squares[c] and isP1Finish(W.P1Squares[c]) then s = s - 1e6 end
  end

  -- Danger + reply modeling (dampened when shielded)
  local riskPenBase = 55 * (1.0 - (knobs.risk or 0.35))
  local oppM = (knobs.oppModel or 0)
  local hereAfter = W.P2Squares[color]
  if hereAfter then
    local dmap = AI._util.threatMap(W, knobs)
    local selfShielded = (W.Shields[color] == true)
    if dmap[hereAfter] then
      local amp = (oppM>=2) and 1.15 or 1.0
      local shieldFactor = selfShielded and 0.35 or 1.0
      s = s - riskPenBase * amp * shieldFactor
    end
    local adj, carriers = 0, 0
    for ec,esq in pairs(W.P1Squares or {}) do
      if esq and _isAdj8(hereAfter, esq) then
        adj = adj + 1
        if W.Flags[ec]==true then carriers = carriers + 1 end
      end
    end
    local replyBase = adj*30 + carriers*40 + ((adj>=2) and 25 or 0)
    local replyScale = (0.6 + 0.2*oppM) * (0.5 + 0.5*(knobs.risk or 0.35))
    if (knobs._dif==5 and opt.actionKind=="attack") then replyBase = replyBase * 1.15 end
    if W.Shields[color]==true then replyBase = replyBase * 0.6 end
    s = s - replyBase * replyScale

    -- Setup bonuses and defend preference
    if W.Shields[color]==true then
      local setupBonus = adj*14 + carriers*12
      s = s + setupBonus
    end
    if opt.actionKind=="defend" then
      local fromBefore = (world.P2Squares or {})[color]
      local pd = 0
      if fromBefore and hereAfter then
        pd = (AI._util.progressScore(color, hereAfter, W) - AI._util.progressScore(color, fromBefore, W))
      end
      s = s + 6 + math.max(0, pd)*30
    end
    if W.Flags[color]==true and W.Shields[color]==true then
      local dfin = distToP2Finish(hereAfter) or 99
      if dfin <= 2 then s = s + 80 elseif dfin <= 3 then s = s + 40 end
    end

    -- Intercept bonus (adjacent to enemy carrier after our move)
    if carriers > 0 then
      local intercept = 0
      for ec,esq in pairs(W.P1Squares or {}) do
        if esq and W.Flags[ec]==true and _isAdj8(hereAfter, esq) then
          local df = distToP1Finish(esq) or 99
          intercept = math.max(intercept, (df<=2 and 120 or (df<=3 and 85 or 55)))
        end
      end
      if intercept>0 then
        if W.Shields[color]==true then intercept = intercept * 1.15 end
        s = s + intercept
      end
    end
  end

  -- Spend cost & appetite shaping
  local spendCost = tonumber(knobs.spendCost) or ((knobs._dif==5) and 4 or 20)
  if opt.useBuff and opt.buffKind=="Extra Defend" then spendCost = spendCost * 0.65 end
  if opt.useBuff and opt.buffKind=="Extra Move" and isP2Finish(opt.to) then spendCost = spendCost * 0.25 end
  if opt.useBuff then s = s - (spendCost * (1.0 - (knobs.risk or 0.35))) end

  -- Lane-unlock nudge for Diagonal Move when orth lanes are jammed
  if opt.useBuff and opt.buffKind=="Diagonal Move" and opt.from and opt.to then
    local carrying2 = (world.Flags[color]==true)
    local orthCount = _orthLegalMoveCount(world, opt.from, carrying2)
    if orthCount <= 1 then s = s + 110 end
  end

  -- Strong late-round decay pressure — prefer spending when few actions remain
  do
    local rem = _remainingRealAfter(world, color)
    if opt.useBuff then
      local appetite = (knobs.buffSpend or 0.5)
      local bonus = (rem<=0 and 240 or (rem==1 and 180 or (rem==2 and 90 or 0)))
      s = s + bonus * (0.85 + 0.4*appetite)
    else
      if _zoneOpen(req, color) and rem<=1 then
        s = s - (rem==0 and 130 or 80)
      end
    end
  end

  -- 🔴 HARD DEBUG: if ALWAYS is on, make any buffed option dominate bases.
  if DEBUG_FORCE_SPEND_ALWAYS and opt.useBuff then
    s = s + 1e6
  end

  if (knobs.noise or 0) > 0 then s = s + math.random() * (knobs.noise) end
  return s
end


-- === Elite/any-diff extra buff options ======================================
local function _extraAttackOption(req, world, color)
  if not _zoneOpen(req, color) then return nil end
  if _zoneFor(req, color) ~= "Extra Attack" then return nil end
  local from = (world.P2Squares or {})[color]; if not from then return nil end
  local firstSq, victim = _attackPick(from, world); if not firstSq then return nil end

  -- simulate first hit to see if a second exists
  local W = AI._util.copy(world)
  W.occ = AI._util.copy(world.occ or {})
  W.P2Squares = AI._util.copy(world.P2Squares or {})
  W.P1Squares = AI._util.copy(world.P1Squares or {})
  W.Flags = AI._util.copy(world.Flags or {})
  W.Shields = AI._util.copy(world.Shields or {})

  local vColor = _enemyColorAt(W, firstSq)
  if vColor then
    if W.Shields[vColor]==true then
      W.Shields[vColor]=false
    else
      W.occ[firstSq]=nil; W.P1Squares[vColor]=nil; W.Flags[vColor]=false
    end
  end
  local secondSq, _ = _attackPick(from, W)
  if not secondSq then return nil end

  return {
    color=color, actionKind="attack", from=from, to=firstSq,
    useBuff=true, buffKind="Extra Attack", sequence="BuffFirst",
    attackTarget=vColor or "None", burnOnly=false, _extraFollow=secondSq
  }
end

-- Attack with Extra Defend cover (buff first, then attack, end shielded)
local function _extraDefendAttackCover(req, world, color, knobs)
  if not _zoneOpen(req, color) or _zoneFor(req, color) ~= "Extra Defend" then return nil end
  if (world.Shields or {})[color] == true then return nil end
  local from = (world.P2Squares or {})[color]; if not from then return nil end

  local sq, victim = _attackPick(from, world); if not sq then return nil end

  -- Only worth spending if reply looks scary at the destination
  local dmap = AI._util.threatMap(world, knobs)
  local adj = 0
  for _,esq in pairs(world.P1Squares or {}) do if esq and _isAdj8(sq, esq) then adj = adj + 1 end end
  if not dmap[sq] and adj == 0 then return nil end

  return {
    color=color, actionKind="attack", from=from, to=sq,
    useBuff=true, buffKind="Extra Defend", sequence="BuffFirst",
    attackTarget=victim or "None", burnOnly=false
  }
end

-- Extra Defend escape: defend first, then move to safest adjacent
local function _extraDefendEscape(req, world, color, knobs)
  if not _zoneOpen(req, color) then return nil end
  if _zoneFor(req, color) ~= "Extra Defend" then return nil end
  if (world.Shields or {})[color] == true then return nil end -- already protected
  local from = (world.P2Squares or {})[color]; if not from then return nil end
  local danger = AI._util.threatMap(world, knobs)
  if not danger[from] then return nil end

  local cands = _moveCands(world, from, (world.Flags[color]==true))
  local best, bestS
  for _,c in ipairs(cands) do
    local s = (danger[c.to] and -1 or 0) + AI._util.blockingValue(c.to)*3 + AI._util.progressScore(color, c.to, world)*20
    if not best or s>bestS then best, bestS=c, s end
  end
  if not best then return nil end
  return {
    color=color, actionKind="move", from=from, to=best.to,
    useBuff=true, buffKind="Extra Defend", sequence="BuffFirst",
    burnOnly=false
  }
end

-- DEBUG helper: manufacture a legal "use my zone right now" option if possible
local function _forceUseBuffOption(req, world, color, face)
  -- Battle-phase forcing uses DEBUG_FORCE_SPEND_ALWAYS, not the plan-phase flag.
  if not DEBUG_FORCE_SPEND_ALWAYS then return nil end
  return _manufactureUseOption(req, world, color, face)
end



-- === NEW: Base (no-buff) options ============================================
local function _baseOptionsForColorFace(req, world, color, face, knobs)
  local opts = {}
  local from = (world.P2Squares or {})[color]
  if not from then return opts end

  -- Forced win (no-buff handled here; buffed pathways handled by decide_if_buff)
  local fw = _forcedWinOption(req, world, color, face)
  if fw and fw.useBuff==false then return { fw } end
  -- if fw.useBuff==true we still generate normal base options; buffed forced finish will come via decide_if_buff

  if face == "ATTACK" then
    local sq, victim = _attackPick(from, world)
    if sq then
      opts[#opts+1] = {
        color=color, actionKind="attack",
        from=from, to=sq,
        useBuff=false, buffKind="None",
        sequence="ActionFirst", burnOnly=false,
        attackTarget=victim or "None",
        expectKill=(victim and (world.Shields[victim]~=true)) or false
      }
    end
  else
    local carrying = (world.Flags[color]==true)
    local danger = AI._util.threatMap(world, knobs)
    for _,c in ipairs(_moveCands(world, from, carrying)) do
      if _legal_step(world, from, c.to, false) then
        opts[#opts+1] = {
          color=color, actionKind=(face=="DEFEND") and "defend" or "move",
          from=from, to=c.to,
          useBuff=false, buffKind="None",
          sequence="ActionFirst", burnOnly=false
        }
      end
    end
    -- defend-in-place as safe fallback
    if face=="DEFEND" or (face=="MOVE" and danger[from]) or #opts==0 then
      opts[#opts+1] = {
        color=color, actionKind="defend",
        from=from, to=from,
        useBuff=false, buffKind="None",
        sequence="ActionFirst", burnOnly=false
      }
    end
  end

  return opts
end

-- === NEW: Core buff decision (single overlay per color+face) =================
function decide_if_buff(req, world, color, face, knobs)
  local function skip() return { use=false, useBuff=false } end

  if not _zoneOpen(req, color) then return skip() end
  local zone = _zoneFor(req, color)
  if zone == "None" then return skip() end

  local from = (world.P2Squares or {})[color]; if not from then return skip() end
  local carrying = (world.Flags[color]==true)

  -- 🔴 HARD DEBUG: if ALWAYS is on, try to spend *right now* in any legal way.
  -- This makes the first legal face consume the unrevealed zone card.
  if DEBUG_FORCE_SPEND_ALWAYS then
    local forced = _manufactureUseOption(req, world, color, face)
    if forced then return forced end
    -- If we couldn't legally spend on this face (e.g., Extra Attack with no target),
    -- we fall through to normal logic so a later face can spend it ASAP.
  end

  local danger = AI._util.threatMap(world, knobs)
  local remLeft = _remainingRealAfter(world, color)
  local must = _mustSpendNow(req, world, color, face, knobs)

-- 🔧 DEBUG: if forcing is on and the zone is still unrevealed, spend ASAP.
if DEBUG_FORCE_SPEND_ALWAYS then
  local forced = _manufactureUseOption(req, world, color, face)
  if forced then return forced end
end


  -- 1) Forced finish (return only if it *uses* a buff; no-buff path is in base)
  do
    local fw = _forcedWinOption(req, world, color, face)
    if fw and fw.useBuff==true then return fw end
  end

  -- 2) Zone-specific logic
  if zone == "Extra Attack" and face=="ATTACK" then
    local ea = _extraAttackOption(req, world, color)
    if ea then return ea end
    if must then
      local toSq, victim = _attackPick(from, world)
      if toSq then
        return {
          color=color, actionKind="attack", from=from, to=toSq,
          useBuff=true, buffKind="Extra Attack", sequence="BuffFirst",
          attackTarget=victim or "None", burnOnly=false
        }
      end
    end
    return skip()
  end

  if zone == "Extra Defend" then
    if face=="ATTACK" then
      local cover = _extraDefendAttackCover(req, world, color, knobs)
      if cover then return cover end
      if must then
        local toSq, victim = _attackPick(from, world)
        if toSq then
          return {
            color=color, actionKind="attack", from=from, to=toSq,
            useBuff=true, buffKind="Extra Defend", sequence="BuffFirst",
            attackTarget=victim or "None", burnOnly=false
          }
        end
      end
      return skip()
    end
    local esc = _extraDefendEscape(req, world, color, knobs)
    if esc then return esc end
    if must then
      return {
        color=color, actionKind=(face=="DEFEND") and "defend" or "move",
        from=from, to=from,
        useBuff=true, buffKind="Extra Defend", sequence="BuffFirst",
        burnOnly=false
      }
    end
    return skip()
  end

  if (zone == "Diagonal Move" or zone == "Extra Move") and (face=="MOVE" or face=="DEFEND") then
    local cands = _moveCands(world, from, carrying)

    if zone=="Diagonal Move" then
      for _,c in ipairs(cands) do
        if c.needsDiag and _legal_step(world, from, c.to, true) then
          return {
            color=color, actionKind=(face=="DEFEND") and "defend" or "move",
            from=from, to=c.to,
            useBuff=true, buffKind="Diagonal Move", sequence="BuffFirst",
            burnOnly=false
          }
        end
      end
      if must then
        local f,r = AI._util.sqParse(from)
        for df=-1,1,2 do for dr=-1,1,2 do
          local to = AI._util.sqMake(f+df, r+dr)
          if to and not (world.occ or {})[to] then
            return {
              color=color, actionKind=(face=="DEFEND") and "defend" or "move",
              from=from, to=to,
              useBuff=true, buffKind="Diagonal Move", sequence="BuffFirst",
              burnOnly=false
            }
          end
        end end
      end
      return skip()
    end

    -- Extra Move
    do
      local best=nil; local bestProg=-1e9; local bestSeq="BuffFirst"
      for _,c1 in ipairs(cands) do
        if _legal_step(world, from, c1.to, false) then
          local tf,tr = AI._util.sqParse(c1.to)
          if tf and tr then
            local step2 = carrying and AI._util.sqMake(tf, tr+1) or AI._util.sqMake(tf, tr-1)
            if step2 and not (world.occ or {})[step2] and _isOrthStep(c1.to, step2) then
              if isP2Finish(step2) then
                return {
                  color=color, actionKind="move",
                  from=from, to=step2, useBuff=true, buffKind="Extra Move",
                  sequence="BuffFirst", _firstStep=c1.to, burnOnly=false
                }
              end
              local p = AI._util.progressScore(color, step2, world)
              if p > bestProg then bestProg=p; best={to=step2, first=c1.to}; bestSeq="BuffFirst" end
              -- ActionFirst variant
              if p >= bestProg then bestProg=p; best={to=step2, first=c1.to}; bestSeq="ActionFirst" end
            end
          end
        end
      end
      if best then
        return {
          color=color, actionKind="move",
          from=from, to=best.to, useBuff=true, buffKind="Extra Move",
          sequence=bestSeq, _firstStep=best.first, burnOnly=false
        }
      end
      if must then
        local any = _manufactureUseOption(req, world, color, face)
        if any then return any end
      end
    end

    return skip()
  end

  -- 3) End-of-actions safety (spend if some gain exists)
  if remLeft == 0 then
    local any = _manufactureUseOption(req, world, color, face)
    if any then return any end
  end

  -- 4) Debug brute force (BACKSTOP)
  local dbg = _forceUseBuffOption(req, world, color, face)
  if dbg then return dbg end

  return skip()
end


-- === Choose the best concrete option for a given color+face ==================
local function _bestOptionForColorFace(req, world, color, face, knobs)
  local cand = {}

  -- Base (no-buff) options
  local base = _baseOptionsForColorFace(req, world, color, face, knobs)
  for _,o in ipairs(base) do
    o._pre = _scoreImmediate(req, world, color, face, o, knobs)
    cand[#cand+1] = o
  end

  -- Single buff overlay
  local b = decide_if_buff(req, world, color, face, knobs)
  if b and b.use ~= false then
    b._pre = _scoreImmediate(req, world, color, face, b, knobs)
    cand[#cand+1] = b
  end

  -- 🔧 Hard debug: if requested, only consider buffed options.
  if DEBUG_FORCE_SPEND_ALWAYS then
    local buffed = {}
    for _,o in ipairs(cand) do
      if o.useBuff == true then buffed[#buffed+1] = o end
    end
    if #buffed > 0 then
      cand = buffed
    else
      -- Try to manufacture *some* buff use so we never stall.
      local m = _manufactureUseOption(req, world, color, face)
      if m then
        m._pre = _scoreImmediate(req, world, color, face, m, knobs)
        cand = { m }
      end
      -- If m is nil we fall through with base options (no legal buff spend)
    end
  end

  -- (Optional) tiny trace so you can see candidates
  if PLAN_DEBUG_ON then
    AILOG({
      tag = "[BATTLE] cand",
      payload = (function()
        local t = {}
        for i,o in ipairs(cand) do
          t[i] = {
            useBuff   = o.useBuff,
            kind      = o.actionKind,
            buffKind  = o.buffKind,
            seq       = o.sequence,
            from      = o.from,
            to        = o.to,
            pre       = o._pre
          }
        end
        return t
      end)()
    })
  end

  return AI._util.projectAndPick(cand, world, knobs)
end


local function _nextFaceFor(world, color)
  local _, k, real = _nextRealSlot(world, color)
  return real and k or "BLANK"
end

function decideAction(req, world, knobs)
  -- Colors tied for the earliest unrevealed REAL action
  local ties = _tiesEarliest(world)

  -- If nothing left to do, burn a safe no-op defend (should be rare)
  if #ties == 0 then
    local c = (world.P2Squares or {}).Blue and "Blue"
           or (world.P2Squares or {}).Pink and "Pink"
           or (world.P2Squares or {}).Purple and "Purple"
           or "Blue"
    return {
      color=c, actionKind="defend",
      from=(world.P2Squares or {})[c], to=(world.P2Squares or {})[c],
      useBuff=false, buffKind="None", sequence="ActionFirst", burnOnly=true
    }
  end

  local bestOpt, bestScore = nil, -1e9

  for _,color in ipairs(ties) do
    local face = _nextFaceFor(world, color)

    -- Pick best among base options + single buff overlay
    local opt = _bestOptionForColorFace(req, world, color, face, knobs)

    -- If nothing legal came back, try to manufacture a minimal-but-legal use,
    -- else fall back to a defend-in-place burn so we never stall.
    if not opt then
      opt = _manufactureUseOption(req, world, color, face) or {
        color=color, actionKind="defend",
        from=(world.P2Squares or {})[color], to=(world.P2Squares or {})[color],
        useBuff=false, buffKind="None", sequence="ActionFirst", burnOnly=true
      }
    end

    local sc = _scoreImmediate(req, world, color, face, opt, knobs)
    if sc > bestScore then
      bestScore, bestOpt = sc, opt
    end
  end

  -- Final safety: if for some reason we still have nothing, defend in place.
  if not bestOpt then
    local c = ties[1]
    return {
      color=c, actionKind="defend",
      from=(world.P2Squares or {})[c], to=(world.P2Squares or {})[c],
      useBuff=false, buffKind="None", sequence="ActionFirst", burnOnly=true
    }
  end

  return bestOpt
end
--#endregion Battle

--#region Flag
-- Decision logic for who should grab the flag (if anyone).
-- Improvements:
--   • Escape viability: weighs safe orth/diag exits + a short lookahead lane check
--   • Stack awareness: prefers a color whose next unrevealed face is MOVE/DEFEND and soon
--   • Ally cover vs enemy pressure: counts adjacent allies/enemies (scaled by risk)
--   • Buff synergy: Diagonal/Extra Move/Extra Defend nudge the score
--   • Difficulty-aware weights (small nudges with req.difficulty or knobs._dif)
--   • Conservative fallback: if escape looks bad, returns nil

local function _nextFaceInfo(world, color)
  -- Return (pos, face, real) for next unrevealed REAL face, else 99,"NONE",false
  local st = (((world.actionP2 or {})[color] or {}).stack) or {}
  for i=1,#st do
    local c = st[i]
    if c and c.revealed ~= true then
      local k = tostring((c.kind or c.face or "ACTION")):upper()
      local real = (k=="MOVE" or k=="ATTACK" or k=="DEFEND")
      if real then return i, k, true end
    end
  end
  return 99, "NONE", false
end

local function _adjacentCounts(world, sq)
  local allies, enemies = 0, 0
  local occ = world.occ or {}
  local a = (AI._util and AI._util.enemySquareMap) and AI._util.enemySquareMap(world) or {}
  for _,t in ipairs(AI._util.orth(sq)) do
    if occ[t] and (occ[t]=="Blue" or occ[t]=="Pink" or occ[t]=="Purple") then allies = allies + 1 end
    if a[t] == "ENEMY" or a[t] == "CARRIER" then enemies = enemies + 1 end
  end
  return allies, enemies
end


local function _laneAheadScore(world, fromSq, allowDiag, carrying)
  -- Short lookahead in front of P2 (+rank). Reward open & safe steps.
  local f,r = AI._util.sqParse(fromSq); if not f then return 0 end
  local occ   = world.occ or {}
  local danger= AI._util.threatMap(world, {})  -- knobs not critical for map shape here
  local s = 0
  local steps = { {0,1,false}, {-1,1,true}, {1,1,true} }
  for depth=1,3 do
    for _,d in ipairs(steps) do
      local to = AI._util.sqMake(f + d[1], r + d[2]*depth)
      if to and not occ[to] then
        local safe = danger[to] and 0 or 1
        local diag = d[3]
        if (not diag) or (diag and allowDiag) then
          s = s + (safe==1 and (1.0/(depth)) or 0.15/(depth))
        end
      end
    end
  end
  -- small finish bonus if already carrying and one of those is a finish
  if carrying then
    for depth=1,2 do
      local fwd = AI._util.sqMake(f, r+depth)
      if fwd and AI._util and AI._util.isP2Finish and AI._util.isP2Finish(fwd) then
        s = s + 1.2
      end
    end
  end
  return s
end

function decideFlag(req, world, knobs)
  -- If any P2 already carries, do nothing
  for _,c in ipairs({"Blue","Pink","Purple"}) do
    if world.Flags[c]==true then
      return { decision="Flag", color=nil }
    end
  end

  -- Candidates on rank 1 only
  local cands={}
  for _,c in ipairs({"Blue","Pink","Purple"}) do
    local sq = (world.P2Squares or {})[c]
    if sq then
      local _f,r=AI._util.sqParse(sq)
      if r==1 then cands[#cands+1]=c end
    end
  end
  if #cands==0 then return { decision="Flag", color=nil } end

  local danger = AI._util.threatMap(world, knobs)
  local occ    = world.occ or {}
  local bz     = (world.buffsP2 or {}).zones or {}
  local zstat  = (_BUFFS(req.status or {}).zoneStatus) or {}

  -- Difficulty / risk knobs
  local d = tonumber((knobs and knobs._dif) or (req and req.difficulty) or 3) or 3
  local risk = (knobs and knobs.risk) or 0.35
  local safetyScale = (1.15 - math.min(1.0, math.max(0.0, risk))) -- lower risk => larger penalty

  -- Weights (gentle dif nudges; preserve original feel)
  local wSafeO = 2.4 + 0.28*d
  local wSafeD = 1.1 + 0.18*d
  local wDist  = 3.1 + 0.30*d
  local wBlock = 0.55
  local wLane  = 1.2 + 0.22*d
  local wAllies= 0.6
  local wStack = 1.0 + 0.35*d

  local dangerOne   = 22.0 * safetyScale
  local dangerBase  = 2.4  * safetyScale
  local enemyAdjPen = 16.0 * safetyScale

  local function distTo8Score(sq)
    local d8 = AI._util.distToP2Finish and AI._util.distToP2Finish(sq) or 99
    return 1/(1+(d8 or 99))
  end

  local function safeExitCounts(sq, allowDiag)
    local safeO, safeD = 0, 0
    for _,t in ipairs(AI._util.orth(sq)) do if not occ[t] and not danger[t] then safeO=safeO+1 end end
    if allowDiag then
      for _,t in ipairs(AI._util.diag(sq)) do if not occ[t] and not danger[t] then safeD=safeD+1 end end
    end
    return safeO, safeD
  end

  local best, bestS, bestSafeO, bestSafeD = nil, -1e9, 0, 0
  for _,c in ipairs(cands) do
    local sq = (world.P2Squares or {})[c]
    local allowDiag = (bz[c]=="Diagonal Move")
    local extraMove = (bz[c]=="Extra Move")
    local extraDef  = (bz[c]=="Extra Defend")
    local zoneOpen  = (zstat[c] ~= "Revealed")

    local safeO, safeD = safeExitCounts(sq, allowDiag)
    local allies, enemies = _adjacentCounts(world, sq)
    local pos, nextFace, hasNext = _nextFaceInfo(world, c)
    local stackNudge = 0
    if hasNext then
      -- prefer soon/usable actions
      if nextFace=="MOVE" or nextFace=="DEFEND" then
        stackNudge = stackNudge + (pos>=6 and 0.2 or (pos>=4 and 0.45 or (pos>=3 and 0.7 or 1.0)))
      else
        stackNudge = stackNudge - (pos>=6 and 0.4 or (pos>=4 and 0.25 or 0.1))
      end
    else
      stackNudge = stackNudge - 0.6
    end

    -- Buff synergy (only if the zone is still unrevealed)
    local buffNudge = 0
    if zoneOpen then
      if allowDiag then buffNudge = buffNudge + 0.6 end
      if extraMove then buffNudge = buffNudge + 0.9 end
      if extraDef  then buffNudge = buffNudge + 0.7 end
    end

    local lane = _laneAheadScore(world, sq, allowDiag, true)
    local s = 0
    s = s + safeO * wSafeO
    s = s + safeD * wSafeD
    s = s + AI._util.blockingValue(sq) * wBlock
    s = s + distTo8Score(sq) * wDist
    s = s + lane * wLane
    s = s + allies * wAllies
    s = s + stackNudge * wStack
    s = s + buffNudge

    if danger[sq] then s = s - dangerBase end
    s = s - enemies * enemyAdjPen
    if enemies>=1 then s = s - dangerOne end
    if (knobs.noise or 0)>0 then s = s + math.random() * knobs.noise end

    if s>bestS then best, bestS, bestSafeO, bestSafeD = c, s, safeO, safeD end
  end

  if not best then return { decision="Flag", color=nil } end

  -- Conservative safety gate:
  --  • if no safe exits at all and current square is threatened, skip
  --  • if adjacent enemies are many and we lack defend tools, skip
  local bestSq = (world.P2Squares or {})[best]
  local allowDiag = ((world.buffsP2 or {}).zones or {})[best] == "Diagonal Move"
  local extraDef  = ((world.buffsP2 or {}).zones or {})[best] == "Extra Defend"
  local zoneOpen  = ((((req.status or {}).buffs or {}).zoneStatus) or {})[best] ~= "Revealed"

  local _, enemies = _adjacentCounts(world, bestSq)
  local alreadyShielded = (world.Shields or {})[best] == true
  local hasDefTools = (zoneOpen and extraDef) or alreadyShielded
  if (bestSafeO + bestSafeD) == 0 and bestSq and danger[bestSq] then
    return { decision="Flag", color=nil }
  end
  if enemies >= 2 and not hasDefTools then
    return { decision="Flag", color=nil }
  end

  return { decision="Flag", color=best }
end
--#endregion Flag

