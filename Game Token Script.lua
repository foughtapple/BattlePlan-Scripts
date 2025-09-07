--[[===========================================================================
Battleplan — Turn Token Script (Game Manager w/ External AI Token)
===============================================================================
• Context menu: Start Game, Next, Logs On/Off, Dump State, Reset Board,
  Reset Match History, AI Difficulty (1–5)
• Left-click token = Next     • ALT+Left-click = Start (if waiting) / Reset
• Start flow:
    1) Shuffle buff deck
    2) Randomize buff token (re-roll if rank 1/8)
    3) Deal 2 buffs to P2 AND 2 buffs to P1 (White)
    4) Roll & compare dice for initiative
    5) Enter Piece placement
• Phases: Waiting → Piece placement → plan → Battle Phase → (repeat) / Game Over

This Game Token script manages everything EXCEPT the AI’s decision-making. It
delegates to an external AI token via AI_Request, passing:
  { type="Placement|plan|Action|Flag", status=<object> }
…where status includes dice, piece and token locations, stacks, buffs, flags,
budgets, and meta info including difficulty (1..5).

AI Token GUID used: 773b16

NOTE (Flags & AI):
  • The AI reads ONLY what we send it. This script derives flag/shield state
    directly from the piece objects (by detecting the badge buttons with
    tooltips "FlagMarkerPanel" and "ShieldMarkerPanel") and includes both
    `pieces[*].hasFlag/hasShield` and convenience `flags`/`shields` maps in the
    status payload. No external/global flag state is used by the AI.
  • Keep the Player-piece script’s top “Toggle flag” menu as-is; the badge
    presence is what we read here to form the status.
===============================================================================]]

--=============================================================================
--== [0] LOGGING / PLAYER MESSAGES ===========================================
--=============================================================================
local LOG_MATCH_HISTORY = false   -- simple snapshots (T1: (…))
local LOG_TURNLOG       = false   -- full detailed RR_AI.TurnLog
local LOG_ON = false                 -- general logging
local LOG_Decision_Debugging_ON = false
local LOG_AI_WIRE_ON = false         -- wire log on/off (concise)
local LOG_AI_WIRE_VERBOSE = false    -- if true, dumps full JSON too
local PLAYER_MSG_ON = true
local DEBUG_MENUS_ON = false         -- set true to show debug-only menu items
local SCHEMA_VERSION = 3


-- send TurnToken logs to chat instead of console
local CHAT_RGB = {1,1,1}  -- white text in chat
local function _RAWPRINT(msg)
  broadcastToAll("[TurnToken] "..tostring(msg), CHAT_RGB)
end

local function LOG(msg) if LOG_ON then _RAWPRINT(msg) end end
local function LOGF(fmt, ...) if LOG_ON then _RAWPRINT(string.format(fmt, ...)) end end
local function DECLOG(msg) if LOG_Decision_Debugging_ON then _RAWPRINT(msg) end end
local function DECLOGF(fmt, ...) if LOG_Decision_Debugging_ON then _RAWPRINT(string.format(fmt, ...)) end end
local function PMSG(msg) if PLAYER_MSG_ON and msg and msg~="" then _RAWPRINT(msg) end end
local function PMSG_P1_TURN(msg) if PLAYER_MSG_ON then _RAWPRINT(tostring(msg).." Player 1's Turn, press when done.") end end
local function PMSG_NEXT_ROUND(msg)
  if PLAYER_MSG_ON then broadcastToAll(tostring(msg).." Press for next round.", {0,1,0}) end
end

-- forward declarations for functions referenced by onLoad
local addMenus, addClickButtons
local setCueTint, setSelfHighlight
local function _setLastSummary(msg) local ST=S(); ST.lastEventSummary=msg end


--=============================================================================
--== [1] STATE / SAVE-LOAD / GLOBAL BRIDGES ==================================
--=============================================================================
local T = nil
local function defaults()
  return {
    phase            = "Waiting_To_Start_Game",
    round            = 1,
    firstPlayer      = 1,      -- 1=P1, 2=P2
    currentTurn      = 1,
    lastMover        = nil,

    -- placement/prep counters
    p2PlacementIdx   = 0,
    p1PlacementCnt   = 0,
    p2PrepIdx        = 0,
    p1PrepCnt        = 0,

    revealBudget     = { P1=0, P2=0 },

    -- dice/counters
    diceValues       = {0,0,0},
    diceTotal        = 0,
    remainingActions = 0,

    -- action cursors and buff usage for P2
    revealCursor     = { Blue=1, Pink=1, Purple=1 },
    revealTurnCursor = 1,
    buffUsed         = { Blue=false, Pink=false, Purple=false },

    -- NEW: P1 reveal color round-robin cursor (for auto-reveals)
    p1RevealTurnCursor = 1,

    awaitingEndClick = false,  -- pause at end of Action until Player clicks

    difficulty       = 5,      -- 1..5
    aiLog            = { rounds = {}, startedAt = os.time and os.time() or nil },
    lastEventSummary = nil,
        rng              = { P2 = nil },   -- persistent per-game random seed(s)

  }
end

function S()
  if type(T)~="table" then T=defaults() end
  T.diceValues       = (type(T.diceValues)=="table") and T.diceValues or {0,0,0}
  T.revealCursor     = T.revealCursor or { Blue=1, Pink=1, Purple=1 }
  T.buffUsed         = T.buffUsed or { Blue=false, Pink=false, Purple=false }
  T.revealBudget     = T.revealBudget or { P1=0, P2=0 }
  T.awaitingEndClick = (T.awaitingEndClick == true)
  if type(T.difficulty) ~= "number" then T.difficulty = 3 end
  if type(T.p1RevealTurnCursor) ~= "number" then T.p1RevealTurnCursor = 1 end
    T.rng = T.rng or { P2 = nil }

  return T
end

local function dumpState()
  local ST=S()
  return string.format(
    "phase=%s | round=%d | firstPlayer=%d | currentTurn=%d | p2Place=%d/3 | p1Place=%d/3 | p2Prep=%d/3 | p1Prep=%d/3 | dice={%s,%s,%s} total=%d | budgets={P1=%d,P2=%d} | diff=%d",
    tostring(ST.phase), ST.round, ST.firstPlayer, ST.currentTurn,
    ST.p2PlacementIdx, ST.p1PlacementCnt, ST.p2PrepIdx, ST.p1PrepCnt,
    tostring(ST.diceValues[1]), tostring(ST.diceValues[2]), tostring(ST.diceValues[3]),
    ST.diceTotal, (ST.revealBudget.P1 or 0), (ST.revealBudget.P2 or 0), ST.difficulty
  )
end

-- Feature flag reader
local function globalSaveEnabled()
  local v = Global.getVar("SAVE_STATE")
  return (type(v)=="boolean") and v or false
end

function onSave()
  if not globalSaveEnabled() then
    LOG("onSave(): skipping (SAVE_STATE is false/missing).")
    return ""
  end
  LOG("onSave() -> "..dumpState())
  return JSON.encode(S())
end

function onLoad(saved)
  LOG("onLoad()")
  if globalSaveEnabled() and saved and saved~="" then
    local ok, data = pcall(JSON.decode, saved)
    if ok and type(data)=="table" then T=data else T=defaults() end
  else
    T = defaults()
  end

  -- Ensure default AI GUID first, then let Global override if valid
  if type(AI_GUID)~="string" or AI_GUID=="" then AI_GUID = "773b16" end
  local g = Global.getVar("RR_AI_GUID")
  if type(g)=="string" and #g>0 and getObjectFromGUID(g) ~= nil then
    AI_GUID = g
  elseif type(g)=="string" and #g>0 then
    _RAWPRINT("Ignoring invalid RR_AI_GUID = "..tostring(g).."; using default "..tostring(AI_GUID))
  end

  -- Mirror difficulty for other objects
  Global.setVar("AI_DIFFICULTY", S().difficulty)

  addMenus()
  addClickButtons()

  -- Clear any stale “press Next” cues/highlights on load
  setSelfHighlight(false)
  if setCueTint then setCueTint(false) end
end

--== GLOBAL JSON bridges ======================================================
local RR_CONST = nil
local function G_const()
  if not RR_CONST then
    local s = Global.call("RR_const_JSON")
    local ok, data = pcall(JSON.decode, s or "")
    RR_CONST = (ok and type(data)=="table") and data or {}
    _RAWPRINT("G_const(): loaded via JSON")
  end
  return RR_CONST
end

local function W_read()
  local s = Global.call("RR_Read_All_JSON")
  local ok, W = pcall(JSON.decode, s or "")
  W = (ok and type(W)=="table") and W or {}
  LOGF("W_read(): dice={%s,%s,%s} game_state=%s initiative=%s",
       tostring(W.dice and W.dice[1]), tostring(W.dice and W.dice[2]), tostring(W.dice and W.dice[3]),
       tostring(W.game_state), tostring(W.initiative))
  return W
end

local function P2_STACKS()
  local s = Global.call("RR_GetStacksP2_JSON")
  local ok, t = pcall(JSON.decode, s or "")
  if ok and type(t)=="table" then return t end
  _RAWPRINT("RR_STACKS_P2 missing/invalid.")
  return {}
end

--=============================================================================
--== [2] UTILITIES (phase set, initiative, dice, stacks, buff/action utils) ==
--=============================================================================

-- Robust wrapper: uses the same mover the reset uses.
local function _rrMoveToSquare(guid, square)
  -- Try positional arg shape
  local ok = pcall(function() Global.call("RR_MovePieceToSquare", { guid, square }) end)
  if not ok then
    -- Fallback to named-keys shape
    pcall(function() Global.call("RR_MovePieceToSquare", { guid=guid, square=square }) end)
  end
end

-- Upright a piece by color before moving it.
local function _uprightPieceByColor(color)
  local g = (G_const().RR.PIECES or {})[color]
  local o = g and getObjectFromGUID(g) or nil
  if not o then return end
  pcall(function()
    o.setLock(false)
    o.setAngularVelocity({0,0,0}); o.setVelocity({0,0,0})
    o.setRotationSmooth({0,180,0}, false, true)
  end)
end

-- New unified sendHomeAndClear
local function _sendHomeAndClear(colorKey)
  local guid = (G_const().RR.PIECES or {})[colorKey]
  local piece = guid and getObjectFromGUID(guid) or nil
  if not piece then return end

  -- Try to find a snap point tagged with this colorKey
  local targetPos = nil
  if piece.getSnapPoints then
    local wantTag = string.lower(colorKey or "")
    for _, sp in ipairs(piece.getSnapPoints() or {}) do
      for _, t in ipairs(sp.tags or {}) do
        if string.lower(t or "") == wantTag then
          targetPos = piece.positionToWorld(sp.position)
          break
        end
      end
      if targetPos then break end
    end
  end

  -- Reset physics & rotation
  piece.setLock(false)
  piece.setVelocity({0,0,0})
  piece.setAngularVelocity({0,0,0})
  piece.setRotationSmooth({0,180,0}, false, true)

  if targetPos then
    piece.setPositionSmooth({targetPos.x, targetPos.y + 1.0, targetPos.z}, false, true)
  else
    local ok = pcall(function() Global.call("RR_MovePieceToSquare", { guid=guid, square="HOME" }) end)
    if not ok then piece.setPosition({0,3,0}) end
  end

  -- Clear state markers
  pcall(function() piece.call("clearFlag") end)
  pcall(function() piece.call("clearShield") end)
  RR_RemoveFlag(colorKey)
  RR_ClearShield(colorKey)
end

-- ======= Token tint cue (P1 press Next) =======
local GREEN_TINT  = {r=0.10, g=0.80, b=0.20}
local NO_TINT     = {r=1,    g=1,    b=1}

local function _selectedTokenGUIDs()
  return {"a9c4f3"} -- if you ever want to cue the AI token instead, return {"773b16"}
end

function setCueTint(on)
  for _,gid in ipairs(_selectedTokenGUIDs()) do
    local o=getObjectFromGUID(gid)
    if o and o.setColorTint then
      pcall(function() o.setColorTint(on and GREEN_TINT or NO_TINT) end)
    end
  end
end

-- === Turn Token self highlight ===
local SELF_GREEN = {r=0.10, g=0.80, b=0.20}
local SELF_CLEAR = {r=1, g=1, b=1}
function setSelfHighlight(on)
  if self and self.setColorTint then self.setColorTint(on and SELF_GREEN or SELF_CLEAR) end
end

-- Bridge for attacks (always delegate to Global)
function RR_ResolveAttack(args)
  if not args or not args.attacker or not args.square then return end
  pcall(function() Global.call("RR_ResolveAttackFromSquare", args) end)
end

-- Track flag carriers locally too (helpers)
FLAG_CARRIER = { P1=nil, P2=nil }

function RR_GiveFlag(color)
  local piece = getObjectFromGUID((G_const().RR.PIECES or {})[color] or "")
  if not piece then return end
  if color=="Blue" or color=="Pink" or color=="Purple" then
    if FLAG_CARRIER.P2 then return end; FLAG_CARRIER.P2=color
  else
    if FLAG_CARRIER.P1 then return end; FLAG_CARRIER.P1=color
  end
  piece.call("setFlag", true)
end

function RR_RemoveFlag(color)
  local piece = getObjectFromGUID((G_const().RR.PIECES or {})[color] or "")
  if piece then piece.call("setFlag", false) end
  if color=="Blue" or color=="Pink" or color=="Purple" then
    if FLAG_CARRIER.P2==color then FLAG_CARRIER.P2=nil end
  else
    if FLAG_CARRIER.P1==color then FLAG_CARRIER.P1=nil end
  end
end

-- Shield bridge (call the pawn’s API)
function RR_SetShield(color, on)
  local guid = (G_const().RR.PIECES or {})[color]
  local piece = guid and getObjectFromGUID(guid) or nil
  if piece then piece.call("setShield", on and true or false) end
end

function RR_ClearShield(color)
  local guid = (G_const().RR.PIECES or {})[color]
  local piece = guid and getObjectFromGUID(guid) or nil
  if piece then piece.call("clearShield") end
end

local function ensureFlagCarriersSafe()
  local fn = Global.getVar("RR_EnsureFlagCarriers")
  if type(fn)=="function" then local ok,err=pcall(fn); if not ok then LOG("EnsureFlagCarriers threw: "..tostring(err)) end end
end

local function setPhase(phase)
  local ST=S()
  LOGF("setPhase(%s) — from %s", tostring(phase), tostring(ST.phase))
  ST.phase = phase
  Global.call("RR_SetGameState", phase)
  self.setName("Turn Token — "..phase)
  if addClickButtons then addClickButtons() end
end

local function setInitiative(who)
  who = (who==2) and 2 or 1
  local newWho = who
  local ok, res = pcall(function() return Global.call("RR_SetInitiative_JSON", who) end)
  if ok and type(res)=="string" and #res>0 then
    local ok2, W = pcall(JSON.decode, res)
    if ok2 and type(W)=="table" and (W.initiative==1 or W.initiative==2) then newWho=W.initiative end
  end
  S().firstPlayer = newWho
  return newWho
end

local function sumDice(d)
  local a=tonumber(d[1] or 0) or 0; local b=tonumber(d[2] or 0) or 0; local c=tonumber(d[3] or 0) or 0
  return a+b+c
end

local function getP2StackForColor(color)
  local stacks = P2_STACKS()
  local list = stacks[color] or stacks[string.upper(color or "")] or stacks[string.lower(color or "")]
  if type(list)~="table" then LOGF("getP2StackForColor(%s): NOT FOUND", tostring(color)); return {} end
  LOGF("getP2StackForColor(%s): %d guids", tostring(color), #list)
  return list
end

-- Buff / action utilities
local function dealBuffToSeat(seat, n)
  n = tonumber(n or 1) or 1
  for _=1,n do
    if seat=="White" then pcall(function() Global.call("RR_DealBuff_P1") end)
    else pcall(function() Global.call("RR_DealBuff") end) end
  end
end

function RR_P2_SetTopNMovesForColor(color, n)
  LOGF("RR_P2_SetTopNMovesForColor(color=%s, n=%s)", tostring(color), tostring(n))
  local guids = getP2StackForColor(color)
  if not guids or #guids==0 then LOG("… no guids; abort setTopN."); return false end

  local function noteGet(obj, key)
    local s = obj.getGMNotes() or ""
    local pat = "%["..key:gsub("(%W)","%%%1")..":([^%]]+)%]"
    return s:match(pat)
  end
  local function noteSet(obj, key, value)
    local s = obj.getGMNotes() or ""
    local pat = "%["..key:gsub("(%W)","%%%1")..":[^%]]+%]"
    if s:find(pat) then s = s:gsub(pat, "["..key..":"..value.."]", 1)
    else s = (s~="" and s.."\n" or "").."["..key..":"..value.."]" end
    obj.setGMNotes(s)
  end
  local function refreshCard(o)
    pcall(function() o.call("enforceVisibility") end)
    pcall(function() o.call("applyFaceForState") end)
    pcall(function() o.call("addMenu") end)
  end

  local changed=false
  for i=1, math.min(6, #guids) do
    local card=getObjectFromGUID(guids[i])
    if card and card.tag=="Card" then
      local want=(i <= (n or 0)) and "MOVE" or "BLANK"
      local cur=(noteGet(card,"FaceKind") or "ACTION")
      if cur~=want then noteSet(card, "FaceKind", want); changed=true end
      if noteGet(card,"Revealed")~="0" then noteSet(card,"Revealed","0") end
      refreshCard(card)
    end
  end
  LOGF("RR_P2_SetTopNMovesForColor done. changed=%s", tostring(changed))
  return changed
end

function RR_P2_RevealNextForColor(color)
  LOGF("RR_P2_RevealNextForColor(color=%s)", tostring(color))
  local guids = getP2StackForColor(color)
  if not guids or #guids==0 then LOG("… no guids; cannot reveal."); return false end

  local function noteGet(obj, key)
    local s=obj.getGMNotes() or ""
    local pat="%["..key:gsub("(%W)","%%%1")..":([^%]]+)%]"
    return s:match(pat)
  end
  local function refreshCard(o)
    pcall(function() o.setLock(false) end)
    pcall(function() o.flip() end)
    pcall(function() o.call("applyFaceForState") end)
    pcall(function() o.call("addMenu") end)
  end

  for i=1, math.min(6, #guids) do
    local card=getObjectFromGUID(guids[i])
    if card and card.tag=="Card" then
      local revealed = (noteGet(card,"Revealed")=="1")
      local kind = (noteGet(card,"FaceKind") or "ACTION"):upper()
      local isBlank = (kind=="ACTION" or kind=="BLANK")
      LOGF("  slot %d: kind=%s revealed=%s blank=%s", i, tostring(kind), tostring(revealed), tostring(isBlank))
      if (not revealed) and (not isBlank) then
        local s=card.getGMNotes() or ""
        if not s:find("%[Revealed:1%]") then
          if s:find("%[Revealed:[^%]]+%]") then s=s:gsub("%[Revealed:[^%]]+%]","[Revealed:1]",1)
          else s=(s~="" and s.."\n" or "").."[Revealed:1]" end
          card.setGMNotes(s)
        end
        refreshCard(card)
        LOGF("  slot %d: REVEALED (%s)", i, tostring(kind))
        return true, kind
      end
    end
  end
  LOG("No non-blank, unrevealed actions left for "..tostring(color))
  return false, nil
end

--=============================================================================
--== [3] MENUS & BUTTONS ======================================================
--=============================================================================
local function onMenuDumpState(_,_) LOG("=== Dump State ==="); LOG(dumpState()); local W=W_read(); LOGF("World.game_state=%s | initiative=%s | dice={%s,%s,%s}", tostring(W.game_state), tostring(W.initiative), tostring(W.dice and W.dice[1]), tostring(W.dice and W.dice[2]), tostring(W.dice and W.dice[3])) end
local function safeAddMenu(label, fn) pcall(function() self.addContextMenuItem(label, fn) end) end
local function onMenuToggleLogs(_,_) LOG_ON = not LOG_ON; _RAWPRINT("Logs are now "..(LOG_ON and "ON" or "OFF")); addMenus() end

local function _setDifficulty(n)
  local v = math.max(1, math.min(5, tonumber(n) or 3))
  S().difficulty = v
  Global.setVar("AI_DIFFICULTY", v)
  _RAWPRINT("AI Difficulty set to "..v)
  addMenus()
end
function onMenuDiff1(_,_) _setDifficulty(1) end
function onMenuDiff2(_,_) _setDifficulty(2) end
function onMenuDiff3(_,_) _setDifficulty(3) end
function onMenuDiff4(_,_) _setDifficulty(4) end
function onMenuDiff5(_,_) _setDifficulty(5) end

function addMenus()
  self.clearContextMenu()

  safeAddMenu("Reset Board", onMenuResetBoard)
  safeAddMenu("Start Game", onMenuStartGame)
  safeAddMenu("Next", onMenuNext)
  

  safeAddMenu("Logs: "..(LOG_ON and "On" or "Off"), onMenuToggleLogs)
  safeAddMenu("Dump State", onMenuDumpState)
  safeAddMenu("Reset Match History", onMenuResetHistory)
  safeAddMenu("Export Match (Simple)", onMenuCopyMatch)

  if DEBUG_MENUS_ON then safeAddMenu("Notebook Self-Test", onMenuNotebookSelfTest) end
  local st=S()
  safeAddMenu("AI Difficulty: 1"..(st.difficulty==1 and " ✓" or ""), onMenuDiff1)
  safeAddMenu("AI Difficulty: 2"..(st.difficulty==2 and " ✓" or ""), onMenuDiff2)
  safeAddMenu("AI Difficulty: 3"..(st.difficulty==3 and " ✓" or ""), onMenuDiff3)
  safeAddMenu("AI Difficulty: 4"..(st.difficulty==4 and " ✓" or ""), onMenuDiff4)
  safeAddMenu("AI Difficulty: 5"..(st.difficulty==5 and " ✓" or ""), onMenuDiff5)
  LOG("Context menus added.")
end

function addClickButtons()
  for _,b in ipairs(self.getButtons() or {}) do pcall(function() self.removeButton(b.index) end) end
  local isWaiting = (S().phase=="Waiting_To_Start_Game")
  self.createButton({
    click_function = "onBtnMain",
    function_owner = self,
    label          = isWaiting and "Start ▶" or "Next ▶",
    position       = {0,0.25,0},
    rotation       = {0,180,0},
    width          = 1400,
    height         = 1400,
    font_size      = 300,
    color          = {0,0,0,0},
    font_color     = {1,1,1,1},
    tooltip        = isWaiting and "Click to Start Game" or "Click for Next",
  })
end

function onBtnNext(_,_) onMenuNext(nil,nil) end
function onBtnMain(_, _playerColor, _altClick)
  if S().phase=="Waiting_To_Start_Game" then
    _RAWPRINT("Click → Start Game")
    onMenuStartGame(nil, nil)
  else
    onMenuNext(nil, nil)
  end
end

function onMenuResetBoard(_, _)
  _RAWPRINT("Reset Board…")
  local ok, err = pcall(function() Global.call("Reset_Board") end)
  if not ok then _RAWPRINT("Reset_Board failed: "..tostring(err)) end

  -- Clear all pawn flags/shields by calling their own API
  for _,o in ipairs(getAllObjects()) do
    if o.getVar and o.getVar("clearFlag") then
      pcall(function() o.call("clearFlag") end)
    elseif o.getVar and o.getVar("setFlag") then
      pcall(function() o.call("setFlag", false) end)
    end
    if o.getVar and o.getVar("clearShield") then pcall(function() o.call("clearShield") end) end
  end

  -- Clear the current match notebook page too (if your global implements it)
  pcall(RR_Notebook_ClearCurrentMatch)

  FLAG_CARRIER = { P1=nil, P2=nil }
  T = defaults()
  setPhase("Waiting_To_Start_Game")
  addMenus()

  -- Also clear the visual cues
  setSelfHighlight(false)
  if setCueTint then setCueTint(false) end
end

--=============================================================================
--== [4] START / INITIATIVE / AUTO-ADVANCE ===================================
--=============================================================================
local function ensureBuffTokenNotEdge(cb, tries)
  tries = tries or 12
  LOGF("ensureBuffTokenNotEdge(tries=%d)", tries)
  if tries <= 0 then if cb then cb() end; return end
  local RR = G_const().RR
  local tok = getObjectFromGUID(RR.TOKEN)
  if not tok then if cb then cb() end; return end
  tok.call("randomizePosition")
  Wait.time(function()
    local W = W_read()
    local sq = (W.buff_token or {}).square
    local rank = tonumber(string.match(sq or "", "%d+"))
    if rank == 1 or rank == 8 then ensureBuffTokenNotEdge(cb, tries-1) else if cb then cb() end end
  end, 0.7)
end

local function decideInitiative(cb)
  LOG("decideInitiative()")
  local tieCount, repeatCount, lastP2 = 0, 0, nil
  local function readTotal()
    local W = W_read()
    local ST = S()
    ST.diceValues = W.dice or {0,0,0}
    return sumDice(ST.diceValues)
  end
  local function roll(label, afterSec, onDone)
    pcall(function() Global.call("RR_RollGameDice") end)
    Wait.time(function()
      local tot=readTotal()
      local ST=S()
      LOGF("  %s total=%d (dice={%s,%s,%s})", label, tot, tostring(ST.diceValues[1]), tostring(ST.diceValues[2]), tostring(ST.diceValues[3]))
      onDone(tot)
    end, afterSec or 1.0)
  end
  local function startRound()
    roll("Player 1", 1.0, function(p1)
      roll("Computer", 1.0, function(p2)
        local whoFirst
        if lastP2 ~= nil and p2 == lastP2 then
          repeatCount = repeatCount + 1
          if repeatCount >= 5 then whoFirst=1 else lastP2=p2; return startRound() end
        elseif p1 == p2 then
          tieCount = tieCount + 1
          if tieCount >= 5 then whoFirst=1 else lastP2=p2; return startRound() end
        else
          whoFirst = (p1 > p2) and 1 or 2
          lastP2 = p2
        end
        local first=setInitiative(whoFirst)
        local ST=S(); ST.currentTurn=(first==2) and 2 or 1
        if cb then cb() end
      end)
    end)
  end
  startRound()
end

local function maybeAutoAdvanceForComputer()
  local st=S()
  if st.currentTurn==2 and st.awaitingEndClick~=true and st.phase~="Waiting_To_Start_Game" then
    Wait.time(function()
      local s2=S()
      if s2.currentTurn==2 and s2.awaitingEndClick~=true and s2.phase~="Waiting_To_Start_Game" then onMenuNext(nil,nil) end
    end, 0.25)
  end
end

function onMenuStartGame(_, _)
  -- turn off any lingering highlights at the start of a new match
  setSelfHighlight(false)
  if setCueTint then setCueTint(false) end
  if RR_AI and RR_AI.TurnLog and type(RR_AI.TurnLog.Clear)=="function" then RR_AI.TurnLog.Clear() end

  _ensureP2Seed()  -- make sure P2's seed is fixed for the entire match


  local ST=S()
  if ST.phase~="Waiting_To_Start_Game" then return end
  pcall(function() Global.call("RR_ShuffleBuffDeck") end)
  ensureBuffTokenNotEdge(function()
    dealBuffToSeat((G_const().RR or {}).PLAYER2 or "Blue", 2)
    dealBuffToSeat("White", 2)
    decideInitiative(function()
      setPhase("Piece placement")
      local S1=S()
      S1.p2PlacementIdx=0; S1.p1PlacementCnt=0
      S1.p2PrepIdx=0; S1.p1PrepCnt=0
      S1.revealCursor={ Blue=1, Pink=1, Purple=1 }

      broadcastToAll("AI Difficulty: "..tostring(S1.difficulty or 3), {0,0.5,1})
      broadcastToAll(
        string.format("Placement Phase: %s places first.",
          (S1.firstPlayer==1 and "Player 1 (White)" or "Computer")),
        {0,1,0}
      )
      maybeAutoAdvanceForComputer()
    end)
  end)
end

--=============================================================================
--== [5] FLOW: NEXT (PHASE PROGRESSION + END-OF-ROUND) =======================
--=============================================================================
RR_AI = RR_AI or {}; RR_AI.TurnLog = RR_AI.TurnLog or {}
local function _logSafe(name, payload)
  if not LOG_TURNLOG then return end
  local t = RR_AI and RR_AI.TurnLog
  local f = t and t[name]
  if type(f) == "function" then
    if payload ~= nil then return f(payload) else return f() end
  end
end


-- Defensive respawn helpers
local function _defenseRankFor(color) return (color=="Blue" or color=="Pink" or color=="Purple") and 8 or 1 end
local function _freeSquareOnRank(rank, occ, side)
  local A = string.byte("A")
  if side == 2 then
    for f=8,1,-1 do local sq = string.char(A+f-1)..tostring(rank); if not occ[sq] then return sq end end
  else
    for f=1,8 do local sq = string.char(A+f-1)..tostring(rank); if not occ[sq] then return sq end end
  end
  return nil
end

local function _respawnHomesToDefenseZones()
  local W=W_read() or {}
  local pieces=W.pieces or {}
  local occ={}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    local e=pieces[c]
    if e and e.loc=="BOARD" and e.square then occ[e.square]=true end
  end
  local RR=(G_const().RR or {})
  local movedList={}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    local e=pieces[c] or {}
    local atHome=(e.loc~="BOARD")
    if atHome then
      local side = (c=="Blue" or c=="Pink" or c=="Purple") and 2 or 1
      local targetSq = _freeSquareOnRank(_defenseRankFor(c), occ, side)
      local guid=RR.PIECES and RR.PIECES[c] or nil
      if targetSq and guid then
        pcall(function() Global.call("RR_MovePieceToSquare", { guid, targetSq }) end)
        occ[targetSq]=true
        movedList[#movedList+1]=c.."→"..targetSq
      end
    end
  end
  if #movedList>0 then PMSG("Respawned to DZ: "..table.concat(movedList, ", ")); _setLastSummary("Respawned to DZ: "..table.concat(movedList, ", ")) end
end

-- Buff recollection helpers
local _BUFF_TAGS = { ["Extra Move"]=true, ["Extra Attack"]=true, ["Extra Defend"]=true, ["Diagonal Move"]=true }
-- Map a card object -> canonical buff name or nil
local function _buffNameFromCard(o)
  if not o or o.tag ~= "Card" then return nil end
  local tags = o.getTags() or {}
  for _,t in ipairs(tags) do if _BUFF_TAGS[t] then return t end end
  local nm = (o.getName and o.getName()) or ""
  if _BUFF_TAGS[nm] then return nm end
  local notes = (o.getGMNotes and o.getGMNotes()) or ""
  for k,_ in pairs(_BUFF_TAGS) do if notes:find(k, 1, true) then return k end end
  return nil
end

-- List all buff cards in a seat's hand as { guid, name }
local function _buffHandListForSeat(seat)
  local out = {}
  local ok, objs = pcall(function() return Player[seat] and Player[seat].getHandObjects() or {} end)
  if not ok then return out end
  for _,o in ipairs(objs) do
    local name = _buffNameFromCard(o)
    if name then out[#out+1] = { guid=o.getGUID(), name=name } end
  end
  return out
end

local function _gatherHandGuids()
  local G={}
  for _,p in pairs(Player.getPlayers() or {}) do
    for _,o in ipairs(p.getHandObjects() or {}) do if o and o.tag=="Card" then G[o.getGUID()]=true end end
  end
  return G
end
local function _findBuffZonePos(color)
  local want=string.lower((color or "").." buff")
  for _,obj in ipairs(getAllObjects()) do
    if obj.getSnapPoints then
      for _,sp in ipairs(obj.getSnapPoints() or {}) do
        for _,t in ipairs(sp.tags or {}) do
          if string.lower(t)==want then local pos=obj.positionToWorld(sp.position); return {x=pos.x,y=pos.y,z=pos.z} end
        end
      end
    end
  end
  return nil
end
local function _nearestBuffCardTo(pos, excludeGuids)
  local nearest, best
  for _,o in ipairs(getAllObjects()) do
    if o.tag=="Card" then
      local guid=o.getGUID()
      if not (o.held_by_color and o.held_by_color~="") then
        if not (excludeGuids and excludeGuids[guid]) then
          local tags=o.getTags() or {}
          local isBuff=false
          for _,t in ipairs(tags) do if _BUFF_TAGS[t] then isBuff=true break end end
          if isBuff then
            o.setLock(false); o.setVelocity({0,0,0}); o.setAngularVelocity({0,0,0})
            local p=o.getPosition()
            local d=(p.x-pos.x)^2 + (p.z-pos.z)^2
            if not best or d<best then nearest,best=o,d end
          end
        end
      end
    end
  end
  return nearest
end

local function _findBuffDeck()
  local ok,res = pcall(function() return Global.call("RR_FindBuffDeck") end)
  return ok and res or nil
end

local function _ensureCardFlat(card, wantFace)  -- wantFace: "down"|"up"|nil
  if not card then return end
  pcall(function()
    card.setLock(false)
    card.setVelocity({0,0,0}); card.setAngularVelocity({0,0,0})
    if wantFace == "down" and not card.is_face_down then card.flip() end
    if wantFace == "up"   and card.is_face_down   then card.flip() end
  end)
end

local function _squareUpBuffInZone(color, wantFace)
  local pos = _findBuffZonePos(color); if not pos then return end
  local card = _nearestBuffCardTo(pos, _gatherHandGuids()); if not card then return end
  _ensureCardFlat(card, wantFace or "down")
  card.setRotation({0,180,0})
  card.setLock(false)
  card.setPositionSmooth({pos.x, pos.y+0.02, pos.z}, false, true)
end

-- Place a specific card (by GUID) from hand into the color's buff zone, face-down
local function _placeBuffFromHandToZone(cardGuid, color)
  if not cardGuid or not color then return false end
  local card = getObjectFromGUID(cardGuid); if not card then return false end
  local pos  = _findBuffZonePos(color);     if not pos  then return false end
  local name = _buffNameFromCard(card);     if not name then return false end
  card.setLock(false)
  _ensureCardFlat(card, "down")
  card.setRotation({0,180,0})
  card.setPositionSmooth({pos.x, pos.y+0.02, pos.z}, false, true)
  return true
end

-- Flip the buff card in the assigned zone using your Global function
local function _flipBuffZone(color)
  pcall(function() Global.call("RR_FlipBuffAt", color) end)
end



local function _revealAndReturnBuff(color)
  local pos = _findBuffZonePos(color); if not pos then return end
  local card = _nearestBuffCardTo(pos, _gatherHandGuids()); if not card then return end
  _ensureCardFlat(card, "up")
  card.setLock(false)
  Wait.time(function()
    local deck = _findBuffDeck()
    if deck and deck.tag=="Deck" and (not deck.held_by_color or deck.held_by_color=="") then
      deck.setLock(false)
      pcall(function() deck.putObject(card) end)
      pcall(function() deck.shuffle() end)
      deck.setLock(true)
    else
      local dp = deck and deck.getPosition() or nil
      if dp then card.setPositionSmooth({dp.x, dp.y+2.0, dp.z}, false, true) end
      Wait.time(function()
        local d2=_findBuffDeck(); if d2 and d2.tag=="Deck" then pcall(function() d2.shuffle() end) end
      end, 0.3)
    end
  end, 0.25)
end

-- Consume a hand card: flip up and return to deck
local function _consumeBuffCard(card)
  if not card then return end
  _ensureCardFlat(card, "up")
  local deck = _findBuffDeck()
  if deck and deck.tag=="Deck" and (not deck.held_by_color or deck.held_by_color=="") then
    deck.setLock(false)
    pcall(function() deck.putObject(card) end)
    pcall(function() deck.shuffle() end)
    deck.setLock(true)
  end
end


local function _collectBuffZonesToDeck()
  LOG("[EndRound] Collecting buff-zone cards to deck (excluding hand cards)…")

  -- Build a GUID set of everything in player hands (plus anything actively held)
  local inHandList = (_gatherHandGuids and _gatherHandGuids()) or {}
  local inHandSet = {}
  if type(inHandList) == "table" then
    for _,g in ipairs(inHandList) do inHandSet[g] = true end
  end
  if Player and Player.getPlayers then
    for _,p in ipairs(Player.getPlayers()) do
      local objs = p.getHandObjects and p.getHandObjects() or {}
      for _,o in ipairs(objs) do inHandSet[o.getGUID()] = true end
    end
  end
  local function isInHands(obj)
    if not obj then return false end
    if obj.held_by_color and obj.held_by_color ~= "" then return true end
    return inHandSet[obj.getGUID()] == true
  end

  -- Find deck + target position
  local deck = nil
  local ok,res = pcall(function() return Global.call("RR_FindBuffDeck") end)
  if ok then deck = res end
  local deckPos = deck and deck.getPosition() or nil

  -- Helper: nearest buff card to a zone, but only if it’s close AND not in hands
  local RADIUS = 4.0 -- table-units around the zone; keeps distant hand cards safe
  local function pick_zone_card(zonePos)
    if not zonePos then return nil end
    local obj = _nearestBuffCardTo and _nearestBuffCardTo(zonePos, inHandList) or nil
    if not obj then return nil end
    if isInHands(obj) then return nil end
    local p = obj.getPosition()
    local dx, dz = (p.x - zonePos.x), (p.z - zonePos.z)  -- ignore Y for planar distance
    if (dx*dx + dz*dz) > (RADIUS * RADIUS) then return nil end
    return obj
  end

  -- If state is available, only try zones that actually have an assigned (unrevealed) buff
  local ST = (type(S)=="function") and S() or nil
  local zones    = ST and ST.buffs and ST.buffs.zones or nil
  local zstatus  = ST and ST.buffs and ST.buffs.zoneStatus or nil
  local function zone_has_unrevealed(color)
    if not zones or not zstatus then return true end -- fallback: behave like previous logic
    local a = zones[color] or "None"
    local s = zstatus[color] or "None"
    return (a ~= "None") and (s ~= "Revealed")
  end

  local colors = {"Blue","Pink","Purple","Green","Yellow","Orange"}
  for _,c in ipairs(colors) do
    if zone_has_unrevealed(c) then
      local z = _findBuffZonePos and _findBuffZonePos(c) or nil
      if z then
        local card = pick_zone_card(z)
        if card then
          card.setLock(false)
          card.setVelocity({0,0,0})
          card.setAngularVelocity({0,0,0})
          card.setRotation({0,180,0})
          if deck and deck.tag=="Deck" and (not deck.held_by_color or deck.held_by_color=="") then
            deck.setLock(false)
            pcall(function() deck.putObject(card) end)
          elseif deckPos then
            card.setPosition({x=deckPos.x, y=deckPos.y+3.0, z=deckPos.z})
          end
        end
      end
    end
  end

  Wait.time(function()
    local d = deck
    local ok2,res2 = pcall(function() return Global.call("RR_FindBuffDeck") end)
    if ok2 and res2 then d = res2 end
    if not d then return end
    d.setLock(false)
    if d.tag == "Deck" then d.shuffle(); d.setName("Buff Deck") end
  end, 0.8)
end


local function _resetP1_ActionCards()
  LOG("[EndRound] Resetting Player 1 action cards…")
  local function _hasTag(o,wanted) wanted=string.lower(wanted or ""); for _,t in ipairs(o.getTags() or {}) do if string.lower(t)==wanted then return true end end return false end
  local function _setNoteStr(s,key,val)
    local pat = "%["..key:gsub("(%W)","%%%1")..":[^%]]+%]"
    if s:find(pat) then return s:gsub(pat,"["..key..":"..val.."]",1) else return (s~="" and s.."\n" or "").."["..key..":"..val.."]" end
  end
  for _,o in ipairs(getAllObjects()) do
    if o.tag=="Card" and _hasTag(o, "Player 1") then
      local s=o.getGMNotes() or ""
      s=_setNoteStr(s,"Revealed","0"); s=_setNoteStr(s,"FaceKind","ACTION"); s=_setNoteStr(s,"ReadyGlobal","0")
      o.setGMNotes(s)
      if o.getVar("applyFaceForState") ~= nil then pcall(function() o.call("applyFaceForState") end) end
      if o.getVar("addMenu")           ~= nil then pcall(function() o.call("addMenu")           end) end
    end
  end
end

local function _clearAllShieldsAndDefend()
  local pieces = (G_const().RR.PIECES or {})
  local maybeBadge = Global.getVar("RR_SetDefendBadge")
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    -- keep shields as-is at round end (no RR_ClearShield here)
    if type(maybeBadge)=="function" and pieces[c] then
      pcall(function() maybeBadge({ guid=pieces[c], on=false }) end)
    end
    if type(DEFEND)=="table" then
      DEFEND[c] = false
    end
  end
end

function end_round()
  local ST=S()
  LOG("end_round()")

  local prev = ST.firstPlayer or 1
  local nextFirst = (prev==1) and 2 or 1
  local first = setInitiative(nextFirst)

  ST.round = ST.round + 1
  ST.revealCursor     = { Blue=1, Pink=1, Purple=1 }
  ST.p2PrepIdx        = 0
  ST.p1PrepCnt        = 0
  ST.awaitingEndClick = false

  pcall(function() Global.call("RR_P2_ResetAll") end)
  _resetP1_ActionCards()

  _collectBuffZonesToDeck()
  _respawnHomesToDefenseZones()
  _clearAllShieldsAndDefend()

  setPhase("plan phase")
  ST.currentTurn = (first==2) and 2 or 1

  pcall(function() Global.call("RR_RollGameDice") end)
  Wait.time(function()
    local W=W_read()
    ST.diceValues       = W.dice or {0,0,0}
    ST.diceTotal        = sumDice(ST.diceValues)
    ST.remainingActions = ST.diceTotal

    _logSafe("BeginRound", { round = ST.round, firstPlayer = ST.currentTurn, dice = ST.diceValues })

    broadcastToAll(
      string.format("Round %d — plan. Dice=%s total=%d. %s to pick first.",
        ST.round, JSON.encode(ST.diceValues), ST.diceTotal,
        (ST.currentTurn==1 and "Player 1 (White)" or "Computer")),{0,0.5,1})

    setSelfHighlight(false)
    if setCueTint then setCueTint(false) end
    maybeAutoAdvanceForComputer()
  end, 1.0)
end

--=============================================================================
--== [6] EXTERNAL AI TOKEN HOOKUP + STATUS OBJECT ============================
--=============================================================================
AI_GUID = "773b16"
local function _AI()
  local obj = getObjectFromGUID(AI_GUID)
  if not obj then _RAWPRINT("AI token NOT found for GUID "..tostring(AI_GUID)..". Using fallbacks only.") end
  return obj
end

function AI_WireLog_Request(req)  -- defined later again (same name) — here as stub in case CallAI fires before bottom section loads
  if not LOG_AI_WIRE_ON then return end
  local ok, s = pcall(JSON.encode, req); _RAWPRINT("[AI wire→] "..(ok and s or "<json>"))
end
function AI_WireLog_Reply(res)
  if not LOG_AI_WIRE_ON then return end
  local ok, s = pcall(JSON.encode, res); _RAWPRINT("[AI wire←] "..(ok and s or "<json>"))
end

local function CallAI(requestTbl)
  local ai = _AI()
  if not ai then
    _RAWPRINT("[TurnToken] AI missing: no object for GUID "..tostring(AI_GUID))
    return nil
  end
  local f = ai.getVar and ai.getVar("AI_Request")
  if type(f) ~= "function" then
    _RAWPRINT("AI object found ("..(ai.getName() or "<unnamed>")..") but AI_Request is not present/visible as a global function.")
    return nil
  end
  if type(AI_WireLog_Request)=="function" then pcall(AI_WireLog_Request, requestTbl) end
  local ok, res = pcall(function() return ai.call("AI_Request", requestTbl) end)
  if not ok then _RAWPRINT("AI_Request failed (runtime error): "..tostring(res)); return nil end
  if type(AI_WireLog_Reply)=="function" then pcall(AI_WireLog_Reply, res) end
  return res
end

-- Helpers to read notes/tags on cards for stacks/buffs
local function _parseNote(obj, key)
  local s = (obj and obj.getGMNotes and (obj.getGMNotes() or "")) or ""
  local pat = "%["..key:gsub("(%W)","%%%1")..":([^%]]+)%]"
  return s:match(pat)
end

-- =========================
-- PHASE 1: Short codes & helpers
-- =========================
local SHORT = { Blue="BB", Pink="BH", Purple="BR", Green="WR", Yellow="WH", Orange="WB" }
local function short(c) return SHORT[c] or tostring(c) end

-- Board square or HM if not on board
local function squareOrHM(color)
  local W = W_read() or {}
  local e = (W.pieces or {})[color]
  if e and e.loc == "BOARD" and e.square and e.square ~= "" then return e.square end
  return "HM"
end

-- Flag / Shield state
local FLAG_TOOLTIP = "FlagMarkerPanel"
local SHIELD_TOOLTIP = "ShieldMarkerPanel"
local function _pieceHasFlagByGuid(guid)
  local piece = guid and getObjectFromGUID(guid) or nil
  if not piece or not piece.getButtons then return false end
  for _,b in ipairs(piece.getButtons() or {}) do if b.tooltip == FLAG_TOOLTIP then return true end end
  return false
end
local function _pieceHasShieldByGuid(guid)
  local piece = guid and getObjectFromGUID(guid) or nil
  if not piece or not piece.getButtons then return false end
  for _,b in ipairs(piece.getButtons() or {}) do if b.tooltip == SHIELD_TOOLTIP then return true end end
  return false
end
local function _pieceHasFlag(color)
  local guid = (G_const().RR.PIECES or {})[color]
  return _pieceHasFlagByGuid(guid)
end
local function _pieceHasShield(color)
  local gv = Global.getVar("RR_ShieldStatus_"..tostring(color))
  if gv == true or gv == false then return gv end
  local guid = (G_const().RR.PIECES or {})[color]
  return _pieceHasShieldByGuid(guid)
end

-- Buff state code
local function _readBuffZone(color)
  local ok, name = pcall(function() return Global.call("RR_ReadBuffZone", color) end)
  local n = (ok and type(name)=="string" and name~="" and name) or "None"
  if n=="Extra Move" or n=="Extra Attack" or n=="Extra Defend" or n=="Diagonal Move" then return n end
  return (n=="None" and "None") or "Face down"
end
local function _buffZoneStatus(color)
  -- First: look for the physical card in the zone and use its orientation
  local pos = _findBuffZonePos(color)
  if pos then
    local card = _nearestBuffCardTo(pos, _gatherHandGuids())
    if card then
      return (card.is_face_down and "Unrevealed" or "Revealed")
    end
  end
  -- Fallback to the global reader
  local v = _readBuffZone(color)
  if not v or v == "None" then return "None" end
  if v == "Face down" then return "Unrevealed" end
  return "Revealed"
end


-- =========================
-- Snapshot for simple match history
-- =========================
local SHORT_PIECE = { Purple="BR", Pink="BH", Blue="BB", Green="WR", Yellow="WH", Orange="WB" }
local function shortPiece(color) return SHORT_PIECE[color] or color end

local function _safe_W()
  local ok, W = pcall(W_read); if ok and W then return W end
  return { pieces = {}, buffs = { hand = { P1 = 0, P2 = 0 }, zoneStatus = {} }, dice = { 0,0,0 } }
end
local function _square_or_HM(color)
  local W = _safe_W()
  local p  = (W.pieces or {})[color]
  if p and (p.square and p.square ~= "") and (p.loc == "BOARD" or p.loc == nil) then return p.square end
  return "HM"
end
local function _has_flag(color) return _pieceHasFlag(color) end
local function _has_shield(color) return _pieceHasShield(color) end
-- replace your existing _buff_state with this:
local function _buff_state(color)
  local z = _buffZoneStatus(color)  -- uses RR_ReadBuffZone internally
  if z == "None" then return "NB" end
  if z == "Revealed" then return "BR" end
  return "BU"  -- Unrevealed
end

local function _read_dice()
  local W = _safe_W()
  local d = W.dice or W.diceValues or {0,0,0}
  local a = tonumber(d[1] or 0) or 0
  local b = tonumber(d[2] or 0) or 0
  local c = tonumber(d[3] or 0) or 0
  return a, b, c
end
local function _buff_counts()
  local W = _safe_W()
  local hand = (W.buffs or {}).hand or {}
  local p1 = tonumber(hand.P1 or 0) or 0
  local p2 = tonumber(hand.P2 or 0) or 0
  return p1, p2
end
local function _encode_piece(color)
  local sc  = shortPiece(color)
  local loc = _square_or_HM(color)
  local F   = _has_flag(color)   and "HF" or "NF"
  local S   = _has_shield(color) and "HS" or "NS"
  local B   = _buff_state(color) -- NB/BU/BR
  return string.format("%s_%s_%s_%s_%s", sc, loc, F, S, B)
end
local MATCH_HISTORY = {}
local TURN_N        = 0
local _snapP1       = nil
local function BuildSimpleSnapshot()
  local p_wr = _encode_piece("Green")
  local p_wh = _encode_piece("Yellow")
  local p_wb = _encode_piece("Orange")
  local p_br = _encode_piece("Purple")
  local p_bh = _encode_piece("Pink")
  local p_bb = _encode_piece("Blue")
  local P1c, P2c = _buff_counts()
  local d1, d2, d3 = _read_dice()
  local tail = string.format("P1_%d_BC,P2_%d_BC,D_%d_%d_%d", P1c, P2c, d1, d2, d3)
  local body = table.concat({ p_wr, p_wh, p_wb, p_br, p_bh, p_bb, tail }, ",")
  return "(" .. body .. ")"
end
local function RR_MatchHistory_Reset() MATCH_HISTORY = {}; TURN_N = 0; _snapP1 = nil end
local function RR_MatchHistory_Snapshot_AfterP1() _snapP1 = BuildSimpleSnapshot() end
local function RR_MatchHistory_Snapshot_AfterP2() TURN_N = TURN_N + 1; MATCH_HISTORY[TURN_N] = BuildSimpleSnapshot() end
local function RR_MatchHistory_GetAll() return MATCH_HISTORY, TURN_N end

-- ==== Status object for AI ==================================================
local function _countBuffCardsInHandBySeat(seatColor)
  local ok, handObjs = pcall(function() return Player[seatColor] and Player[seatColor].getHandObjects() or {} end)
  if not ok or type(handObjs) ~= "table" then return 0 end
  local n = 0
  for _,o in ipairs(handObjs) do
    if o and o.tag == "Card" then
      local tags = o.getTags() or {}
      for _,t in ipairs(tags) do if _BUFF_TAGS[t] then n = n + 1; break end end
    end
  end
  return n
end
local function _seatForP2() return (G_const().RR or {}).PLAYER2 or "Blue" end
local function _seatForP1() return "White" end
local function _readStackAsFaces(guidList)
  local out = {}
  for i=1, math.min(6, #(guidList or {})) do
    local card = getObjectFromGUID(guidList[i])
    if card and card.tag=="Card" then
      local kind = (_parseNote(card,"FaceKind") or "ACTION"):upper()
      local rev  = (_parseNote(card,"Revealed")=="1")
      out[#out+1] = { face=kind, revealed=rev }
    end
  end
  return out
end
local function _p2StacksAsFaces()
  local out = {}
  for _,c in ipairs({"Blue","Pink","Purple"}) do out[c] = _readStackAsFaces(getP2StackForColor(c)) end
  return out
end
local function _scanP1ActionCardsByColor()
  local buckets = { Green={}, Yellow={}, Orange={} }
  for _,o in ipairs(getAllObjects()) do
    if o.tag=="Card" then
      local tags=o.getTags() or {}
      local isP1=false; for _,t in ipairs(tags) do if t=="Player 1" then isP1=true; break end end
      if isP1 then
        local colorTag=nil
        for _,t in ipairs(tags) do if t=="Green" or t=="Yellow" or t=="Orange" then colorTag=t; break end end
        if colorTag then
          buckets[colorTag][#buckets[colorTag]+1] = {
            face     = (_parseNote(o,"FaceKind") or "ACTION"):upper(),
            revealed = (_parseNote(o,"Revealed")=="1")
          }
        end
      end
    end
  end
  return buckets
end
local function _p1StacksAsFaces() return _scanP1ActionCardsByColor() end
local function _buffZonesMap()
  local Z = {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do Z[c] = _readBuffZone(c) end
  return Z
end
local function _buffZoneStatusMap()
  local ZS = {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do ZS[c] = _buffZoneStatus(c) end
  return ZS
end
local function _flagsMapFromPieces(P) local M = {}; for k,v in pairs(P) do M[k] = (v.hasFlag == true) end; return M end
local function _shieldsMapFromPieces(P) local M = {}; for k,v in pairs(P) do M[k] = (v.hasShield == true) end; return M end

-- Create (once) and return the persistent P2 seed for this game.
function _ensureP2Seed()
  local ST = S()
  if type(ST.rng) ~= "table" then ST.rng = { P2 = nil } end
  if ST.rng.P2 == nil then
    -- Base the seed on wall clock time (seconds) plus a little extra jitter
    local base  = (os.time and os.time()) or 0
    local extra = math.floor(((os.clock and os.clock()) or 0) * 1000) % 1000
    ST.rng.P2   = base * 1000 + extra   -- e.g., milliseconds resolution
  end
  return ST.rng.P2
end


function BuildStatusForAI()
  local ST = S()
  local W  = W_read() or {}

  local colors = {"Blue","Pink","Purple","Green","Yellow","Orange"}
  local P = {}
  for _, c in ipairs(colors) do
    local e = (W.pieces or {})[c] or {}
    local hasFlag   = _pieceHasFlag(c)
    local hasShield = _pieceHasShield(c)
    local defending = (type(DEFEND)=="table" and DEFEND[c]==true) or false
    P[c] = {
      loc       = e.loc or ((e.square and "BOARD") or "HOME"),
      square    = e.square or nil,
      hasFlag   = hasFlag,
      hasShield = hasShield,
      defending = defending,
    }
  end

  local stacksP2   = _p2StacksAsFaces()
  local stacksP1   = _p1StacksAsFaces()
  -- Hide P1’s unrevealed plan from the AI
  for color, arr in pairs(stacksP1) do
    for _, slot in ipairs(arr or {}) do
      if slot.revealed ~= true then slot.face = "UNKNOWN" end
    end
  end

  local zones      = _buffZonesMap()
  local zoneStatus = _buffZoneStatusMap()

  local handP2List = _buffHandListForSeat(_seatForP2())
  local handP1List = _buffHandListForSeat(_seatForP1())
  local handP2     = #handP2List
  local handP1     = #handP1List

  -- Names + type counts
  local function _toNames(list)
    local t = {}
    for _, e in ipairs(list or {}) do
      local n = e and e.name
      if n and n ~= "" then t[#t+1] = n end
    end
    return t
  end
  local function _toTypes(list)
    local m = {}
    for _, e in ipairs(list or {}) do
      local n = e and e.name
      if n and n ~= "" then m[n] = (m[n] or 0) + 1 end
    end
    return m
  end

  -- AI vantage is P2
  local handCards = { P2 = _toNames(handP2List), P1 = {} }
  local handTypes = { P2 = _toTypes(handP2List), P1 = {} }

  local diceVals = ST.diceValues or (W.dice or {0,0,0})
  local token    = { square = ((W.buff_token or {}).square) or nil }

  local seedP2 = _ensureP2Seed()
  local rngObj = { player = "P2", seed = seedP2, seedHex = string.format("%x", seedP2) }

  local meta = {
    schema      = SCHEMA_VERSION,
    round       = ST.round,
    phase       = ST.phase,
    currentTurn = ST.currentTurn,
    firstPlayer = ST.firstPlayer,
    difficulty  = ST.difficulty,
    objects     = { turnToken = self and self.getGUID() or nil, aiToken = AI_GUID },
    rng         = rngObj,   -- NEW: seed for AI in agreed format
  }


  local budget = {
    P1        = (ST.revealBudget and ST.revealBudget.P1) or 0,
    P2        = (ST.revealBudget and ST.revealBudget.P2) or 0,
    remaining = ST.remainingActions or 0,
  }

  local payload = {
    meta        = meta,
    dice        = diceVals,
    diceValues  = diceVals,  -- legacy alias
    token       = token,
    pieces      = P,
    stacks      = { P2 = stacksP2, P1 = stacksP1 },

    buffs = {
      -- canonical
      zones       = zones,          -- map: color -> "Extra Move"/"Face down"/"None"
      zoneStatus  = zoneStatus,     -- map: color -> "None"|"Unrevealed"|"Revealed"
      hand        = { P2 = handP2, P1 = handP1 },     -- counts (legacy existed)
      handCards   = handCards,                          -- NEW: names by side (P2 only visible)
      handTypes   = handTypes,                          -- NEW: {["Extra Move"]=n,...}
      handDetail  = { P2 = handP2List, P1 = handP1List }, -- keep guid+name for our own use
      assigned    = {                                      -- convenience mirror of zones + status
        Blue   = { name = zones.Blue,   status = zoneStatus.Blue   },
        Pink   = { name = zones.Pink,   status = zoneStatus.Pink   },
        Purple = { name = zones.Purple, status = zoneStatus.Purple },
        Green  = { name = zones.Green,  status = zoneStatus.Green  },
        Yellow = { name = zones.Yellow, status = zoneStatus.Yellow },
        Orange = { name = zones.Orange, status = zoneStatus.Orange },
      },

      -- legacy aliases (so old AIs won’t miss buffs)
      zoneAssigned        = zones,
      zoneAssignedStatus  = zoneStatus,
      handCount           = { P2 = handP2, P1 = handP1 },
      names               = handCards.P2,  -- flat array of P2 card names
    },

    flags            = (function() local M={}; for k,v in pairs(P) do M[k]=(v.hasFlag==true) end; return M end)(),
    shields          = (function() local M={}; for k,v in pairs(P) do M[k]=(v.hasShield==true) end; return M end)(),
    budget           = budget,
    lastMover        = ST.lastMover,
    lastEventSummary = ST.lastEventSummary,
    seats            = { P2=_seatForP2(), P1=_seatForP1() },
  }

  -- top-level legacy mirrors (seen in some older policies)
  payload.buffAssigned    = payload.buffs.zones
  payload.buffZoneStatus  = payload.buffs.zoneStatus
  payload.buffHand        = payload.buffs.hand
  payload.buffHandCards   = payload.buffs.handCards.P2
  payload.buffHandTypes   = payload.buffs.handTypes.P2

  -- NEW: expose rng at top level as well (alias to meta.rng) for older AIs
  payload.rng             = rngObj

  return payload

end




--=============================================================================
--== [7] PHASE A — PIECE PLACEMENT (AI-Driven) ===============================
--=============================================================================
function Piece_placement_Decision()
  local ST=S()
  local idxToColor={ "Blue","Pink","Purple" }
  local fallbackColor = idxToColor[(ST.p2PlacementIdx or 0)+1] or "Blue"

  local res = CallAI({ type="Placement", status=BuildStatusForAI() })
  if res and res.color and res.square then return { color=res.color, square=res.square } end

  -- Fallback: first free home on rank 8 for expected color
  local occ={}
  local W=W_read() or {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    local e=(W.pieces or {})[c]; if e and e.square then occ[e.square]=true end
  end
  for f=1,8 do local sq=string.char(string.byte("A")+f-1).."8"; if not occ[sq] then return { color=fallbackColor, square=sq } end end
  return nil
end

function Piece_placement_Resolve(decision)
  local ST=S()
  if not decision or not decision.color or not decision.square then LOG("[PlacementResolve] Invalid decision table"); return end
  local color, square = decision.color, decision.square
  local RR=G_const().RR
  local guid = RR.PIECES and RR.PIECES[color]
  if not guid then _RAWPRINT(string.format("Placement failed: no GUID for %s", tostring(color))); return end
  LOGF("[PlacementResolve] placing %s at %s (guid=%s)", color, square, tostring(guid))
  Global.call("RR_MovePieceToSquare", { guid, square })
  ST.p2PlacementIdx = math.min(3, ST.p2PlacementIdx + 1)
  PMSG_P1_TURN(string.format("%s placed on %s.", color, square))
  _setLastSummary(string.format("%s placed on %s.", color, square))
  _logSafe("RecordPlacement", { side="P2", color=color, square=square })
end

function Piece_placement_Manager()
  local decision = Piece_placement_Decision()
  if decision then Piece_placement_Resolve(decision) else LOG("Piece_placement_Manager(): no decision.") end
end

--=============================================================================
--== [8] PHASE B — plan (AI-Driven) ==========================================
--=============================================================================
function plan_phase_Decision()
  local ST = S()
  if ST.p2PrepIdx >= 3 then return nil end

  -- Default color for this prep index (fallback if AI omits/invalid)
  local idxToColor = { "Blue", "Pink", "Purple" }
  local defaultColor = idxToColor[(ST.p2PrepIdx or 0) + 1]

  -- Default n from dice (fallback if AI omits/invalid)
  local defaultN = tonumber((ST.diceValues or {})[(ST.p2PrepIdx or 0) + 1] or 0) or 0
  defaultN = math.max(0, math.min(6, defaultN))

  local res = CallAI({ type = "plan", status = BuildStatusForAI() })

  local function _clampN(n) n = tonumber(n or 0) or 0; return math.max(0, math.min(6, n)) end
  local function _sanitizeBuffName(name)
    if type(name) ~= "string" or name == "" then return "None" end
    local s = string.lower(name)
    if s == "none" then return "None" end
    if s == "extra move" or s == "move+" or s == "em" then return "Extra Move" end
    if s == "extra attack" or s == "attack+" or s == "ea" then return "Extra Attack" end
    if s == "extra defend" or s == "defend+" or s == "ed" then return "Extra Defend" end
    if s == "diagonal move" or s == "diag move" or s == "diagonal" or s == "dm" then return "Diagonal Move" end
    return "None"
  end
  local function _normFace(v)
    local k = v; if type(v)=="table" then k = v.kind or v.face or v.type end
    if type(k) ~= "string" then return "BLANK" end
    local u = string.upper(k); if u=="M" then u="MOVE" elseif u=="A" then u="ATTACK" elseif u=="D" then u="DEFEND" end
    if u=="MOVE" or u=="ATTACK" or u=="DEFEND" or u=="BLANK" then return u end
    return "BLANK"
  end
  local function _fixPlanToN(plan, n, defaultFill)
    plan = plan or {}; local out = {}
    for i = 1, math.min(n, #plan) do out[i] = _normFace(plan[i]) end
    for i = #out + 1, n do out[i] = defaultFill or "MOVE" end
    return out
  end
  local function _validP2Color(c) return c=="Blue" or c=="Pink" or c=="Purple" end

  if type(res) == "table" then
    local colorOut = _validP2Color(res.color) and res.color or defaultColor
    local n = res.n; if n == nil and type(res.plan) == "table" then n = #res.plan end
    n = _clampN(n ~= nil and n or defaultN)

    local plan = res.plan or res.program or res.cards
    if type(plan) == "table" then plan = _fixPlanToN(plan, n, "MOVE")
    else plan = (n>0) and _fixPlanToN({}, n, "MOVE") or {} end

    -- Buff request by NAME (still supported)
    local wantBuff = "None"
    if type(res.buff) == "table" then
      local use = (res.buff.use ~= false) or (res.buff.enabled == true) or (res.buff.play == true) or (res.buff.want == true)
      if use then wantBuff = _sanitizeBuffName(res.buff.kind or res.buff.name or res.buff.type or "None") end
    elseif type(res.buff) == "string" then
      wantBuff = _sanitizeBuffName(res.buff)
    elseif type(res.wantBuff) == "string" then
      wantBuff = _sanitizeBuffName(res.wantBuff)
    elseif type(res.buffKind) == "string" then
      wantBuff = _sanitizeBuffName(res.buffKind)
    elseif type(res.buffChoice) == "string" then
      wantBuff = _sanitizeBuffName(res.buffChoice)
    end

    -- NEW: explicit hand-card assignment (by GUID)
    local assignGuid, assignColor = nil, colorOut
    if type(res.assignBuff)=="table" and (res.assignBuff.use ~= false) then
      assignGuid  = res.assignBuff.guid or res.assignBuff.card or res.buffGuid
      if _validP2Color(res.assignBuff.color) then assignColor = res.assignBuff.color end
    elseif res.buffGuid then
      assignGuid = res.buffGuid
    end

    if _validP2Color(colorOut) and type(plan) == "table" then
      return {
        color = colorOut, n = n, plan = plan, wantBuff = wantBuff,
        assignBuffGuid = assignGuid, assignBuffColor = assignColor
      }
    end
  end

  local fallbackPlan = {}; for i = 1, defaultN do fallbackPlan[i] = "MOVE" end
  return { color = defaultColor, n = defaultN, plan = fallbackPlan, wantBuff = "None" }
end



function plan_phase_Resolve(decision)
  local ST=S()
  if not decision or not decision.color or decision.n==nil then LOG("[PrepResolve] Invalid decision table"); return end
  local color = decision.color
  local n     = math.max(0, math.min(6, tonumber(decision.n or 0) or 0))
  local plan  = decision.plan or {}
  local wantBuf = decision.wantBuff or "None"

  local guids = getP2StackForColor(color)
  local function noteGet(obj, key)
    local s=obj.getGMNotes() or ""
    local pat="%["..key:gsub("(%W)","%%%1")..":([^%]]+)%]"
    return s:match(pat)
  end
  local function noteSet(obj, key, val)
    local s=obj.getGMNotes() or ""
    local pat="%["..key:gsub("(%W)","%%%1")..":[^%]]+%]"
    if s:find(pat) then s=s:gsub(pat,"["..key..":"..val.."]",1)
    else s=(s~="" and s.."\n" or "").."["..key..":"..val.."]" end
    obj.setGMNotes(s)
  end
  local function refreshCard(o)
    pcall(function() o.call("applyFaceForState") end)
    pcall(function() o.call("addMenu")           end)
  end

  -- Write plan onto unrevealed slots
  local firstIdx = nil
  for i=1, math.min(6, #guids) do
    local card=getObjectFromGUID(guids[i])
    if card and card.tag=="Card" then
      local revealed = (noteGet(card,"Revealed")=="1")
      if not revealed then firstIdx=i; break end
    end
  end

  if not firstIdx or n<=0 then
    LOGF("[PrepResolve] %s → nothing to program (firstIdx=%s, n=%d)", color, tostring(firstIdx), n or -1)
  else
    local wrote, slot = 0, firstIdx
    while slot <= math.min(6, #guids) and wrote < n do
      local card=getObjectFromGUID(guids[slot])
      if card and card.tag=="Card" then
        local revealed = (noteGet(card,"Revealed")=="1")
        if not revealed then
          local want = (plan[wrote+1] or "BLANK"):upper()
          noteSet(card, "FaceKind", want)
          noteSet(card, "Revealed", "0")
          refreshCard(card)
          wrote = wrote + 1
        end
      end
      slot = slot + 1
    end
    LOGF("[PrepResolve] %s → wrote %d action(s) starting at slot %d", color, wrote, firstIdx)
  end

  -- Buff assignment
  local placed, placedName = false, "None"

  -- 1) NEW: if AI gave a specific GUID, place THAT exact card into the zone (if empty)
  if decision.assignBuffGuid then
    local targetColor = decision.assignBuffColor or color
    if _buffZoneStatus(targetColor) == "None" then
      local okPlaced = _placeBuffFromHandToZone(decision.assignBuffGuid, targetColor)
      if okPlaced then
        placed = true
        local obj = getObjectFromGUID(decision.assignBuffGuid)
        placedName = _buffNameFromCard(obj) or placedName
        Wait.frames(function() _squareUpBuffInZone(targetColor, "down") end, 1)
      end
    end
  end

  -- 2) Fallback to name-based placement (your existing behavior)
  if (not placed) and wantBuf ~= "None" then
    local ok,res = pcall(function() return Global.call("RR_PlaceBuffByName", { color=color, name=wantBuf }) end)
    if ok and res then
      placed, placedName = true, wantBuf
    else
      local ok2,res2 = pcall(function() return Global.call("RR_PlaceFirstBuff", color) end)
      placed = (ok2 and (res2 ~= false))
      local okNow,resNow = pcall(function() return Global.call("RR_ReadBuffZone", color) end)
      if okNow and type(resNow)=="string" and resNow~="" then placedName=resNow end
    end
  end

  if placed then Wait.frames(function() _squareUpBuffInZone(color, "down") end, 1) end

  S().buffUsed[color]=false
  ST.p2PrepIdx = math.min(3, ST.p2PrepIdx+1)

  local msg = string.format("%s prepared %d action%s%s",
    color, n, (n==1 and "" or "s"),
    (placed and (" and placed "..tostring(placedName).."!")) or ".")
  LOG(msg); _setLastSummary(msg)
  _logSafe("RecordPrep", { side="P2", color=color, n=n, plan=plan, wantBuff=wantBuf, placedBuff=placedName or "None" })
end


function plan_phase_Manager()
  local decision = plan_phase_Decision()
  if decision then plan_phase_Resolve(decision) else LOG("plan_phase_Manager(): no decision.") end
end

--=============================================================================
--== [9] PHASE C — ACTION (start, win check, decision, resolve) ==============
--=============================================================================
DEFEND = DEFEND or { Blue=false, Pink=false, Purple=false, Green=false, Yellow=false, Orange=false }

local function _inferP2ColorFromSquare(square)
  if not square or square=="None" then return nil end
  local W = W_read() or {}      -- { pieces = { Blue={loc="BOARD",square="A8"}, ... } }
  local P = W.pieces or {}
  for _,c in ipairs({"Blue","Pink","Purple"}) do
    local e = P[c]
    if e and e.loc=="BOARD" and e.square==square then return c end
  end
  return nil
end

local function pieceDead(color)
  local W=W_read() or {}
  local e=(W.pieces or {})[color]
  return (not e) or (e.loc ~= "BOARD")
end

function start_Round()
  local ST=S()
  pcall(function() Global.call("RR_P1_SetReadyAll", true) end)
  pcall(function() Global.call("RR_P2_SetReadyAll", true) end)

  setPhase("Battle Phase")
  ST.currentTurn = ST.firstPlayer

  ST.revealBudget = { P1=ST.diceTotal or 0, P2=ST.diceTotal or 0 }
  ST.remainingActions = ST.revealBudget.P2

  broadcastToAll(
    string.format("Battle Phase begins — %s to act.",
      (ST.currentTurn==1 and "Player 1 (White)" or "Computer")),{0,1,0})
end

-- Center-screen toast
local TOAST_ID       = "rr_center_toast"
local TOAST_TEXT_ID  = "rr_center_toast_text"
local TOAST_TIMER_TAG= "rr_center_toast_timer"
local function _ensureToastUI()
  if UI.getAttribute(TOAST_ID, "id") then return end
  local xml = [[
    <Panel id="]]..TOAST_ID..[[" rectAlignment="MiddleCenter"
           width="1600" height="240" color="#000000CC"
           active="false" raycastTarget="false">
      <Text id="]]..TOAST_TEXT_ID..[[" alignment="MiddleCenter"
            fontSize="110" color="#FFFFFF">.</Text>
    </Panel>
  ]]
  UI.setXml(UI.getXml() .. xml)
end
function hideWinBanner() UI.setAttribute(TOAST_ID, "active", "false") end
function showWinBanner(text, seconds)
  _ensureToastUI()
  seconds = tonumber(seconds) or 5.0
  UI.setValue(TOAST_TEXT_ID, tostring(text or ""))
  UI.setAttribute(TOAST_ID, "active", "true")
  Timer.destroy(TOAST_TIMER_TAG)
  Timer.create({ identifier=TOAST_TIMER_TAG, function_name="hideWinBanner", function_owner=self, delay=seconds, repetitions=1 })
end

function Check_win()
  local W = W_read(); local P = W.pieces or {}
  local function sideWins(side)
    local targetSq = (side == 1) and "H1" or "A8"
    local colors   = (side == 1) and {"Green","Yellow","Orange"} or {"Blue","Pink","Purple"}
    for _, c in ipairs(colors) do
      if _pieceHasFlag(c) then
        local e = P[c]
        if e and e.loc == "BOARD" and e.square == targetSq then
          return (side == 2) and "COMPUTER" or "PLAYER 1"
        end
      end
    end
    return nil
  end
  return sideWins(1) or sideWins(2)
end

function Action_phase_Decision()
  local ST = S()

  local ai = CallAI({ type="Action", status=BuildStatusForAI() })
  if not ai then PMSG("AI provided no action; skipping reveal this turn."); return true end

  if not ai.color or ai.color=="" then
    local fromSq = ai.location or ai.from or ai.loc_from or ai.location_from or "None"
    if fromSq and fromSq~="None" then
      local inferred = _inferP2ColorFromSquare(fromSq)
      if inferred then ai.color = inferred; DECLOG(string.format("[Action] Inferred color %s from square %s.", inferred, tostring(fromSq))) end
    end
  end
  if not ai.color then PMSG("AI did not specify a color and it could not be inferred; turn burned."); return true end

  local revealed, kind = RR_P2_RevealNextForColor(ai.color)
  if not revealed then PMSG(ai.color.." has no unrevealed actions; turn burned."); return true end

  local revealedKind = string.upper(kind or "BLANK")
  if revealedKind ~= "DEFEND" then RR_ClearShield(ai.color) end
  if ai.burnOnly == true then return true end
  if pieceDead(ai.color) then PMSG(ai.color.." is dead, card wasted."); return true end

  local function _sanitizeBuffName(name)
    if type(name) ~= "string" then return "None" end
    local s = string.lower(name)
    if s == "extra move" or s == "move+" or s == "em" then return "Extra Move" end
    if s == "extra attack" or s == "attack+" or s == "ea" then return "Extra Attack" end
    if s == "extra defend" or s == "defend+" or s == "ed" then return "Extra Defend" end
    if s == "diagonal move" or s == "diag move" or s == "diagonal" or s == "dm" then return "Diagonal Move" end
    if s == "none" then return "None" end
    return "None"
  end

  local function _truthy(v)
    if v == nil then return false end
    if type(v) == "boolean" then return v end
    if type(v) == "string" then
      local s = string.lower(v)
      return (s=="yes" or s=="true" or s=="on" or s=="1")
    end
    return false
  end

  local wantBuff = false
  if type(ai.buff) == "table" then
    -- modern shapes: {use=true}|{enabled=true}|{play=true}|{want=true}
    wantBuff = _truthy(ai.buff.use) or _truthy(ai.buff.enabled) or _truthy(ai.buff.play) or _truthy(ai.buff.want)
  end
  if not wantBuff then
    -- legacy shapes: boolean/string fields
    wantBuff =
      _truthy(ai.buffCardProvided) or
      _truthy(ai.useBuff) or
      (type(ai.buff)=="string" and _sanitizeBuffName(ai.buff) ~= "None")
  end

  local buffKind = _sanitizeBuffName(
    (type(ai.buff)=="table" and (ai.buff.kind or ai.buff.name or ai.buff.type)) or
    ai.buffKind or ai.buff or ai.buffChoice or ai.wantBuff or "None"
  )


local function buffAllowed(k, rk)
  if k=="None" then return true end
  if k=="Extra Attack"  then return rk=="ATTACK" end
  if k=="Extra Defend"  then return (rk=="DEFEND" or rk=="ATTACK" or rk=="MOVE") end
  if k=="Extra Move" or k=="Diagonal Move" then return (rk=="MOVE" or rk=="DEFEND") end
  return false
end

  if (not buffAllowed(buffKind, revealedKind)) then wantBuff=false; buffKind="None" end

  local actionKindLower = string.lower(revealedKind)
  local loc_from = ai.location or ai.from or ai.loc_from or ai.location_from or "None"
  local loc_to
  if revealedKind == "ATTACK" then
    loc_to = ai.location_to or ai.to or ai.targetSquare or "None"
  else
    loc_to = ai.location_to or ai.to or ai.targetSquare or ai.location or loc_from or "None"
  end
  if revealedKind=="ATTACK" and (loc_to=="" or loc_to=="None") then loc_to = "None" end

  -- NEW: pass through a specific hand card GUID if AI chose one
    local buffGuid = (type(ai.buff)=="table" and ai.buff.guid) or ai.buffGuid


  resolve_action({
    color            = ai.color,
    actionKind       = actionKindLower,
    location         = loc_from,
    location_to      = loc_to,
    sequence         = ai.sequence or "ActionFirst",
    buffGuid         = buffGuid,                         -- NEW
    buffCardProvided = (wantBuff and "Yes" or "No"),
    buffKind         = buffKind,
    buffTarget       = ai.buffTarget or (type(ai.buff)=="table" and ai.buff.target) or "None",
    attackTarget     = ai.attackTarget or ai.targetColor or ai.killColor or "None",
  })
  if ai.actionKind and string.upper(ai.actionKind) ~= revealedKind then
    DECLOGF("[Action] Revealed kind %s differs from AI claim %s for %s; resolved using revealed kind.",
      revealedKind, tostring(ai.actionKind), tostring(ai.color))
  end
  return true
end


local function _maybeGiveFlagP2_atSquare(color, square)
  if FLAG_CARRIER.P2 then return end
  if not (color=="Blue" or color=="Pink" or color=="Purple") then return end
  local r = square and tonumber(square:match("%d+")) or nil
  if r == 1 then RR_GiveFlag(color) end
end
local function _maybeGiveFlagP2_nowOrSoon(color, maybeSq)
  _maybeGiveFlagP2_atSquare(color, maybeSq)
  Wait.time(function()
    if FLAG_CARRIER.P2 then return end
    local W=W_read() or {}; local e=(W.pieces or {})[color] or {}
    if e and e.square then _maybeGiveFlagP2_atSquare(color, e.square) end
  end, 0.05)
  Wait.time(function()
    if FLAG_CARRIER.P2 then return end
    local W=W_read() or {}; local e=(W.pieces or {})[color] or {}
    if e and e.square then _maybeGiveFlagP2_atSquare(color, e.square) end
  end, 0.20)
end

local function _clearFlagsOnDeadPieces()
  local W = W_read() or {}
  local P = W.pieces or {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    local e = P[c]
    local dead = (not e) or (e.loc ~= "BOARD")
    if dead then
      if _pieceHasFlag(c)  then RR_RemoveFlag(c)  end
      if _pieceHasShield(c) then RR_ClearShield(c) end
    end
  end
end

local function _isP2Color(c) return (c=="Blue" or c=="Pink" or c=="Purple") end
local function _sideColors(side) return (side==2) and {"Blue","Pink","Purple"} or {"Green","Yellow","Orange"} end
local function _opponentDZRank(side) return (side==2) and 1 or 8 end
local function _listAliveInOppDZ(side)
  local W = W_read() or {}; local P = W.pieces or {}
  local want = _opponentDZRank(side)
  local list = {}
  for _,c in ipairs(_sideColors(side)) do
    local e = P[c]
    if e and e.loc=="BOARD" and e.square then
      local r = tonumber(e.square:match("%d+"))
      if r==want and (not _pieceHasFlag(c)) then list[#list+1]=c end
    end
  end
  return list
end
local function _chooseLeftmost(cands)
  if #cands==0 then return nil end
  local W = W_read() or {}; local P = W.pieces or {}
  local bestC, bestFile = nil, 999
  for _,c in ipairs(cands) do
    local sq = P[c] and P[c].square or nil
    if sq then
      local file = string.byte(sq:sub(1,1))  -- 'A'..'H'
      if file and file < bestFile then bestFile, bestC = file, c end
    end
  end
  return bestC or cands[1]
end
local function _tryReassignFlagAfterCasualty(prevP1Carrier, prevP2Carrier)
  if prevP2Carrier and (not FLAG_CARRIER.P2) then
    local cands = _listAliveInOppDZ(2)
    if #cands==0 then return end
    if #cands==1 then RR_GiveFlag(cands[1]); PMSG("Computer reassigned the flag to "..cands[1].."."); return end
    local res = CallAI({ type="Flag", status=BuildStatusForAI() })
    local choice = nil
    if res and res.color then for _,c in ipairs(cands) do if c==res.color then choice=c break end end end
    if not choice then choice = _chooseLeftmost(cands) end
    if choice then RR_GiveFlag(choice); PMSG("Computer reassigned the flag to "..choice..".") end
  end
end

local function _snapshotOppSide(attackerColor)
  local side = _isP2Color(attackerColor) and 2 or 1
  local opp  = (side==2) and {"Green","Yellow","Orange"} or {"Blue","Pink","Purple"}
  local W = W_read() or {}; local P = W.pieces or {}
  local snap = {}
  for _,c in ipairs(opp) do
    local e = P[c] or {}
    snap[c] = { loc=e.loc or "HOME", square=e.square, hasShield=_pieceHasShield(c) }
  end
  return snap
end

local function _postAttackHandleShields(prevOpp, act)
  if not prevOpp then return end
  local RR = G_const().RR or {}
  local W  = W_read() or {}
  local P  = W.pieces or {}

  if act and act.attackTarget and act.attackTarget~="None" then
    local victim = act.attackTarget
    if _pieceHasShield(victim) then RR_ClearShield(victim); PMSG(victim.." blocked the hit with a shield."); return end
    local g = (RR.PIECES or {})[victim]
    if g then _rrMoveToSquare(g, "HOME") end
    RR_RemoveFlag(victim); RR_ClearShield(victim)
    return
  end

  for color, prev in pairs(prevOpp) do
    local now = P[color] or {}
    local wasOnBoard = (prev.loc=="BOARD")
    local nowOnBoard = (now.loc=="BOARD")
    if wasOnBoard and (not nowOnBoard) then
      local guid = RR.PIECES and RR.PIECES[color]
      if prev.hasShield and guid then
        local piece = getObjectFromGUID(guid); if piece then pcall(function() piece.call("clearShield") end) end
        if prev.square then pcall(function() Global.call("RR_MovePieceToSquare", { guid=guid, square=prev.square }) end) end
        PMSG(color.." blocked the hit with a shield.")
      else
        if guid then pcall(function() _rrMoveToSquare(guid, "HOME") end) end
        RR_RemoveFlag(color); RR_ClearShield(color)
      end
    end
  end
end

local function _simpleActionLine(color, kind, fromSq, toSq, atkTarget)
  local sc = short(color)
  local k  = string.lower(tostring(kind or ""))
  if k == "move" then
    local from = tostring(fromSq or "")
    local arrow = (toSq and "→"..tostring(toSq)) or ""
    return string.format("P2: %s MOVE %s%s", sc, from, arrow)
  elseif k == "attack" then
    local tar = (atkTarget and atkTarget~="None") and short(atkTarget) or ""
    return tar ~= "" and string.format("P2: %s ATTACK %s", sc, tar) or string.format("P2: %s ATTACK", sc)
  elseif k == "defend" then
    return string.format("P2: %s DEFEND%s", sc, toSq and (" "..tostring(toSq)) or "")
  else
    return string.format("P2: %s %s", sc, string.upper(k))
  end
end

function resolve_action(info)
  local function RLOG(msg) if LOG_Decision_Debugging_ON then _RAWPRINT("[Resolve] "..tostring(msg)) end end
  if type(info)~="table" then RLOG("resolve_action(): missing info"); return end

  local color    = info.color or "Blue"
  local kind     = (info.actionKind or "move"):lower()
  local fromSq   = info.location or "None"
  local toSq     = info.location_to or fromSq
  local seq      = info.sequence or "ActionFirst"
  local usedBuf  = (info.buffCardProvided==true) or (type(info.buffCardProvided)=="string" and string.lower(info.buffCardProvided)=="yes")
  local bufKind  = info.buffKind or "None"
  local bufTgt   = info.buffTarget or "None"
  local atkTarget= info.attackTarget or info.targetColor or info.killColor

  -- NEW: if a specific hand card was provided, grab the object & treat its name as truth
  local pickedCard = (info.buffGuid and getObjectFromGUID(info.buffGuid)) or nil
  if pickedCard then
    local detected = _buffNameFromCard(pickedCard)
    if detected then bufKind = detected end
  end

  local RR   = G_const().RR or {}
  local guid = RR.PIECES and RR.PIECES[color] or nil
  local summary = ""

  local function _moveTo(sq)
    if not guid or not sq or sq=="None" then return false end
    local ok = pcall(function() Global.call("RR_MovePieceToSquare", { guid, sq }) end)
    return ok
  end
  local function _setDefend(on)
    DEFEND[color] = (on==true)
    pcall(function()
      local fn = Global.getVar("RR_SetDefendBadge")
      if type(fn)=="function" then fn({ guid=guid, on=on }) end
    end)
    if _isP2Color(color) then RR_SetShield(color, on and true or false) end
  end
  local function _colorAtSquare(sq)
    if not sq or sq=="None" then return nil end
    local W = W_read() or {}; local P = W.pieces or {}
    for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
      local e = P[c]; if e and e.loc=="BOARD" and e.square==sq then return c end
    end
    return nil
  end
  local function _resolveImmediateAttack(targetColorOrNil)
    local victim = targetColorOrNil
    if (not victim) or victim=="None" then
      if toSq and toSq ~= "None" and toSq ~= fromSq then
        local c = _colorAtSquare(toSq)
        if c and not _isP2Color(c) then victim = c end
      end
    end
    if not victim or victim=="None" then PMSG(color.." attacked, but no target was specified/found."); return end
    if _pieceHasShield(victim) then RR_ClearShield(victim); PMSG(victim.." blocked the hit with a shield.")
    else _sendHomeAndClear(victim) end
  end
  local function _applyBuff()
    if not usedBuf or bufKind=="None" then return end
    if bufKind=="Extra Move" or bufKind=="Diagonal Move" then
      if bufTgt and bufTgt~="None" then _moveTo(bufTgt); _maybeGiveFlagP2_nowOrSoon(color, bufTgt) end
    elseif bufKind=="Extra Defend" then
      _setDefend(true)
    elseif bufKind=="Extra Attack" then
      _resolveImmediateAttack(atkTarget)
    end

    -- Consume the chosen source: hand card (preferred) or reveal zone
    -- After use: just flip the zone card (do NOT return it to the deck)
    _flipBuffZone(color)

    local ST=S()
    if ST and ST.buffUsed and color then ST.buffUsed[color] = true end

  end


  local prevP1Carrier = FLAG_CARRIER.P1
  local prevP2Carrier = FLAG_CARRIER.P2

  if seq == "BuffFirst" then _applyBuff() end

  if kind == "move" then
    _moveTo(toSq)
    summary = string.format("%s moved %s", color, tostring(toSq))
    _maybeGiveFlagP2_nowOrSoon(color, toSq)
  elseif kind == "defend" then
    _moveTo(toSq)
    _setDefend(true)
    summary = string.format("%s defended%s", color, (toSq and toSq~=fromSq) and (" at "..toSq) or "")
  elseif kind == "attack" then
    _resolveImmediateAttack(atkTarget)
    summary = string.format("%s attacked", color)
  else
    summary = string.format("%s resolved %s.", color, kind)
  end

  if seq == "ActionFirst" then _applyBuff() end

  Wait.time(function()
    _clearFlagsOnDeadPieces()
    ensureFlagCarriersSafe()
    _tryReassignFlagAfterCasualty(prevP1Carrier, prevP2Carrier)
  end, 0.05)

  if usedBuf and bufKind~="None" then
    summary = (summary~="" and (summary..", used "..bufKind..".")) or (color.." used "..bufKind..".")
  end
  if summary=="" then summary=string.format("%s resolved %s.", color, kind) end
  local simple = _simpleActionLine(color, kind, fromSq, toSq, atkTarget)
  PMSG_P1_TURN(simple); _setLastSummary(simple)

  _logSafe("RecordAction", {
    side="P2", color=color, kind=kind, from=fromSq, to=toSq,
    buffUsed=(usedBuf==true), buffKind=bufKind, sequence=seq, attackTarget=atkTarget, summary=summary
  })
end


--=============================================================================
--== [10] NEXT FLOW (incl. Action budget + reveals guarantee) ================
--=============================================================================
function onMenuNext(_, _)
  local ST=S()
  LOG("onMenuNext() "..dumpState())
  if ST.phase=="Waiting_To_Start_Game" then _RAWPRINT("Use 'Start Game' first."); return end
  local who=ST.currentTurn

  -- End-of-round gate during Action
  if ST.phase=="Battle Phase" and ST.awaitingEndClick==true then
    setSelfHighlight(false)
    if setCueTint then setCueTint(false) end
    end_round()
    return
  end

  -- A) PIECE PLACEMENT
  if ST.phase=="Piece placement" then
    if who==2 then
      Piece_placement_Manager()
      ST.currentTurn = 1
      Wait.time(ensureFlagCarriersSafe, 0.1)
    else
      ST.p1PlacementCnt = math.min(3, ST.p1PlacementCnt+1)
      ST.currentTurn = 2
    end
    if (ST.p2PlacementIdx>=3) and (ST.p1PlacementCnt>=3) then
      setPhase("plan phase")
      ST.currentTurn = ST.firstPlayer
      ST.p2PrepIdx = 0
      ST.p1PrepCnt = 0
      local W=W_read()
      ST.diceValues = W.dice or {0,0,0}
      ST.diceTotal  = sumDice(ST.diceValues)
      ST.remainingActions = ST.diceTotal
      if RR_AI and RR_AI.TurnLog and type(RR_AI.TurnLog.BeginRound)=="function" then
        RR_AI.TurnLog.BeginRound({ round = ST.round, firstPlayer = ST.currentTurn, dice = ST.diceValues })
      end
      broadcastToAll(
        string.format("Round %d — plan. Dice=%s total=%d. %s to pick first.",
          ST.round, JSON.encode(ST.diceValues), ST.diceTotal,
          (ST.currentTurn==1 and "Player 1 (White)" or "Computer")),{0,0.5,1})
    end
    maybeAutoAdvanceForComputer()

  -- B) plan
  elseif ST.phase=="plan phase" then
    if who==2 then
      plan_phase_Manager()
      ST.currentTurn = 1
    else
      ST.p1PrepCnt = math.min(3, ST.p1PrepCnt+1)
      ST.currentTurn = 2
    end

    if (ST.p2PrepIdx>=3) and (ST.p1PrepCnt>=3) then start_Round() end
    maybeAutoAdvanceForComputer()

  -- C) ACTION
  elseif ST.phase=="Battle Phase" then
    local winner = Check_win()
    if winner then
      showWinBanner((winner == "COMPUTER") and "Computer wins!" or "Player wins!")
      _RAWPRINT(winner.." WINS! Right-click the Turn Token → Reset Board to play again.")
      setPhase("Game Over"); addMenus()
      return
    end

    if who==2 then
      local before = ST.revealBudget.P2 or 0
      local _ = Action_phase_Decision()

      -- Phase 5: Snapshot AFTER Computer's action
      if LOG_MATCH_HISTORY and type(RR_MatchHistory_Snapshot_AfterP2)=="function" then
  pcall(RR_MatchHistory_Snapshot_AfterP2)
end


      ST.revealBudget.P2   = math.max(0, before - 1)
      ST.remainingActions  = ST.revealBudget.P2
      ST.lastMover         = 2

      if (ST.revealBudget.P1<=0) and (ST.revealBudget.P2<=0) then
        ST.awaitingEndClick = true
        setSelfHighlight(true)
        if setCueTint then setCueTint(true) end
        local summary = ST.lastEventSummary or "Computer finished."
        PMSG_NEXT_ROUND(summary)
        return
      end
      ST.currentTurn = (ST.revealBudget.P1>0) and 1 or 2
      if ST.currentTurn==1 then
        Wait.time(function() LOG("Player 1's Turn: Reveal and resolve one of your own cards.") end, 0.4)
      end

    else
      local before = ST.revealBudget.P1 or 0
      ST.revealBudget.P1 = math.max(0, before - 1)
      ST.lastMover       = 1
      LOG("Player 1's Turn: Reveal and resolve one of your own cards.")
      Wait.time(ensureFlagCarriersSafe, 0.1)

      -- Phase 5: Snapshot AFTER Player 1's action (before handing to P2)
      if LOG_MATCH_HISTORY and type(RR_MatchHistory_Snapshot_AfterP1)=="function" then
  pcall(RR_MatchHistory_Snapshot_AfterP1)
end


      if (ST.revealBudget.P1<=0) and (ST.revealBudget.P2<=0) then
        ST.awaitingEndClick = true
        setSelfHighlight(true)
        if setCueTint then setCueTint(true) end
        PMSG_NEXT_ROUND(ST.lastEventSummary or "Player finished.")
        return
      end
      ST.currentTurn = (ST.revealBudget.P2>0) and 2 or 1
    end

    local winner2 = Check_win()
    if winner2 then
      showWinBanner((winner2 == "COMPUTER") and "Computer wins!" or "Player wins!")
      _RAWPRINT(winner2.." WINS! Right-click the Turn Token → Reset Board to play again.")
      setPhase("Game Over"); addMenus()
      return
    end

    maybeAutoAdvanceForComputer()
  end
end

--=============================================================================
--== [11] TURN LOG (rounds + events) =========================================
--=============================================================================
RR_AI = RR_AI or {}
local function _curLog()
  local st = S()
  st.aiLog = st.aiLog or { rounds = {}, startedAt = os.time and os.time() or nil }
  return st.aiLog
end
local function _ensureRound(roundIdx)
  local L = _curLog()
  if #L.rounds == 0 or (roundIdx and L.rounds[#L.rounds].round ~= roundIdx) then
    L.rounds[#L.rounds+1] = { round = roundIdx or ((#L.rounds)+1), firstPlayer = nil, dice = {0,0,0}, entries = {} }
  end
  return L.rounds[#L.rounds]
end
local function _pushEntry(roundIdx, entry)
  local R = _ensureRound(roundIdx)
  entry.ts = os.time and os.time() or nil
  R.entries[#R.entries+1] = entry
end

RR_AI.TurnLog = {
  Clear = function() S().aiLog = { rounds = {}, startedAt = os.time and os.time() or nil } end,

  BeginRound = function(args)
    local R = _ensureRound(args.round)
    R.round       = args.round
    R.firstPlayer = args.firstPlayer
    R.dice        = { (args.dice or {})[1] or 0, (args.dice or {})[2] or 0, (args.dice or {})[3] or 0 }
  end,

  RecordPlacement = function(e)
    local ST=S()
    _pushEntry(ST.round, { type="placement", side=e.side or "P2", color=e.color, square=e.square })
  end,

  RecordPrep = function(e)
    local ST=S()
    _pushEntry(ST.round, {
      type="prep", side=e.side or "P2", color=e.color, n=e.n or 0,
      plan=e.plan or {}, wantBuff=e.wantBuff or "None", placedBuff=e.placedBuff or nil
    })
  end,

  RecordAction = function(e)
    local ST=S()
    _pushEntry(ST.round, {
      type="action", side=e.side or "P2", color=e.color, kind=e.kind,
      from=e.from, to=e.to, buffUsed=e.buffUsed or false, buffKind=e.buffKind or "None",
      sequence=e.sequence or "ActionFirst", attackTarget=e.attackTarget, summary=e.summary
    })
  end,

  ExportToNotebook = function()
    local stCopy
    do
      local ok, enc = pcall(function() return JSON.encode(S()) end)
      if ok then local ok2, dec = pcall(JSON.decode, enc); if ok2 and type(dec)=="table" then stCopy = dec end end
    end
    stCopy = stCopy or S()
    stCopy.aiLog = nil

    local snap = { state = stCopy, world = W_read(), ai_log = _curLog() }
    local okBlob, blob = pcall(function() return JSON.encode(snap) end)
    if not okBlob then broadcastToAll("[TurnToken] Export failed (JSON).", {1,1,1}); return end

    local TITLE = "Battleplan Match Log"
    local MAX   = 60000
    local parts = {}
    for i=1, #blob, MAX do parts[#parts+1] = blob:sub(i, math.min(i+MAX-1, #blob)) end

    local function _edit(idx0, params)
      local ok = pcall(function() editNotebookTab({ index = idx0, title = params.title, body = params.body }) end)
      if ok then return true end
      ok = pcall(function() editNotebookTab(idx0, params) end)
      if ok then return true end
      ok = pcall(function() editNotebookTab(idx0+1, params) end)
      return ok
    end
    local function _add(params)
      local ok, res = pcall(function() return addNotebookTab(params) end)
      if ok and type(res)=="number" then return res end
      local tabs = getNotebookTabs() or {}
      tabs[#tabs+1] = { title=params.title, body=params.body }
      pcall(function() setNotebookTabs(tabs) end)
      return #tabs-1
    end

    local tabsBefore = getNotebookTabs() or {}
    local baseIdx0
    for i,t in ipairs(tabsBefore) do if t.title==TITLE then baseIdx0=i-1 break end end

    if #parts == 1 then
      local params = { title = TITLE, body = parts[1] }
      if baseIdx0 ~= nil then _edit(baseIdx0, params) else baseIdx0 = _add(params) end
    else
      for n,chunk in ipairs(parts) do
        local partTitle = string.format("%s (%d/%d)", TITLE, n, #parts)
        local idx0
        local tabsNow = getNotebookTabs() or {}
        for i,t in ipairs(tabsNow) do if t.title==partTitle then idx0=i-1 break end end
        local params = { title = partTitle, body = chunk }
        if idx0 ~= nil then _edit(idx0, params) else _add(params) end
      end
    end

    local after = getNotebookTabs() or {}
    local found, count = {}, 0
    for _,t in ipairs(after) do
      if t.title==TITLE or t.title:match("^"..TITLE:gsub("%W","%%%1").." %(%d+/%d+%)$") then
        count = count + 1; found[#found+1]=t.title
      end
    end

    if count > 0 then
      broadcastToAll(string.format("[TurnToken] Match log written to Notebook: %s", table.concat(found, ", ")), {1,1,1})
    else
      broadcastToAll("[TurnToken] Tried to write match log, but Notebook did not update. This usually means the payload was too large or the API signature is different in your build.", {1,0.2,0.2})
      local pointer = string.format("%s\n\n(length=%d chars). If Notebook didn’t update, reduce log size or use the multi-part tabs.", TITLE, #blob)
      pcall(function() setNotes(pointer) end)
    end
  end
}

--=============================================================================
--== [12] SIMPLE MATCH EXPORT + DEBUG HELPERS ================================
--=============================================================================
local function _safeEdit(idx0, rec)
  if type(editNotebookTab) ~= "function" then return false end
  local ok = pcall(function()
    editNotebookTab({ index = idx0, title = rec.title, body = rec.body, color = rec.color or "Grey" })
  end)
  if ok then return true end
  ok = pcall(function()
    editNotebookTab(idx0, { title = rec.title, body = rec.body, color = rec.color or "Grey" })
  end)
  if ok then return true end
  ok = pcall(function()
    editNotebookTab(idx0 + 1, { title = rec.title, body = rec.body, color = rec.color or "Grey" })
  end)
  return ok
end

local function _safeAdd(rec)
  if type(addNotebookTab) ~= "function" then return false end
  local ok = pcall(function()
    addNotebookTab({ title = rec.title, body = rec.body, color = rec.color or "Grey" })
  end)
  if ok then return true end
  ok = pcall(function() addNotebookTab(rec.title, rec.body) end)
  return ok
end

local function _upsertNotebookTabs(entries)
  entries = entries or {}
  local tabs = (type(getNotebookTabs)=="function" and (getNotebookTabs() or {})) or {}

  -- Fast path: if we can set the whole list, try that first
  if type(setNotebookTabs) == "function" then
    local nameToIdx = {}
    for i,t in ipairs(tabs) do nameToIdx[t.title or ("#"..i)] = i end
    for _,e in ipairs(entries) do
      local i = nameToIdx[e.title]
      local color = (i and tabs[i] and tabs[i].color) or "Grey"
      local rec = { title = tostring(e.title), body = tostring(e.body or ""), color = color }
      if i then tabs[i] = rec else tabs[#tabs+1] = rec end
    end
    local ok, err = pcall(function() setNotebookTabs(tabs) end)
    if not ok then
      broadcastToAll("[TurnToken] setNotebookTabs not usable here: "..tostring(err), {1,0.2,0.2})
    else
      local after = getNotebookTabs() or {}
      local have = {}
      for _,e in ipairs(entries) do
        local found=false; for _,t in ipairs(after) do if t.title==e.title then found=true break end end
        have[#have+1] = e.title..(found and " ✓" or " ✗")
      end
      broadcastToAll("[TurnToken] Notebook upsert: "..table.concat(have, ", "), {1,1,1})
      return true
    end
  end

  -- Fallback path: per-tab safe edit/add
  local titleToIdx0 = {}
  for i,t in ipairs(tabs) do titleToIdx0[t.title or ("#"..i)] = i-1 end

  local results = {}
  for _,e in ipairs(entries) do
    local rec = { title=tostring(e.title), body=tostring(e.body or ""), color="Grey" }
    local idx0 = titleToIdx0[rec.title]
    local ok = (idx0 ~= nil) and _safeEdit(idx0, rec) or _safeAdd(rec)
    results[#results+1] = rec.title..(ok and " ✓" or " ✗")

    -- refresh cached tab list/indexes in case UI mutated
    tabs = getNotebookTabs() or tabs
    titleToIdx0 = {}; for i,t in ipairs(tabs) do titleToIdx0[t.title or ("#"..i)] = i-1 end
  end
  broadcastToAll("[TurnToken] Notebook upsert: "..table.concat(results, ", "), {1,1,1})
  for _,r in ipairs(results) do if r:sub(-3)==" ✓" then return true end end
  return false
end

function onMenuNotebookSelfTest(_, _)
  local ts = os.time and os.time() or math.random(1, 999999)
  _upsertNotebookTabs({ { title = "Battleplan TEST "..ts, body = "hello @"..ts } })
end

function onMenuResetHistory(_, _)
  RR_MatchHistory_Reset()
  broadcastToAll("[TurnToken] Match history cleared (T1…Tn).", {1,1,1})
end

function onMenuCopyMatch(_, _)
  local title = "Battleplan Match (Simple)"
  local H, N = RR_MatchHistory_GetAll()
  local lines = {}
  lines[#lines+1] = string.format("Match history — %d turn(s)", tonumber(N or 0))
  lines[#lines+1] = "Format: (WR_..,WH_..,WB_..,BR_..,BH_..,BB_..,P1_x_BC,P2_y_BC,D_a_b_c)"
  lines[#lines+1] = ""
  if type(H) ~= "table" or (N or 0) == 0 then
    lines[#lines+1] = "No turns recorded yet."
  else
    for i = 1, N do
      lines[#lines+1] = string.format("T%d: %s", i, tostring(H[i] or "(nil)"))
    end
  end
  local body = table.concat(lines, "\n")

  local ok = _upsertNotebookTabs({ { title = title, body = body, color = "Blue" } })
  if ok then
    broadcastToAll("[TurnToken] Wrote simple match export to Notebook tab: "..title, {1,1,1})
  else
    -- Fallback: attempt to drop the text into the in-game Notes panel
    local okNotes = pcall(function() setNotes(title.."\n\n"..body) end)
    if okNotes then
      broadcastToAll("[TurnToken] Notebook update failed; exported to the Tabletop Notes panel instead.", {1,0.8,0.2})
    else
      broadcastToAll("[TurnToken] Could not export match text (Notebook and Notes both unavailable).", {1,0.2,0.2})
    end
  end
end

-- ---- AI wire logging (concise + verbose modes) -----------------------------
-- Re-define the wire loggers with richer trimming controls.
local function _wireTrimStatus(st)
  if type(st) ~= "table" then return st end

  local colors = {"Blue","Pink","Purple","Green","Yellow","Orange"}
  local piecesOut = {}
  for _,c in ipairs(colors) do
    local p = (st.pieces or {})[c] or {}
    piecesOut[c] = {
      square    = p.square,
      hasFlag   = p.hasFlag == true,
      hasShield = p.hasShield == true,
      defending = p.defending == true, -- NEW
    }
  end

  local function _len(t) return (type(t)=="table") and #t or 0 end
  local sc = (st.stacks or {})
  local p2 = sc.P2 or {}
  local p1 = sc.P1 or {}

  return {
    meta   = st.meta,
    dice   = st.dice or st.diceValues,
    token  = st.token,
    pieces = piecesOut,
    buffs  = {
      zoneStatus = (st.buffs or {}).zoneStatus,
      zones      = (st.buffs or {}).zones,        -- names in zones
      assigned   = (st.buffs or {}).assigned,     -- same as zones+status
      hand       = (st.buffs or {}).hand,
      handCards  = (st.buffs or {}).handCards,    -- names per side
    },

    budget = st.budget,           -- NEW
    lastMover = st.lastMover,     -- NEW
    stacksCounts = {
      P2 = { Blue=_len(p2.Blue), Pink=_len(p2.Pink), Purple=_len(p2.Purple) },
      P1 = { Green=_len(p1.Green), Yellow=_len(p1.Yellow), Orange=_len(p1.Orange) },
    },
  }
end


function AI_WireLog_Request(req)
  if not LOG_AI_WIRE_ON then return end
  local payload
  if LOG_AI_WIRE_VERBOSE then
    local ok, s = pcall(JSON.encode, req)
    payload = ok and s or "<json>"
  else
    local trimmed = { type = req and req.type or "?" }
    if type(req)=="table" and type(req.status)=="table" then
      trimmed.status = _wireTrimStatus(req.status)
    end
    local ok, s = pcall(JSON.encode, trimmed)
    payload = ok and s or "<json>"
  end
  broadcastToAll("[AI wire→] "..payload, {1,1,1})
end

function AI_WireLog_Reply(res)
  if not LOG_AI_WIRE_ON then return end
  local out
  if LOG_AI_WIRE_VERBOSE then
    local ok, s = pcall(JSON.encode, res)
    out = ok and s or "<json>"
  else
    local t = {}
    if type(res)=="table" then
      t.color   = res.color
      t.n       = res.n
      t.planLen = (type(res.plan)=="table") and #res.plan or nil
      t.wantBuff= res.wantBuff or res.buffChoice or res.buffKind
      t.action  = res.actionKind or res.kind
      t.from    = res.location or res.from or res.loc_from
      t.to      = res.location_to or res.to or res.targetSquare
      t.buff    = res.buffKind or res.buff
      t.buffOK  = res.buffCardProvided
      t.target  = res.attackTarget or res.targetColor or res.killColor
      t.seq     = res.sequence
    else
      t.note = tostring(res)
    end
    local ok, s = pcall(JSON.encode, t)
    out = ok and s or "<json>"
  end
  broadcastToAll("[AI wire←] "..out, {1,1,1})
end
