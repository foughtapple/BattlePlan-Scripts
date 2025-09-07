-- sim.lua (v3, Part 1/3)

--#region Part1
-- BattlePlan AI-vs-AI simulator (uses your "AI Code.lua" for BOTH sides)
-- Outputs (controlled by flags at top):
--   1) "sim_match_log.txt"         → lean turn-by-turn diffs (+ optional JSON blocks)
--   2) "sim_match_summery.txt"     → overall stats & aggregates for easy copy/paste
-- No interactive prompts; everything is configured via constants below.

------------------------------------------------------------
-- ========== CONFIG (edit these; no prompts) ==========
------------------------------------------------------------
-- Difficulty handling
P1_DIFFICULTY                  = 0            -- 0 => sweep over P1_DIFFICULTY_SET × P2_DIFFICULTY_SET
P2_DIFFICULTY                  = 0            -- 0 => sweep over P1_DIFFICULTY_SET × P2_DIFFICULTY_SET
P1_DIFFICULTY_SET              = {1,2,3,4,5}
P2_DIFFICULTY_SET              = {1,2,3,4,5}
GAMES_PER_PAIR                 = 20
MAX_ROUNDS_PER_MATCH           = 50           -- stop after this many rounds if no winner

-- === AI RNG controls ===
SAME_SEED = true                              -- flip to false to give P1/P2 different streams
GAME_SEED = GAME_SEED or os.time()            -- pick a fixed int for reproducible runs

-- Run & logging
WRITE_MATCH_LOG                = false         -- write sim_match_log.txt
WRITE_SIM_SUMMERY              = true          -- write sim_match_summery.txt
CONFIRM_OVERWRITE              = false         -- if false, overwrite without asking
INCLUDE_JSON_BLOCKS_IN_MATCH_LOG = false       -- include per-match JSON/JSONL blocks
DEBUG_BUFF                     = false         -- verbose buff debug JSONL (large)
LOG_VERBOSITY                  = 1             -- 0=quiet, 1=normal, 2=debug prints
LOG_VERSION                    = "1.1"

-- Optional size controls for the match log (soft limits only)
MAX_MATCH_LOG_LINES            = 5000
ROTATE_MATCH_LOG               = false

-- Filenames
FILENAME_MATCH_LOG             = "sim_match_log.txt"
FILENAME_SIM_SUMMERY           = "sim_match_summery.txt"  -- spelled per request

-- Seed & reproducibility
SEED_BASE                      = os.time() % 2^31  -- base seed (number or nil for random)
REROLL_SEED_EACH_MATCH         = true        -- if true, seed = SEED_BASE + match_index
RUN_ID_SUFFIX                  = ""          -- appended to summary headers/files

-- What to include in sim_match_summery.txt
SUMMARY_INCLUDE_PER_MATCH_ROWS = true
SUMMARY_INCLUDE_BY_DIFFICULTY  = true
SUMMARY_INCLUDE_GLOBAL         = true
SUMMARY_INCLUDE_HEALTHCHECKS   = true

-- Telemetry toggles
TRACK_OSCILLATION              = true   -- A4→A5→A4 style undo-steps
TRACK_TOWARD_GOAL_DISTANCE     = true   -- signed progress per action
TRACK_BUFF_ROI                 = true   -- keep (already wired)
TRACK_THREAT_SIGNALS           = true   -- before/after adjacent-enemy deltas
TRACK_WASTED_ATTACKS           = true   -- attempted attacks with no legal enemy target

------------------------------------------------------------
-- Minimal JSON (encoder only) – deterministic key order
------------------------------------------------------------
local JSON = {}
do
  local function esc(s)
    s = s:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\b','\\b'):gsub('\f','\\f')
         :gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')
    return '"'..s..'"'
  end
  local function is_array(t)
    local n = 0
    for k,_ in pairs(t) do
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then return false end
      if k > n then n = k end
    end
    for i=1,n do if t[i] == nil then return false end end
    return true
  end
  local enc
  enc = function(v)
    local tv = type(v)
    if tv == "nil"      then return "null"
    elseif tv == "boolean" then return v and "true" or "false"
    elseif tv == "number"  then
      if v ~= v or v == math.huge or v == -math.huge then return "null" end
      return tostring(v)
    elseif tv == "string"  then return esc(v)
    elseif tv == "table"   then
      if is_array(v) then
        local out = {}
        for i=1,#v do out[#out+1] = enc(v[i]) end
        return "["..table.concat(out,",").."]"
      else
        local keys = {}
        for k,_ in pairs(v) do keys[#keys+1] = k end
        table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
        local out = {}
        for i=1,#keys do
          local k = keys[i]
          out[#out+1] = esc(tostring(k))..":"..enc(v[k])
        end
        return "{ "..table.concat(out,",").." }"
      end
    else
      return esc("<"..tv..">")
    end
  end
  JSON.encode = enc
end

-- Quiet 'log' if not provided by host (we will override later to capture)
if type(log) ~= "function" then
  function log(x) end
end

------------------------------------------------------------
-- Seed RNG helper (deterministic per match when desired)
------------------------------------------------------------
local function _seed_rng(seed)
  if type(seed) == "number" then
    math.randomseed(seed)
    for _=1,5 do math.random() end
  else
    math.randomseed(os.time() % 2^31)
  end
end

-- Initial seed for module load
_seed_rng(SEED_BASE)

------------------------------------------------------------
-- Constants & helpers
------------------------------------------------------------
local COLORS_P2 = {"Blue","Pink","Purple"}    -- AI-native side (top, row 8)
local COLORS_P1 = {"Green","Yellow","Orange"} -- human-named (bottom, row 1)

-- Credit life to Extra Defend if this shield came from it, then clear provenance
local function _credit_ed_life(world, piece, defSide)
  if piece._shieldFromExtraDefend and piece._shieldStamp then
    local age = math.max(0, world.stats.turns - piece._shieldStamp)
    local ed = world.stats.buff_effect[defSide].ExtraDefend
    ed._lifeSum = (ed._lifeSum or 0) + age
    ed._lifeCnt = (ed._lifeCnt or 0) + 1
  end
  piece._shieldFromExtraDefend = nil
  piece._shieldStamp = nil
end

local function square(file, rank) return string.char(64+file)..tostring(rank) end
local function parseSquare(sq)
  if type(sq)~="string" or #sq<2 then return nil,nil end
  local f = string.byte(sq:sub(1,1):upper()) - 64
  local r = tonumber(sq:match("%d+"))
  if not f or f<1 or f>8 or not r or r<1 or r>8 then return nil,nil end
  return f,r
end
local function mirror_square(sq) local f,r=parseSquare(sq); return (f and square(f,9-r) or nil) end
local function side_of_color(c) return (c=="Blue" or c=="Pink" or c=="Purple") and 2 or 1 end

local function occupant_at(world, sq)
  if not sq then return nil end
  for c,p in pairs(world.pieces) do
    if p.loc=="BOARD" and p.square==sq then return c end
  end
  return nil
end

local function copy_shallow(t) local r={}; for k,v in pairs(t or {}) do r[k]=v end; return r end
local function push(t,v) t[#t+1]=v end
-- forward declare so earlier funcs can call it
local try_auto_flag

------------------------------------------------------------
-- Movement legality helpers
------------------------------------------------------------
local function _on_board(f,r) return f and r and f>=1 and f<=8 and r>=1 and r<=8 end
local function _is_adj_orth(a,b)
  local f1,r1 = parseSquare(a); local f2,r2 = parseSquare(b)
  if not _on_board(f1,r1) or not _on_board(f2,r2) then return false end
  return (math.abs(f1-f2)+math.abs(r1-r2))==1
end
local function _is_adj_diag(a,b)
  local f1,r1 = parseSquare(a); local f2,r2 = parseSquare(b)
  if not _on_board(f1,r1) or not _on_board(f2,r2) then return false end
  return (math.abs(f1-f2)==1 and math.abs(r1-r2)==1)
end

-- (FIX) add oscillation detection + step bookkeeping
local function _try_step(world, color, toSq, mode)
  local p = world.pieces[color]; if not p or p.loc~="BOARD" or not p.square then return false end
  if not toSq or toSq=="None" then return false end
  if occupant_at(world, toSq) then return false end
  if mode=="orth" and not _is_adj_orth(p.square, toSq) then return false end
  if mode=="diag" and not _is_adj_diag(p.square, toSq) then return false end

  -- detect A4→A5→A4 style undo step
  if TRACK_OSCILLATION and p._lastStepFrom and p._lastStepTo then
    if toSq == p._lastStepFrom and p.square == p._lastStepTo then
      local s = side_of_color(color)
      world.stats.oscillations[s] = (world.stats.oscillations[s] or 0) + 1
    end
  end

  -- legal: move
  local prev = p.square
  p.loc = "BOARD"; p.square = toSq
  -- remember last step (per-piece)
  p._lastStepFrom, p._lastStepTo = prev, toSq

  try_auto_flag(world, color)
  if world.token.square == p.square then
    local side = side_of_color(color)
    local name = world._draw_card(world.buff)
    world._give_card(world, side, name, true, "MovePickup")
    world._reposition_token(world)
    world.stats.token_pickups_move[side] = world.stats.token_pickups_move[side] + 1
  end
  return true
end

-- Threat metric helpers (8-adjacent enemies)
local function _adjacent_enemy_count(world, sq, side)
  if not sq then return 0 end
  local f,r = parseSquare(sq); if not f then return 0 end
  local count = 0
  for df=-1,1 do for dr=-1,1 do
    if not (df==0 and dr==0) then
      local s = square(f+df, r+dr)
      local occ = occupant_at(world, s)
      if occ and side_of_color(occ) ~= side then count = count + 1 end
    end
  end end
  return count
end

local function _orth_legal_move_count(world, sq)
  if not sq then return 0 end
  local f,r = parseSquare(sq); if not f then return 0 end
  local c = 0
  local cand = { square(f+1,r), square(f-1,r), square(f,r+1), square(f,r-1) }
  for _,s in ipairs(cand) do
    local ff,rr = parseSquare(s)
    if _on_board(ff,rr) and not occupant_at(world, s) and _is_adj_orth(sq, s) then
      c = c + 1
    end
  end
  return c
end

------------------------------------------------------------
-- Buff deck + token system
------------------------------------------------------------
local BUFF_TYPES = { "Extra Move", "Extra Attack", "Extra Defend", "Diagonal Move" }

-- Canonicalize buff names coming from the AI to one of BUFF_TYPES or "None"
local function _canon_buff(name)
  if not name then return "None" end
  local k = tostring(name):lower()
  k = k:gsub("_"," "):gsub("%s+"," ")
  if k == "" or k == "none" then return "None" end

  if k:find("diag") or k == "diagonal" then
    return "Diagonal Move"
  end
  if k:find("extra attack") or k:find("attack%+") or k == "atk+" or k == "a+" then
    return "Extra Attack"
  end
  if k:find("extra defend") or k:find("extra defense") or k:find("defend%+")
     or k == "def+" or k == "d+" or k:find("defense") then
    return "Extra Defend"
  end
  if k:find("extra move") or k:find("move%+") or k == "m+" or k == "move" or k == "extramove" then
    return "Extra Move"
  end

  return "None"
end

-- ===== Buff debug helpers (captured for file; JSONL) =====
local function _side_str(side) return (side==2) and "P2" or "P1" end

local function _buff_counts_for(world, sideStr)
  local hand  = world.buff.hand[sideStr] or {}
  local fresh = world.buff.fresh[sideStr] or {}
  local types = {}
  local total, usable, fresh_total = 0, 0, 0
  for _,t in ipairs(BUFF_TYPES) do
    local h = hand[t] or 0
    local fr = fresh[t] or 0
    types[t] = { hand=h, fresh=fr, usable=math.max(0, h-fr) }
    total = total + h
    fresh_total = fresh_total + fr
    usable = usable + math.max(0, h-fr)
  end
  return { total=total, fresh_total=fresh_total, usable=usable, types=types }
end

local function _buff_snapshot(world)
  return { P1=_buff_counts_for(world, "P1"), P2=_buff_counts_for(world, "P2") }
end

local function _buffdbg(world, ev)
  if not (DEBUG_BUFF and world and world.buff_debug) then return end
  local e = copy_shallow(ev or {})
  e.round = world.round
  e.turns = world.stats.turns or 0
  e.phase = world.phase
  e.token = world.token and world.token.square or nil
  e.hands = _buff_snapshot(world)
  push(world.buff_debug, e)
end

local function _shuffle(t)
  for i=#t,2, -1 do local j=math.random(i); t[i],t[j]=t[j] end
end

local function _new_deck()
  local d={}
  for _,name in ipairs(BUFF_TYPES) do for i=1,5 do d[#d+1]=name end end
  _shuffle(d); return d
end

local function _draw_card(state)
  if #state.deck == 0 then
    for i=1,#state.discard do state.deck[#state.deck+1] = state.discard[i] end
    state.discard = {}
    _shuffle(state.deck)
  end
  local c = table.remove(state.deck)  -- pop
  return c
end

local function _push_discard(state, name)
  if name and name ~= "None" then state.discard[#state.discard+1] = name end
end

local function _hand_for(world, side) return (side==2) and world.buff.hand.P2 or world.buff.hand.P1 end
local function _fresh_for(world, side) return (side==2) and world.buff.fresh.P2 or world.buff.fresh.P1 end

-- helper: structured failure log with hand/fresh/usable counts
local function _buff_log_assign_failure(world, side, color, name, reason, src)
  local hand  = _hand_for(world, side)
  local fresh = _fresh_for(world, side)
  _buffdbg(world, {
    event="assign_failed", source=src or "unknown",
    side=side, side_str=_side_str(side),
    color=color, name=name or "None",
    reason=reason or "unknown",
    have=(hand and name and hand[name]) or 0,
    fresh=(fresh and name and fresh[name]) or 0,
    usable=math.max(0, ((hand and name and hand[name]) or 0) - ((fresh and name and fresh[name]) or 0)),
    zone=(world.buffs.zones[color] or "None"),
    zoneStatus=(world.buffs.zoneStatus[color] or "None"),
  })
end

local function _give_card(world, side, name, fresh, src)
  if not name or name=="None" then return end
  local hand  = _hand_for(world, side)
  local freshT= _fresh_for(world, side)
  hand[name]  = (hand[name] or 0) + 1
  if fresh then freshT[name] = (freshT[name] or 0) + 1 end
  world.stats.buff_draws[side] = (world.stats.buff_draws[side] or 0) + 1
  _buffdbg(world, {
    event="give_card", side=side, side_str=_side_str(side),
    name=name, fresh=(fresh and true or false), src=src or "unknown"
  })
end

local function _can_assign(world, side, name)
  local hand  = _hand_for(world, side)
  local freshT= _fresh_for(world, side)
  local have  = (hand[name] or 0)
  local fresh = (freshT[name] or 0)
  return (have - fresh) > 0
end

local function _consume_for_assignment(world, side, name)
  local hand  = _hand_for(world, side)
  if not _can_assign(world, side, name) then return false end
  hand[name] = hand[name] - 1
  world.stats.buff_assigned[side] = (world.stats.buff_assigned[side] or 0) + 1
  _buffdbg(world, { event="consume_for_assignment", side=side, side_str=_side_str(side), name=name })
  return true
end

local function _end_round_cleanup(world)
  -- Discard any un-revealed assigned buffs; reset zones
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    local z = world.buffs.zones[c]
    if z and z~="None" and world.buffs.zoneStatus[c] ~= "Revealed" then
      _buffdbg(world, {
        event="cleanup_discard_unrevealed", side=side_of_color(c), side_str=_side_str(side_of_color(c)),
        color=c, name=z
      })
      _push_discard(world.buff, z)
    end
    world.buffs.zones[c] = "None"
    world.buffs.zoneStatus[c] = "None"
  end
  -- Fresh cards become usable next round
  world.buff.fresh.P1 = {}
  world.buff.fresh.P2 = {}
  -- Shields persist across rounds (they clear on reveal/hit/home)
  world.planDicePool = {}
end

local function _token_roll_square(allowDefensive)
  local f = math.random(1,8)
  local r = math.random(1,8)
  if not allowDefensive then
    while (r==1 or r==8) do r = math.random(1,8) end
  end
  return string.char(64+f)..tostring(r)
end

local function _place_token_initial(world)
  world.token.square = _token_roll_square(false)
end

local function _reposition_token(world)
  while true do
    local sq = _token_roll_square(true)
    local occ = occupant_at(world, sq)
    if not occ then
      world.token.square = sq
      return
    else
      -- occupant draws 1 buff, then re-roll
      local side = side_of_color(occ)
      local name = _draw_card(world.buff)
      _give_card(world, side, name, true, "TokenRespawnHit")
      world.stats.token_respawn_hits[side] = world.stats.token_respawn_hits[side] + 1
      -- continue loop
    end
  end
end

------------------------------------------------------------
-- World state
------------------------------------------------------------
local function _init_buff_effect_bucket()
  return {
    ExtraMove   = { twoStepFinishes=0, distanceGain=0, laneOpens=0 },
    DiagonalMove= { diagonalsTaken=0, laneOpens=0, finishesEnabled=0 },
    ExtraAttack = { firstHitKills=0, secondHitKills=0, shieldsBrokenOnExtra=0 },
    ExtraDefend = { covers=0, escapes=0, _lifeSum=0, _lifeCnt=0, preventedSendHome=0 },
  }
end

local function new_world()
  local pieces = {}
  for _,c in ipairs(COLORS_P2) do
    pieces[c] = { loc="HOME", square=nil, hasFlag=false, hasShield=false, _shieldStamp=nil, _lastStepFrom=nil, _lastStepTo=nil }
  end
  for _,c in ipairs(COLORS_P1) do
    pieces[c] = { loc="HOME", square=nil, hasFlag=false, hasShield=false, _shieldStamp=nil, _lastStepFrom=nil, _lastStepTo=nil }
  end

  return {
    round = 1,
    firstPlayer = 1,                 -- (As requested) P1 always goes first
    phase = "Piece placement",
    dice = {0,0,0},
    planDicePool = { [1]={}, [2]={} },

    pieces = pieces,
    stacks = {
      P2 = { Blue={}, Pink={}, Purple={} },
      P1 = { Green={}, Yellow={}, Orange={} }
    },

    -- zones are “assigned”, zoneStatus=Unrevealed/ Revealed/ None
    buffs = {
      zones = { Blue="None", Pink="None", Purple="None",
                Green="None", Yellow="None", Orange="None" },
      zoneStatus = { Blue="None", Pink="None", Purple="None",
                     Green="None", Yellow="None", Orange="None" },
      hand = { P1=0, P2=0 }, -- exposed to AI as counts (compat shim)
    },

    -- real deck/hand storage (type counts), and “fresh” lockouts
    buff = {
      deck = _new_deck(),
      discard = {},
      hand = { P1={}, P2={} },
      fresh= { P1={}, P2={} },
    },

        token = { square = nil },
    matchConst = { P1 = 0, P2 = 0 },


    stats = {
      initiative = 1,                 -- fixed P1 first for this run mode
      rounds = 0,
      turns = 0,
      reveals_used = { [1]=0, [2]=0 },
      reveals_available = { [1]=0, [2]=0 },
      actions = { [1]={MOVE=0,ATTACK=0,DEFEND=0},
                  [2]={MOVE=0,ATTACK=0,DEFEND=0} },
      attacks_attempted = { [1]=0, [2]=0 },
      attacks_hits      = { [1]=0, [2]=0 },
      wasted_attacks    = { [1]=0, [2]=0 },      -- (NEW) swing-at-air counter
      progress_total    = { [1]=0, [2]=0 },      -- (NEW) net progress toward goal
      oscillations      = { [1]=0, [2]=0 },      -- (NEW) A→B→A undos
      threat_delta      = { [1]={up=0,down=0,flat=0}, [2]={up=0,down=0,flat=0} }, -- (NEW)

      buffs_used = { [1]={}, [2]={} },
      buff_draws = { [1]=0, [2]=0 },
      buff_assigned = { [1]=0, [2]=0 },
      shields_broken = { [1]=0, [2]=0 },
      shields_lost   = { [1]=0, [2]=0 },
      shield_turns_total_broken = { [1]=0, [2]=0 },
      captures = { [1]=0, [2]=0 },
      flag_picks = { [1]=0, [2]=0 },
      first_pick_turn = { [1]=nil, [2]=nil },
      token_pickups_move = { [1]=0, [2]=0 },
      token_respawn_hits = { [1]=0, [2]=0 },
      winner = nil, timeout=false,

      -- Telemetry / ROI
      buff_effect = { [1]=_init_buff_effect_bucket(), [2]=_init_buff_effect_bucket() },
      _shield_life_stamps = {}, -- color -> turn index when Extra Defend was applied
    },

    lastActorSide = nil,
    _draw_card = _draw_card,
    _give_card = _give_card,
    _reposition_token = _reposition_token,

    -- debug storage for files
    buff_debug = DEBUG_BUFF and {} or nil,
    ai_debug   = {},                 -- AILOG / log funnel
    action_log = {},                 -- per-reveal timeline rows (JSONL)
  }
end

------------------------------------------------------------
-- Dice & initiative
------------------------------------------------------------
local function roll_three_d6() return { math.random(1,6), math.random(1,6), math.random(1,6) } end
local function roll_initiative()
  -- (kept for future; not used in "P1 always first" mode)
  while true do
    local a = roll_three_d6(); local b = roll_three_d6()
    local sa = a[1]+a[2]+a[3]; local sb = b[1]+b[2]+b[3]
    if sa ~= sb then return (sa > sb) and 1 or 2 end
  end
end

local function sorted_desc3(d)
  local t = { d[1], d[2], d[3] }
  table.sort(t, function(a,b) return (a or 0)>(b or 0) end)
  return t
end

------------------------------------------------------------
-- Placement helpers
------------------------------------------------------------
local function occupant_at_any(world, rank, side)
  if side == 2 then for f=8,1,-1 do local sq=square(f,rank); if not occupant_at(world,sq) then return sq end end
  else for f=1,8 do local sq=square(f,rank); if not occupant_at(world,sq) then return sq end end end
end

------------------------------------------------------------
-- Stacks programming & reveal
------------------------------------------------------------
local function write_stack_next_n(dest, plan, n)
  local wrote = 0
  local first = 1
  while first<=6 and dest[first] and dest[first].revealed do first = first + 1 end
  local idx = first
  while idx<=6 and wrote<n do
    local want = (plan[wrote+1] or "BLANK"):upper()
    dest[idx] = { face=want, revealed=false }
    wrote = wrote + 1
    idx = idx + 1
  end
  return wrote
end

local function reveal_next_nonblank(stack)
  for i=1,6 do
    local cell = stack[i]
    if cell and (not cell.revealed) and (cell.face ~= "BLANK" and cell.face ~= "ACTION") then
      cell.revealed = true
      return true, cell.face
    end
  end
  return false, nil
end

local function count_unrevealed_real(stack)
  local n=0
  for i=1,6 do
    local c=stack[i]
    if c and not c.revealed and c.face ~= "BLANK" and c.face ~= "ACTION" then n=n+1 end
  end
  return n
end

------------------------------------------------------------
-- Flag helpers & win check
------------------------------------------------------------
try_auto_flag = function(world, color)
  local p = world.pieces[color]; if not p or p.loc~="BOARD" or not p.square then return end
  local _, rank = parseSquare(p.square); if not rank then return end
  local before = p.hasFlag
  if (color=="Blue" or color=="Pink" or color=="Purple") then
    if rank == 1 then p.hasFlag = true end
  else
    if rank == 8 then p.hasFlag = true end
  end
  if (not before) and p.hasFlag then
    local side = side_of_color(color)
    world.stats.flag_picks[side] = world.stats.flag_picks[side] + 1
    if not world.stats.first_pick_turn[side] then
      world.stats.first_pick_turn[side] = world.stats.turns + 1
    end
  end
end

local function winner_or_nil(world)
  local function sideWins(side)
    local targetRank = (side==1) and 1 or 8
    local colors   = (side==1) and COLORS_P1 or COLORS_P2
    for _,c in ipairs(colors) do
      local p = world.pieces[c]
      if p and p.hasFlag and p.loc=="BOARD" and p.square then
        local _,r = parseSquare(p.square)
        if r == targetRank then
          return (side==2) and "COMPUTER" or "PLAYER 1"
        end
      end
    end
    return nil
  end
  return sideWins(1) or sideWins(2)
end

------------------------------------------------------------
-- Movement / attacks / token pickup (direct move utility)
------------------------------------------------------------
local function move_piece_to(world, color, toSq)
  local p = world.pieces[color]; if not p then return end
  if toSq and toSq~="None" then
    local prev = p.square
    p.loc = "BOARD"; p.square = toSq
    -- keep step history in direct move as well
    p._lastStepFrom, p._lastStepTo = prev, toSq

    try_auto_flag(world, color)
    if world.token.square == p.square then
      local side = side_of_color(color)
      local name = world._draw_card(world.buff)
      world._give_card(world, side, name, true, "MovePickup")
      world._reposition_token(world)
      world.stats.token_pickups_move[side] = world.stats.token_pickups_move[side] + 1
    end
  end
end

local function send_home(world, color)
  local p = world.pieces[color]; if not p then return end
  -- If the piece is going home while shielded, credit its Extra Defend life before clearing
  if p.hasShield then _credit_ed_life(world, p, side_of_color(color)) end
  p.loc="HOME"; p.square=nil; p.hasShield=false; p._shieldStamp=nil; p.hasFlag=false
end

-- (FIX) forbid friendly fire; count Extra Defend prevention
local function resolve_attack(world, attackerColor, targetColorOrSq)
  -- Figure out the victim (piece id or a square's occupant)
  local victim = nil
  if type(targetColorOrSq) == "string" then
    if world.pieces[targetColorOrSq] then
      victim = targetColorOrSq
    else
      victim = occupant_at(world, targetColorOrSq)
    end
  end
  -- Invalid/empty or friendly target → no hit
  if not victim then return {hit=false} end
  if side_of_color(victim) == side_of_color(attackerColor) then
    return {hit=false}  -- friendly fire disallowed
  end

  local vp = world.pieces[victim]
  local atkSide = side_of_color(attackerColor)
  local defSide = side_of_color(victim)

  -- If victim is shielded: break shield, credit Extra Defend life, record stats, no send-home.
  if vp.hasShield then
    local age = 0
    if vp._shieldStamp then age = math.max(0, (world.stats.turns - vp._shieldStamp)) end

    vp.hasShield = false
    _credit_ed_life(world, vp, defSide)

    world.stats.shields_broken[atkSide] = world.stats.shields_broken[atkSide] + 1
    world.stats.shields_lost[defSide]   = world.stats.shields_lost[defSide] + 1
    world.stats.shield_turns_total_broken[defSide] =
      world.stats.shield_turns_total_broken[defSide] + age

    -- (NEW) ROI: Extra Defend prevented a send-home event
    world.stats.buff_effect[defSide].ExtraDefend.preventedSendHome =
      (world.stats.buff_effect[defSide].ExtraDefend.preventedSendHome or 0) + 1

    return {hit=true, shieldBroken=true, sentHome=false, victim=victim}
  end

  -- No shield: send the victim home and count a capture for attacker.
  send_home(world, victim)
  world.stats.captures[atkSide] = world.stats.captures[atkSide] + 1

  return {hit=true, shieldBroken=false, sentHome=true, victim=victim}
end

--endregion Part 1/3

--#region Part2
-- sim.lua (v3, Part 2/3)

------------------------------------------------------------
-- Snapshot builders (structured)
------------------------------------------------------------
local function _count_hand_types(t)
  local n=0; for _,c in pairs(t or {}) do n=n+c end; return n
end

local function _flags_map(world)
  local F={}
  for _,c in ipairs({"Green","Yellow","Orange","Blue","Pink","Purple"}) do
    F[c]=world.pieces[c].hasFlag and true or false
  end
  return F
end

local function _shields_map(world)
  local S={}
  for _,c in ipairs({"Green","Yellow","Orange","Blue","Pink","Purple"}) do
    S[c]=world.pieces[c].hasShield and true or false
  end
  return S
end

local function _stack_dual_shape(stack)
  local arr={}
  for i=1,6 do
    local c=stack[i]
    if c then arr[i]={ face=c.face, revealed=c.revealed } end
  end
  arr.stack = {}
  for i=1,6 do arr.stack[i]=arr[i] end
  return arr
end

local function build_status_for_ai_full(world, difficulty)
  local P = {}
  for _,c in ipairs({"Blue","Pink","Purple","Green","Yellow","Orange"}) do
    local e = world.pieces[c] or {}
    P[c] = {
      loc=e.loc, square=e.square,
      hasFlag=e.hasFlag, hasShield=e.hasShield,
      flag=e.hasFlag, shield=e.hasShield
    }
  end

  local stacks = {
    P2 = {
      Blue   = _stack_dual_shape(world.stacks.P2.Blue   or {}),
      Pink   = _stack_dual_shape(world.stacks.P2.Pink   or {}),
      Purple = _stack_dual_shape(world.stacks.P2.Purple or {}),
    },
    P1 = {
      Green  = _stack_dual_shape(world.stacks.P1.Green  or {}),
      Yellow = _stack_dual_shape(world.stacks.P1.Yellow or {}),
      Orange = _stack_dual_shape(world.stacks.P1.Orange or {}),
    }
  }

  local diceSorted = sorted_desc3(world.dice)

  return {
    meta = {
      round = world.round,
      phase = world.phase,
      currentTurn = world.firstPlayer,
      difficulty = difficulty,
      finish = {
        P2 = {"A8","B8","C8","D8","E8","F8","G8","H8"},
        P1 = {"A1","B1","C1","D1","E1","F1","G1","H1"},
      },
      homes = {
        P2 = {"A8","B8","C8","D8","E8","F8","G8","H8"},
        P1 = {"A1","B1","C1","D1","E1","F1","G1","H1"},
      },
      -- P2 is “self” for the full builder
      playerConst = { self = world.matchConst.P2, opponent = world.matchConst.P1 },
    },
    dice = { world.dice[1], world.dice[2], world.dice[3] },
    diceValues = { diceSorted[1], diceSorted[2], diceSorted[3] },
    token = { square = world.token.square },
    pieces = P,
    flags = _flags_map(world),
    shields = _shields_map(world),
    stacks = stacks,
    buffs = {
      zones      = world.buffs.zones,
      zoneStatus = world.buffs.zoneStatus,
      hand       = {
        P1 = _count_hand_types(world.buff.hand.P1),
        P2 = _count_hand_types(world.buff.hand.P2),
      },
      handTypes  = {
        P1 = copy_shallow(world.buff.hand.P1),
        P2 = copy_shallow(world.buff.hand.P2),
      },
    },
    p2_buff_hand_count = _count_hand_types(world.buff.hand.P2),
    p1_buff_hand_count = _count_hand_types(world.buff.hand.P1),
  }
end


local P1_TO_P2 = { Green="Blue", Yellow="Pink",  Orange="Purple" }
local P2_TO_P1 = { Blue="Green", Pink="Yellow", Purple="Orange" }

-- mirror helpers so side 1's buff API targets the right real pieces
local function _mirror_color_for_side1_in(c)
  -- AI on side 1 speaks in Blue/Pink/Purple; map to real Green/Yellow/Orange
  return (_AIENV.side == 1 and P2_TO_P1[c]) or c
end

local function _mirror_zone_status_for_side1_out(zoneStatus)
  if _AIENV.side ~= 1 then
    local out = {}; for k,v in pairs(zoneStatus) do out[k]=v end; return out
  end
  -- re-key so side-1 AI “sees” its own pieces under Blue/Pink/Purple
  return {
    Blue   = zoneStatus.Green,
    Pink   = zoneStatus.Yellow,
    Purple = zoneStatus.Orange,
    Green  = zoneStatus.Blue,
    Yellow = zoneStatus.Pink,
    Orange = zoneStatus.Purple,
  }
end

local function build_status_for_ai_mirrored(world, difficulty, local_only_p2)
local st = { meta = { round=world.round, phase=world.phase, currentTurn=world.firstPlayer, difficulty=difficulty,
                        finish = { P2 = { "A8","B8","C8","D8","E8","F8","G8","H8" }, P1 = { "A1","B1","C1","D1","E1","F1","G1","H1" } },
                        homes  = { P2 = { "A8","B8","C8","D8","E8","F8","G8","H8" }, P1 = { "A1","B1","C1","D1","E1","F1","G1","H1" } },
                        -- NEW: per-match, per-side constant (P1 is “self” for the mirrored builder)
                        playerConst = { self = world.matchConst.P1, opponent = world.matchConst.P2 },
                      } }

  local diceSorted = sorted_desc3(world.dice)
  st.dice  = { world.dice[1], world.dice[2], world.dice[3] }
  st.diceValues = { diceSorted[1], diceSorted[2], diceSorted[3] }
  st.token = { square = world.token.square and mirror_square(world.token.square) or nil }

  st.pieces = {}
  for g,p2 in pairs(P1_TO_P2) do
    local e = world.pieces[g] or {}
    st.pieces[p2] = { loc=e.loc, square=(e.square and mirror_square(e.square) or nil), hasFlag=e.hasFlag, hasShield=e.hasShield, flag=e.hasFlag, shield=e.hasShield }
  end
  for b,p1 in pairs(P2_TO_P1) do
    local e = world.pieces[b] or {}
    st.pieces[p1] = { loc=e.loc, square=(e.square and mirror_square(e.square) or nil), hasFlag=e.hasFlag, hasShield=e.hasShield, flag=e.hasFlag, shield=e.hasShield }
  end

  st.stacks = { P2 = {}, P1 = {} }
  local function dual(src) return _stack_dual_shape(src or {}) end
  st.stacks.P2.Blue   = dual(world.stacks.P1.Green)
  st.stacks.P2.Pink   = dual(world.stacks.P1.Yellow)
  st.stacks.P2.Purple = dual(world.stacks.P1.Orange)
  if not local_only_p2 then
    st.stacks.P1.Green  = dual(world.stacks.P2.Blue)
    st.stacks.P1.Yellow = dual(world.stacks.P2.Pink)
    st.stacks.P1.Orange = dual(world.stacks.P2.Purple)
  end

  st.buffs = { zones={}, zoneStatus={}, hand = { P1=_count_hand_types(world.buff.hand.P2), P2=_count_hand_types(world.buff.hand.P1) } }
  for g,p2 in pairs(P1_TO_P2) do
    st.buffs.zones[p2]      = world.buffs.zones[g]
    st.buffs.zoneStatus[p2] = world.buffs.zoneStatus[g]
  end
  for b,p1 in pairs(P2_TO_P1) do
    st.buffs.zones[p1]      = world.buffs.zones[b]
    st.buffs.zoneStatus[p1] = world.buffs.zoneStatus[b]
  end
  do
  local z, zs = {}, {}
  for k,v in pairs(st.buffs.zones)      do z[k]  = v end
  for k,v in pairs(st.buffs.zoneStatus) do zs[k] = v end
  st.buffs.zones, st.buffs.zoneStatus = z, zs
end

  st.buffs.handTypes = { P1=copy_shallow(world.buff.hand.P2), P2=copy_shallow(world.buff.hand.P1) }

  st.flags  = {}
  st.shields= {}
  for g,p2 in pairs(P1_TO_P2) do st.flags[p2]=world.pieces[g].hasFlag; st.shields[p2]=world.pieces[g].hasShield end
  for b,p1 in pairs(P2_TO_P1) do st.flags[p1]=world.pieces[b].hasFlag; st.shields[p1]=world.pieces[b].hasShield end

st.p2_buff_hand_count = _count_hand_types(world.buff.hand.P2)
st.p1_buff_hand_count = _count_hand_types(world.buff.hand.P1)


  return st
end

------------------------------------------------------------
-- Respawns at start of round
------------------------------------------------------------
local function _respawn_left_to_right(world)
  local function place_in_row(row, leftToRight, colorList)
    local files = leftToRight and {1,2,3,4,5,6,7,8} or {8,7,6,5,4,3,2,1}
    for _,c in ipairs(colorList) do
      local p = world.pieces[c]
      if p.loc=="HOME" then
        for _,f in ipairs(files) do
          local sq = square(f,row)
          if not occupant_at(world, sq) then
            p.loc="BOARD"; p.square=sq; p._lastStepFrom=nil; p._lastStepTo=nil
            break
          end
        end
      end
    end
  end
  place_in_row(1, true,  COLORS_P1)
  place_in_row(8, false, COLORS_P2)
end

local function _reset_stacks_for_new_round(world)
  world.stacks = { P2 = { Blue={}, Pink={}, Purple={} }, P1 = { Green={}, Yellow={}, Orange={} } }
end

------------------------------------------------------------
-- AI glue
------------------------------------------------------------
_G.JSON = JSON
local AI, RR_AI = _G.AI or {}, _G.RR_AI or {}
_G.AI, _G.RR_AI = AI, RR_AI
local function safe_dofile(path) pcall(function() dofile(path) end) end
safe_dofile("AI Code.lua")

-- TTS Global.call shim: expose buff API to AI
local world_ref = nil
_G._AIENV = _G._AIENV or {}
_G.Global = _G.Global or {}

function Global.call(name, arg)
  if not world_ref then return {} end
  local alias = {
    ListBuffCardsInHand = "RR_ListBuffCardsInHand",
    ReadBuffZone        = "RR_ReadBuffZone",
    ReadBuffZoneStatus  = "RR_ReadBuffZoneStatus",
    Read_BuffZoneStatus = "RR_Read_BuffZoneStatus",
    PlaceBuffByName     = "RR_PlaceBuffByName",
    PlaceFirstBuff      = "RR_PlaceFirstBuff",
  }
  name = alias[name] or name

  if name == "RR_ListBuffCardsInHand" then
    local sideStr = (_AIENV.side == 2) and "P2" or "P1"
    local out = {}
    local hand  = world_ref.buff.hand[sideStr] or {}
    local fresh = world_ref.buff.fresh[sideStr] or {}
    for t,cnt in pairs(hand) do
      local usable = (cnt or 0) - (fresh[t] or 0)
      for _=1, math.max(0, usable) do out[#out+1] = { type = t } end
    end
    return out
  end

  if name == "RR_ReadBuffZone" then
    local colorIn = (type(arg)=="table" and arg.color) or arg
    local color   = _mirror_color_for_side1_in(colorIn)
    local z  = (world_ref.buffs.zones[color] or "None")
    local zs = (world_ref.buffs.zoneStatus[color] or "None")
    if z == "None" then return "None" end
    if zs == "Revealed" then return z end
    return "Face down"
  end

if name == "RR_ReadBuffZoneStatus" or name == "RR_Read_BuffZoneStatus" then
  local out = _mirror_zone_status_for_side1_out(world_ref.buffs.zoneStatus or {})
  local copy = {}
  for k,v in pairs(out) do copy[k] = v end
  return copy
end

  if name == "RR_PlaceBuffByName" then
    local colorIn  = arg and arg.color
    local buffName = _canon_buff(arg and arg.name)
    if not colorIn or not buffName or buffName=="None" then return false end

    local color = _mirror_color_for_side1_in(colorIn) -- map to real piece if side 1
    local side  = side_of_color(color)

    if world_ref.buffs.zones[color] ~= "None" then
      _buff_log_assign_failure(world_ref, side, color, buffName, "zone_occupied", "Global.call:RR_PlaceBuffByName")
      return false
    end

    local function _can_assign_local(world, side, nm)
      local hand  = (side==2) and world.buff.hand.P2 or world.buff.hand.P1
      local fresh = (side==2) and world.buff.fresh.P2 or world.buff.fresh.P1
      return ((hand[nm] or 0) - (fresh[nm] or 0)) > 0
    end
    if not _can_assign_local(world_ref, side, buffName) then
      _buff_log_assign_failure(world_ref, side, color, buffName, "not_usable_or_fresh_lock", "Global.call:RR_PlaceBuffByName")
      return false
    end

    local function _consume_for_assignment_local(world, side, nm)
      local hand  = (side==2) and world.buff.hand.P2 or world.buff.hand.P1
      if ((hand[nm] or 0) <= 0) then return false end
      hand[nm] = hand[nm] - 1
      world.stats.buff_assigned[side] = (world.stats.buff_assigned[side] or 0) + 1
      return true
    end
    if not _consume_for_assignment_local(world_ref, side, buffName) then
      _buff_log_assign_failure(world_ref, side, color, buffName, "consume_failed", "Global.call:RR_PlaceBuffByName")
      return false
    end

    world_ref.buffs.zones[color]      = buffName
    world_ref.buffs.zoneStatus[color] = "Unrevealed"
    if DEBUG_BUFF and world_ref.buff_debug then
      world_ref.buff_debug[#world_ref.buff_debug+1] = {
        event="assigned_to_zone", source="Global.call:RR_PlaceBuffByName",
        side=(side==2) and "P2" or "P1", color=color, name=buffName
      }
    end
    return true
  end

  if name == "RR_PlaceFirstBuff" then
    local colorIn = (type(arg)=="table" and arg.color) or arg
    if not colorIn or colorIn=="None" then return false end
    local color = _mirror_color_for_side1_in(colorIn)
    if world_ref.buffs.zones[color] ~= "None" then return false end
    local side = side_of_color(color)

    for _,nm in ipairs(BUFF_TYPES) do
      if _can_assign(world_ref, side, nm) and _consume_for_assignment(world_ref, side, nm) then
        world_ref.buffs.zones[color]      = nm
        world_ref.buffs.zoneStatus[color] = "Unrevealed"
        _buffdbg(world_ref, {
          event="assigned_to_zone", source="Global.call:RR_PlaceFirstBuff",
          side=side, side_str=_side_str(side), color=color, name=nm
        })
        return true
      end
    end
    return false
  end

  return {}
end

-- Capture AILOG / log into world.ai_debug
_G.AILOG = function(obj)
  if world_ref then
    local e = copy_shallow(obj or {})
    e._ts_turn = world_ref.stats and world_ref.stats.turns or 0
    e._ts_round = world_ref.round
    push(world_ref.ai_debug, e)
  end
end
-- Wrap log() (keep printing quiet, but store)
local _orig_log = log
log = function(x)
  if world_ref then
    push(world_ref.ai_debug, { msg=tostring(x), _ts_turn=world_ref.stats and world_ref.stats.turns or 0, _ts_round=world_ref.round })
  end
  if _orig_log and _orig_log ~= log then pcall(_orig_log, x) end
end

-- Console summary of the whole run (wins + quick bias-y deltas)
local function print_overall_console_stats(agg)
  local function rate(a,b) if (b or 0) <= 0 then return 0 end return a/b end
  local function pct(a,b)  if (b or 0) <= 0 then return "0%" end return string.format("%.1f%%", 100*rate(a,b)) end

  local games   = agg.matches
  local p1w     = agg.wins.P1
  local p2w     = agg.wins.P2
  local to      = agg.wins.TIMEOUT
  local nonTO   = math.max(0, games - to)

  local p1Hit   = rate(agg.attacks_hits[1], agg.attacks_attempted[1])
  local p2Hit   = rate(agg.attacks_hits[2], agg.attacks_attempted[2])
  local p1Waste = rate(agg.wasted_attacks[1], agg.attacks_attempted[1])
  local p2Waste = rate(agg.wasted_attacks[2], agg.attacks_attempted[2])
  local p1KD    = rate(agg.captures[1], agg.captures[2])
  local p2KD    = rate(agg.captures[2], agg.captures[1])
  local p1Rev   = rate(agg.reveals_used[1], agg.reveals_avail[1])
  local p2Rev   = rate(agg.reveals_used[2], agg.reveals_avail[2])
  local p1ShLf  = rate(agg.shield_turns_total_broken[1], agg.shields_lost[1])
  local p2ShLf  = rate(agg.shield_turns_total_broken[2], agg.shields_lost[2])

  print("")
  print(("=== OVERALL (%d games) ==="):format(games))
  print(("Wins  P1=%d (%s of all)  P2=%d (%s of all)  TO=%d"):format(
        p1w, pct(p1w, games), p2w, pct(p2w, games), to))
  if nonTO > 0 then
    print(("Win rate (excl. TO):  P1=%s  P2=%s"):format(pct(p1w, nonTO), pct(p2w, nonTO)))
  end
  print(("Avg Rounds=%.2f  Avg Turns=%.2f"):format(rate(agg.rounds, games), rate(agg.turns, games)))

  -- Quick bias indicators (positive means P1 edge)
  print(("HitRate     P1=%.3f  P2=%.3f  Diff=%.3f"):format(p1Hit, p2Hit, p1Hit - p2Hit))
  print(("WastedAtk   P1=%.3f  P2=%.3f  Diff=%.3f"):format(p1Waste, p2Waste, p1Waste - p2Waste))
  print(("K/D         P1=%.3f  P2=%.3f  Diff=%.3f"):format(p1KD, p2KD, p1KD - p2KD))
  print(("RevealUse   P1=%.3f  P2=%.3f  Diff=%.3f"):format(p1Rev, p2Rev, p1Rev - p2Rev))
  print(("ShieldLife  P1=%.2f  P2=%.2f  Diff=%.2f"):format(p1ShLf, p2ShLf, p1ShLf - p2ShLf))
  print(("Progress    P1=%d  P2=%d  Diff=%d"):format(
        agg.progress_total[1], agg.progress_total[2], (agg.progress_total[1] or 0) - (agg.progress_total[2] or 0)))
  print(("Token luck  MovePickups P1=%d P2=%d  RespawnHits P1=%d P2=%d"):format(
        agg.token_pickups_move[1], agg.token_pickups_move[2],
        agg.token_respawn_hits[1], agg.token_respawn_hits[2]))
  print(("ThreatDiff  P1=%d/%d/%d  P2=%d/%d/%d  (up/down/flat)"):format(
        agg.threat_delta[1].up, agg.threat_delta[1].down, agg.threat_delta[1].flat,
        agg.threat_delta[2].up, agg.threat_delta[2].down, agg.threat_delta[2].flat))
end



local function call_ai(req)
  local fn = (AI and AI.AI_Request) or (RR_AI and RR_AI.AI_Request) or _G.AI_Request
  if type(fn) ~= "function" then return nil end
  if type(req) ~= "table" then return nil end

  -- keep last status around for tools that look at it
  _AIENV._last_status = req.status

  -- === RNG injection (centralized) ===
  -- Uses your globals: SAME_SEED, GAME_SEED (already defined near the top).
  -- Side is taken from _AIENV.side (you set this right before each call).
  local sideU = tostring(_AIENV.side or req.player or req.side or "P2"):upper()
  local turns = (world_ref and world_ref.stats and world_ref.stats.turns) or 0
  local round = (world_ref and world_ref.round) or 1

  if req.rng == nil then
    req.rng = {
      same_seed  = SAME_SEED,                 -- true=identical P1/P2 stream
      game_seed  = GAME_SEED,                 -- per-game base seed from sim
      turn       = string.format("%s#R%dT%d", tostring(req.type or "Unknown"), round, turns),
      ai_salt    = SAME_SEED and "" or sideU, -- different streams when SAME_SEED=false
      -- NEW: per-match constant for this side (stable for the whole match)
      match_const = (world_ref and world_ref.matchConst and ((sideU=="P2") and world_ref.matchConst.P2 or world_ref.matchConst.P1)) or 0,
    }
  end
  -- === end RNG injection ===

  local ok, res = pcall(fn, req)
  if ok then return res end
  return nil
end


------------------------------------------------------------
-- Helpers: plan legality & resilient fallback
------------------------------------------------------------
local function plan_sanitize_and_fill(world, side, raw)
  local res = {
    color = raw.color,
    n     = tonumber(raw.n or 0) or 0,
    plan  = {},
    wantBuff = _canon_buff(
             raw.wantBuff or raw.buffKind or raw.buff or
             raw.buffName or raw.buff_type or raw.buffType or
             raw.useBuffKind or "None"
           )
  }

  local validColors = (side==2) and {Blue=true, Pink=true, Purple=true} or {Green=true, Yellow=true, Orange=true}
  if not validColors[res.color] then
    if side==1 and (res.color=="Blue" or res.color=="Pink" or res.color=="Purple") then
      local map = { Blue="Green", Pink="Yellow", Purple="Orange" }
      res.color = map[res.color]
    else
      res.color = (side==2) and "Blue" or "Green"
    end
  end

  local pool = (world.planDicePool and world.planDicePool[side]) or {}
  local function remove_die_once(v)
    for i=1,#pool do if pool[i]==v then table.remove(pool,i); return true end end
    return false
  end

  local stacks = (side==2) and world.stacks.P2 or world.stacks.P1
  local stk    = stacks[res.color] or {}
  local function stack_first_unrevealed_index(stk)
    local i=1
    while i<=6 and stk[i] and stk[i].revealed do i=i+1 end
    return i
  end
  local nextIdx   = stack_first_unrevealed_index(stk)
  local slotsLeft = math.max(0, 7 - nextIdx)

  local function per_piece_caps_left(stk)
    local m,a,d=0,0,0
    for i=1,6 do
      local c=stk[i]
      if c and not c.revealed then
        local k=(c.face or "ACTION"):upper()
        if k=="MOVE" then m=m+1
        elseif k=="ATTACK" then a=a+1
        elseif k=="DEFEND" then d=d+1 end
      end
    end
    return math.max(0,3-m), math.max(0,2-a), math.max(0,1-d)
  end
  local capM, capA, capD = per_piece_caps_left(stk)
  local capSpace = capM + capA + capD

  local function best_die_that_fits()
    local best = 0
    for _,d in ipairs(pool) do
      if d>best and d<=slotsLeft and d<=capSpace then best=d end
    end
    return best
  end

  if res.n<=0 or res.n>6 or res.n>slotsLeft or res.n>capSpace or not remove_die_once(res.n) then
    local fix = best_die_that_fits()
    if fix>0 then
      res.n = fix
      remove_die_once(fix)
    else
      res.n = 0
    end
  end

  local rawPlan = raw.plan or {}
  for i=1,res.n do res.plan[i] = (tostring(rawPlan[i] or "BLANK")):upper() end
  local function countKind(kind)
    local n=0; for i=1,res.n do if res.plan[i]==kind then n=n+1 end end; return n end
  local function room(kind)
    if kind=="MOVE" then return capM - countKind("MOVE")
    elseif kind=="ATTACK" then return capA - countKind("ATTACK")
    else return capD - countKind("DEFEND") end
  end
  for i=1,res.n do
    local k=res.plan[i]
    if not (k=="MOVE" or k=="ATTACK" or k=="DEFEND") then res.plan[i]="BLANK" end
  end
  for i=1,res.n do
    if res.plan[i]=="BLANK" then
      if room("MOVE")>0 then res.plan[i]="MOVE"
      elseif room("ATTACK")>0 then res.plan[i]="ATTACK"
      elseif room("DEFEND")>0 then res.plan[i]="DEFEND"
      else break end
    end
  end
  local real=0; for i=1,res.n do if res.plan[i]~="BLANK" then real=real+1 end end
  res.n = real

  if res.wantBuff~="None" and not _can_assign(world, side, res.wantBuff) then
    local h = _hand_for(world, side); local fr = _fresh_for(world, side)
    _buffdbg(world, {
      event="wantBuff_rejected", side=side, side_str=_side_str(side),
      color=res.color, name=res.wantBuff, reason="not_usable_or_fresh_lock",
      have=(h[res.wantBuff] or 0), fresh=(fr[res.wantBuff] or 0),
      usable=math.max(0,(h[res.wantBuff] or 0)-(fr[res.wantBuff] or 0))
    })
    -- Keep res.wantBuff; _apply_prep_pick will attempt and log final reason
  end

  return res
end

------------------------------------------------------------
-- Turnline Writer (one line per T#, underscore keys)
------------------------------------------------------------
local FLAG_STR   = { [true]="f", [false]="nf" }
local SHIELD_STR = { [true]="s", [false]="ns" }
local COLORS_ALL = {"Blue","Pink","Purple","Green","Yellow","Orange"}

local function _esc_val(v)
  if v == nil then return "None" end
  if type(v) == "boolean" then return v and "true" or "false" end
  return tostring(v)
end

local function _fmt_kv_line(map)
  if not map or (next(map) == nil) then return "No change" end
  local keys = {}
  for k,_ in pairs(map) do keys[#keys+1] = k end
  table.sort(keys, function(a,b) return a < b end)
  local out = {}
  for i=1,#keys do
    local k = keys[i]
    out[#out+1] = k .. "=" .. _esc_val(map[k])
  end
  return table.concat(out, " ")
end

local function build_struct_snapshot(world)
  local t = {
    round = world.round,
    firstPlayer = world.firstPlayer,
    phase = world.phase,
    dice = { world.dice[1], world.dice[2], world.dice[3] },
    hands = {
      P1 = _count_hand_types(world.buff.hand.P1),
      P2 = _count_hand_types(world.buff.hand.P2),
    },
    token = world.token.square,
    pieces = {}
  }
  for _,c in ipairs({"Green","Yellow","Orange","Blue","Pink","Purple"}) do
    local p = world.pieces[c] or {}
    t.pieces[c] = {
      loc=p.loc, square=p.square, flag=p.hasFlag, shield=p.hasShield,
      zone=world.buffs.zones[c], zstat=world.buffs.zoneStatus[c]
    }
  end
  return t
end

local function _flatten_struct(S)
  local flat = {}
  local d = S.dice or {}
  flat.dice_1 = tonumber(d[1] or 0) or 0
  flat.dice_2 = tonumber(d[2] or 0) or 0
  flat.dice_3 = tonumber(d[3] or 0) or 0
  flat.firstPlayer = S.firstPlayer
  flat.phase = S.phase
  flat.round = S.round
  flat.hands_P1 = S.hands and S.hands.P1 or 0
  flat.hands_P2 = S.hands and S.hands.P2 or 0
  flat.token = S.token or "None"

  for _,c in ipairs(COLORS_ALL) do
    local p = S.pieces[c] or {}
    flat[c.."_loc"] = p.loc or "HOME"
    flat[c.."_sq"]  = p.square or "None"
    flat[c.."_f"]   = FLAG_STR[p.flag == true] or "nf"
    flat[c.."_s"]   = SHIELD_STR[p.shield == true] or "ns"
    flat[c.."_z"]   = p.zone or "None"
    flat[c.."_zs"]  = p.zstat or "None"
  end

  return flat
end

local function _diff_flat(prev, curr)
  if not prev then return curr end
  local out = {}
  for k,v in pairs(curr) do
    if prev[k] ~= v then out[k] = v end
  end
  return out
end

local function new_writer(fh)
  local w = {
    f = fh, turn_index = 0, prev_flat = nil
  }
  function w:_w(s)
    if not WRITE_MATCH_LOG then return end
    self.f:write(s)
    if s:sub(-1) ~= "\n" then self.f:write("\n") end
    self.f:flush()
  end


  function w:header(meta)
    self:_w(string.format("=== BattlePlan Sim Log v%s ===", tostring(LOG_VERSION)))
    if meta then
      self:_w(string.format("Run: %s", meta.run or "N/A"))
      self:_w(string.format("Config: WRITE_MATCH_LOG=%s JSON_BLOCKS=%s DEBUG_BUFF=%s",
        tostring(WRITE_MATCH_LOG), tostring(INCLUDE_JSON_BLOCKS_IN_MATCH_LOG), tostring(DEBUG_BUFF)))
      self:_w(string.format("Difficulties: %s", meta.diff or "N/A"))
      self:_w(string.format("Seed base: %s  RerollEachMatch=%s", tostring(SEED_BASE), tostring(REROLL_SEED_EACH_MATCH)))
      self:_w(string.format("Timestamp: %s", os.date("!%Y-%m-%dT%H:%M:%SZ")))
    end

    self:_w([[
--- LOG_GUIDE_START ---
Record types (one per line)
  Pair P1=<int> P2=<int> Games=<int>  → start of a difficulty pairing batch
  MatchN                                → start of match N (global index)
  Round N                               → start of round N
  <Section>:                            → section header (Placement | Battle)
  T0: <k=v ...>                         → initial full snapshot (all keys)
  Tn: <k=v ...>                         → delta from previous tick (only changed keys); may be "No change"
  Plan: <k=v ...>                       → full snapshot after the Plan phase (all keys)

Key/value tokens (sorted alphabetically on each line)
  round=<int>       firstPlayer=<1|2>     phase=<string>
  dice_1=<1..6>     dice_2=<1..6>         dice_3=<1..6>
  hands_P1=<int>    hands_P2=<int>        token=<A1..H8|None>

Per-piece fields (for each: Blue, Pink, Purple, Green, Yellow, Orange)
  <Color>_loc=HOME|BOARD   <Color>_sq=<square|None>
  <Color>_f=f|nf           <Color>_s=s|ns
  <Color>_z=<buff|None>    <Color>_zs=Unrevealed|Revealed|None

Blocks optionally appended after each match when JSON blocks enabled:
  --- MATCH_SUMMARY_START (Match i) --- JSON --- MATCH_SUMMARY_END ---
  --- ACTION_TIMELINE_JSONL_START (Match i) --- JSONL --- ACTION_TIMELINE_JSONL_END ---
  --- BUFF_DEBUG_JSONL_START (Match i) --- JSONL --- BUFF_DEBUG_JSONL_END ---
  --- AI_DEBUG_JSONL_START (Match i) --- JSONL --- AI_DEBUG_JSONL_END ---

After all matches in the file:
  --- ALL_MATCHES_SUMMARY_START --- JSON --- ALL_MATCHES_SUMMARY_END ---
--- LOG_GUIDE_END ---
]])
  end

  function w:pair_header(d1, d2, games)
    self:_w("")
    self:_w(string.format("Pair P1=%d P2=%d Games=%d", d1 or -1, d2 or -1, games or 1))
  end

  function w:match(n) self:_w(("Match%d"):format(tonumber(n) or 1)) end

  function w:T0(full_struct)
    self.turn_index = 0
    self.prev_flat = _flatten_struct(full_struct)
    self:_w(("T0: %s"):format(_fmt_kv_line(self.prev_flat)))
  end

  function w:round(n)
    self:_w("")
    self:_w(("Round %d"):format(tonumber(n) or 1))
  end

  function w:section(name)
    self:_w("")
    self:_w(tostring(name)..":")
  end

  function w:section_full(name, full_struct)
    self:_w("")
    local flat = _flatten_struct(full_struct)
    self:_w(("%s: %s"):format(tostring(name), _fmt_kv_line(flat)))
    self.prev_flat = flat
  end

  function w:tick(curr_struct)
    self.turn_index = self.turn_index + 1
    local curr_flat = _flatten_struct(curr_struct)
    local d = _diff_flat(self.prev_flat, curr_flat)
    self:_w(("T%d: %s"):format(self.turn_index, _fmt_kv_line(d)))
    self.prev_flat = curr_flat
  end

  -- Append a JSON block bounded by START/END markers (no-op if disabled)
  function w:append_json_block(name, tbl)
    if not INCLUDE_JSON_BLOCKS_IN_MATCH_LOG then return end
    self:_w("")
    self:_w(("--- %s_START ---"):format(name))
    self:_w(JSON.encode(tbl))
    self:_w(("--- %s_END ---"):format(name))
  end

  -- Dump an array of JSON objects, one per line, bounded by markers (no-op if disabled)
  function w:dump_jsonl(name, arr)
    if not INCLUDE_JSON_BLOCKS_IN_MATCH_LOG then return end
    self:_w("")
    self:_w(("--- %s_START ---"):format(name))
    if type(arr)=="table" then
      for i=1,#arr do self:_w(JSON.encode(arr[i])) end
    end
    self:_w(("--- %s_END ---"):format(name))
  end

  return w
end

local function _legal_home_sq_or_fallback(world, side, sq)
  local f,r = parseSquare(sq or "")
  local wantR = (side==2) and 8 or 1
  if r ~= wantR or occupant_at(world, sq) then
    return occupant_at_any(world, wantR, side)
  end
  return sq
end

-- remove one occurrence of a value from a list
local function _remove_one(list, value)
  for i=1,#list do
    if list[i]==value then table.remove(list, i); return true end
  end
  return false
end

------------------------------------------------------------
-- Placement (turn order) — BOTH via AI (P1 mirrored)
------------------------------------------------------------
local function placement_in_turn_order(world, firstPlayer, diffP1, diffP2, writer)
  world.phase = "Piece placement"
  local p1_left = { "Green", "Yellow", "Orange" }
  local p2_left = { "Blue", "Pink", "Purple" }
  local turn = firstPlayer

  while (#p1_left > 0) or (#p2_left > 0) do
    if turn == 1 and #p1_left > 0 then
      _AIENV.side = 1
      local statusM = build_status_for_ai_mirrored(world, diffP1, false)
      statusM.meta.currentTurn = 1
      local resM = call_ai({ type="Placement", status=statusM }) or {}

      local colorP2 = resM.color or "Blue"
      local sqM     = resM.square or mirror_square(occupant_at_any(world, 1, 1) or square(1,1))
      local colorP1 = P2_TO_P1[colorP2]
      if not _remove_one(p1_left, colorP1) then
        colorP1 = table.remove(p1_left, 1)
      end
      local localSq = mirror_square(sqM)
      localSq = _legal_home_sq_or_fallback(world, 1, localSq)
      world.pieces[colorP1].loc="BOARD"; world.pieces[colorP1].square=localSq

      if writer then writer:tick(build_struct_snapshot(world)) end
      turn = 2

    elseif turn == 2 and #p2_left > 0 then
      _AIENV.side = 2
      local status = build_status_for_ai_full(world, diffP2)
      status.meta.currentTurn = 2
      local res = call_ai({ type="Placement", status=status }) or {}

      local color = res.color or "Blue"
      if not _remove_one(p2_left, color) then
        color = table.remove(p2_left, 1)
      end
      local rawSq = res.square
      local sq    = _legal_home_sq_or_fallback(world, 2, rawSq or occupant_at_any(world, 8, 2) or square(8,8))
      world.pieces[color].loc="BOARD"; world.pieces[color].square=sq

      if writer then writer:tick(build_struct_snapshot(world)) end
      turn = 1
    else
      turn = (turn==1) and 2 or 1
    end
  end
end

------------------------------------------------------------
-- Plan (one roll per round; 6 alternating picks) — BOTH via AI
------------------------------------------------------------
local function _apply_prep_pick(world, side, res)
  if not res or not res.color then return end

  if (res.n or 0) > 0 then
    local stacksTbl = (side == 2) and world.stacks.P2 or world.stacks.P1
    stacksTbl[res.color] = stacksTbl[res.color] or {}
    local added = write_stack_next_n(stacksTbl[res.color], res.plan or {}, res.n or 0)
    world.stats.reveals_available[side] = world.stats.reveals_available[side] + (added or 0)
  end

  local want = _canon_buff(res.wantBuff)
  if world.buffs.zones[res.color] ~= "None" then
    _buff_log_assign_failure(world, side, res.color, want or "None", "zone_occupied", "plan_pick")
    return
  end

  local function assign(nm, src)
    if not nm or nm == "None" then return false end
    if not _can_assign(world, side, nm) then return false end
    if not _consume_for_assignment(world, side, nm) then return false end
    world.buffs.zones[res.color]      = nm
    world.buffs.zoneStatus[res.color] = "Unrevealed"
    _buffdbg(world, {
      event="assigned_to_zone", source=src or "plan_pick",
      side=side, side_str=(side==2 and "P2" or "P1"),
      color=res.color, name=nm
    })
    return true
  end

  if assign(want, "plan_pick_requested") then return end
  for _,nm in ipairs(BUFF_TYPES) do
    if assign(nm, "plan_pick_fallback") then return end
  end
  if want and want ~= "None" then
    _buff_log_assign_failure(world, side, res.color, want, "none_usable_in_hand", "plan_pick")
  end
end

local function _single_pick(world, side, diffP1, diffP2)
  if side == 2 then
    _AIENV.side = 2
    local status = build_status_for_ai_full(world, diffP2)
    status.meta.currentTurn = 2
    local res = call_ai({ type="Plan", status=status }) or {}
    local fixed = plan_sanitize_and_fill(world, 2, { color=res.color or "Blue", n=res.n, plan=res.plan, wantBuff=res.wantBuff })
    _apply_prep_pick(world, 2, fixed)
  else
    _AIENV.side = 1
    local statusM = build_status_for_ai_mirrored(world, diffP1, false)
    statusM.meta.currentTurn = 1

    local resM = call_ai({ type="Plan", status=statusM }) or {}
    local map = { Blue="Green", Pink="Yellow", Purple="Orange" }
    local fixed = plan_sanitize_and_fill(world, 1, { color=map[resM.color or "Blue"], n=resM.n, plan=resM.plan, wantBuff=resM.wantBuff })
    _apply_prep_pick(world, 1, fixed)
  end
end

local function Plan_in_turn_order(world, firstPlayer, diffP1, diffP2, writer)
  world.phase = "Plan phase"
  world.dice = roll_three_d6()
  local dsorted = sorted_desc3(world.dice)
  world.planDicePool = { [1] = { dsorted[1], dsorted[2], dsorted[3] },
                         [2] = { dsorted[1], dsorted[2], dsorted[3] } }

  local order = { firstPlayer, (firstPlayer==1 and 2 or 1),
                  firstPlayer, (firstPlayer==1 and 2 or 1),
                  firstPlayer, (firstPlayer==1 and 2 or 1) }
  for i=1,6 do _single_pick(world, order[i], diffP1, diffP2) end

  if writer then writer:section_full("Plan", build_struct_snapshot(world)) end
end

------------------------------------------------------------
-- Buff & action execution  (with telemetry)
------------------------------------------------------------
local function bump_buff_stat(world, side, kind)
  world.stats.buffs_used[side][kind] = (world.stats.buffs_used[side][kind] or 0) + 1
end

local function _use_assigned_buff(world, color, kind, ctx)
  if world.buffs.zones[color] ~= kind or world.buffs.zoneStatus[color] ~= "Unrevealed" then
    return false
  end
  world.buffs.zoneStatus[color] = "Revealed"
  _push_discard(world.buff, kind)
  bump_buff_stat(world, side_of_color(color), kind)
  _buffdbg(world, {
    event="buff_revealed_used", side=side_of_color(color), side_str=_side_str(side_of_color(color)),
    color=color, name=kind, ctx=ctx or {}
  })
  return true
end

local function _has_assigned_buff(world, color, kind)
  return (world.buffs.zones[color]==kind and world.buffs.zoneStatus[color]=="Unrevealed")
end

local function _auto_assign_on_demand(world, color, kind)
  if not kind or kind=="None" then return false end
  if _has_assigned_buff(world, color, kind) then return true end
  if world.buffs.zones[color] ~= "None" then
    _buff_log_assign_failure(world, side_of_color(color), color, kind, "zone_occupied", "on_demand")
    return false
  end
  local side = side_of_color(color)
  if not _can_assign(world, side, kind) then
    _buff_log_assign_failure(world, side, color, kind, "not_usable_or_fresh_lock", "on_demand")
    return false
  end
  if not _consume_for_assignment(world, side, kind) then
    _buff_log_assign_failure(world, side, color, kind, "consume_failed", "on_demand")
    return false
  end
  world.buffs.zones[color] = kind
  world.buffs.zoneStatus[color] = "Unrevealed"
  _buffdbg(world, { event="auto_assigned_to_zone", source="on_demand",
    side=side, side_str=_side_str(side), color=color, name=kind })
  return true
end

local function _clear_shield_on_piece_reveal(world, color)
  local p = world.pieces[color]; if not p then return end
  if p.hasShield then
    _credit_ed_life(world, p, side_of_color(color))
    p.hasShield = false
  end
end

-- progress metric toward finish (signed delta) for telemetry
local function _progress_delta(side, carrying, fromSq, toSq)
  local _,rb = parseSquare(fromSq or "")
  local _,ra = parseSquare(toSq or "")
  if not rb or not ra then return 0 end
  if side==2 then
    if carrying then return (ra - rb) else return (rb - ra) end
  else
    if carrying then return (rb - ra) else return (ra - rb) end
  end
end

local function execute_action(world, side, color, face, aiLike, writer)
  local p = world.pieces[color]; if not p or p.loc ~= "BOARD" or not p.square then return end

  -- remove standing shield as soon as this piece reveals a new action
  _clear_shield_on_piece_reveal(world, color)

  local kind = (face or "MOVE"):upper()
  local act_to   = aiLike.location_to or aiLike.to
  local atk_tgt  = aiLike.attackTarget or act_to

  -- normalize buff fields
  local bk = aiLike.buffKind or aiLike.buff or aiLike.wantBuff or aiLike.buff_name or aiLike.buffName
  if (not bk or bk == "None") and world.buffs.zoneStatus[color] == "Unrevealed" then
    bk = world.buffs.zones[color]
  end
  local buffKind = _canon_buff(bk or "None")
  local buffSeq  = aiLike.sequence or ((aiLike.buffFirst and "BuffFirst") or "ActionFirst")
  local buffTo   = aiLike.buffTarget or aiLike.buff_to or aiLike.location_buff

  local relevant =
      (kind=="MOVE"   and (buffKind=="Extra Move" or buffKind=="Diagonal Move" or buffKind=="Extra Defend"))
   or (kind=="ATTACK" and  (buffKind=="Extra Attack" or buffKind=="Extra Defend"))
   or (kind=="DEFEND" and  (buffKind=="Extra Defend" or buffKind=="Extra Move" or buffKind=="Diagonal Move"))
  if relevant and not _has_assigned_buff(world, color, buffKind) then
    _auto_assign_on_demand(world, color, buffKind)
  end

  local canMoveBuff    = _has_assigned_buff(world, color, buffKind) and (buffKind=="Extra Move" or buffKind=="Diagonal Move")
  local canExtraDefend = _has_assigned_buff(world, color, "Extra Defend")
  local canExtraAttack = _has_assigned_buff(world, color, "Extra Attack")

  -- Pre-telemetry snapshot
  local from_before = p.square
  local carryingBefore = p.hasFlag and true or false
  local threatBefore = _adjacent_enemy_count(world, p.square, side)
  local orthMovesBefore = _orth_legal_move_count(world, p.square)

  local usedDiagonal = false
  local usedExtraMoveTwoStep = false
  local usedExtraDefend = false
  local extraDefendCover = false
  local extraSecondHit = false
  local extraSecondVictim = nil
  local extraShieldBrokenOnSecond = false

  local function do_move_step(stepTo, mode)
    if not stepTo then return end
    if mode=="diag" then usedDiagonal = true end
    _try_step(world, color, stepTo, mode)
  end

  if kind=="MOVE" then
    -- Optional: apply Extra Defend before moving (escape-cover)
    if canExtraDefend and buffSeq=="BuffFirst" then
      p.hasShield = true
      p._shieldFromExtraDefend = true
      p._shieldStamp = world.stats.turns
      _use_assigned_buff(world, color, "Extra Defend", { action=kind, when="BuffFirst" })
      usedExtraDefend = true
      extraDefendCover = true
    end

    if canMoveBuff and buffSeq=="BuffFirst" then
      do_move_step(buffTo, (buffKind=="Diagonal Move") and "diag" or "orth")
      _use_assigned_buff(world, color, buffKind, { action=kind, when="BuffFirst" })
      if buffKind=="Extra Move" then usedExtraMoveTwoStep = true end
      do_move_step(act_to, "orth")
    else
      do_move_step(act_to, "orth")
      if canMoveBuff then
        do_move_step(buffTo, (buffKind=="Diagonal Move") and "diag" or "orth")
        _use_assigned_buff(world, color, buffKind, { action=kind, when="AfterAction" })
        if buffKind=="Extra Move" then usedExtraMoveTwoStep = true end
      end
    end

  elseif kind=="DEFEND" then
    if canExtraDefend then
      -- Extra Defend: up to 2 orth steps toward target, then shield
      local target = act_to or buffTo or p.square
      for _=1,2 do
        local cf,cr = parseSquare(p.square or ""); local tf,tr = parseSquare(target or "")
        if cf and tf then
          local step=nil
          if tf ~= cf then step = square(cf + ((tf>cf) and 1 or -1), cr)
          elseif tr ~= cr then step = square(cf, cr + ((tr>cr) and 1 or -1)) end
          if step then _try_step(world, color, step, "orth") end
        end
      end
      p.hasShield = true
      p._shieldFromExtraDefend = true
      p._shieldStamp = world.stats.turns
      _use_assigned_buff(world, color, "Extra Defend", { action=kind })
      usedExtraDefend = true
    else
      if buffSeq=="BuffFirst" and canMoveBuff then
        do_move_step(buffTo, (buffKind=="Diagonal Move") and "diag" or "orth")
        _use_assigned_buff(world, color, buffKind)
        if buffKind=="Extra Move" then usedExtraMoveTwoStep = true end
      end
      do_move_step(act_to, "orth")
      p.hasShield = true
      p._shieldStamp = world.stats.turns
      if buffSeq~="BuffFirst" and canMoveBuff then
        do_move_step(buffTo, (buffKind=="Diagonal Move") and "diag" or "orth")
        _use_assigned_buff(world, color, buffKind)
        if buffKind=="Extra Move" then usedExtraMoveTwoStep = true end
      end
    end

  elseif kind=="ATTACK" then
    -- Allow Extra Defend cover before attacking if requested
    if canExtraDefend and buffSeq=="BuffFirst" then
      p.hasShield = true
      p._shieldFromExtraDefend = true
      p._shieldStamp = world.stats.turns
      _use_assigned_buff(world, color, "Extra Defend", { action=kind, when="BuffFirst" })
      usedExtraDefend = true
      extraDefendCover = true
    end

    local function _adjacent_ok(from, to)
      local f1,r1 = parseSquare(from or ""); local f2,r2 = parseSquare(to or "")
      if not f1 or not f2 then return false end
      local df,dr = math.abs(f1-f2), math.abs(r1-r2)
      return (df<=1 and dr<=1 and (df+dr)>0)
    end
    local function norm_target(t)
      if not t then return nil end
      if world.pieces[t] and world.pieces[t].square then return world.pieces[t].square end
      return t
    end

    world.stats.attacks_attempted[side] = world.stats.attacks_attempted[side] + 1
    local tgt = norm_target(atk_tgt)
    local occ = tgt and occupant_at(world, tgt) or nil
    local enemyPresent = occ and side_of_color(occ) ~= side
    local adjacentOK = tgt and _adjacent_ok(p.square, tgt)

    local hit = false
    local firstVictimSentHome = false
    if tgt and adjacentOK and enemyPresent then
      local r = resolve_attack(world, color, tgt)
      hit = (r and r.hit) or false
      if r and r.sentHome then firstVictimSentHome = true end
    else
      world.stats.wasted_attacks[side] = (world.stats.wasted_attacks[side] or 0) + 1
    end

    if hit then
      world.stats.attacks_hits[side] = world.stats.attacks_hits[side] + 1
    end

    if canExtraAttack then
      -- pick best adjacent follow-up
      local cf,cr = parseSquare(p.square or "")
      local candidates={}
      for df=-1,1 do for dr=-1,1 do
        if not (df==0 and dr==0) then
          local f=cf+df; local r=cr+dr
          if f and r and f>=1 and f<=8 and r>=1 and r<=8 then
            local sq = square(f,r)
            local o2 = occupant_at(world, sq)
            if o2 and side_of_color(o2) ~= side then
              candidates[#candidates+1] = {sq=sq, occ=o2}
            end
          end
        end
      end end
      local pick=nil
      for _,c in ipairs(candidates) do if world.pieces[c.occ].hasFlag then pick=c; break end end
      if not pick then for _,c in ipairs(candidates) do if not world.pieces[c.occ].hasShield then pick=c; break end end end
      if not pick then pick=candidates[1] end
      if pick then
        world.stats.attacks_attempted[side] = world.stats.attacks_attempted[side] + 1
        local r2 = resolve_attack(world, color, pick.sq)
        if r2 and r2.hit then
          world.stats.attacks_hits[side] = world.stats.attacks_hits[side] + 1
        else
          world.stats.wasted_attacks[side] = (world.stats.wasted_attacks[side] or 0) + 1
        end
        extraSecondHit = (r2 and r2.sentHome) or false
        extraSecondVictim = r2 and r2.victim or nil
        if r2 and r2.shieldBroken then extraShieldBrokenOnSecond = true end
        -- ROI counters
        local BE = world.stats.buff_effect[side]
        if hit and firstVictimSentHome then
          BE.ExtraAttack.firstHitKills = (BE.ExtraAttack.firstHitKills or 0) + 1
        end
        if extraSecondHit then
          BE.ExtraAttack.secondHitKills = (BE.ExtraAttack.secondHitKills or 0) + 1
        end
        if extraShieldBrokenOnSecond then
          BE.ExtraAttack.shieldsBrokenOnExtra = (BE.ExtraAttack.shieldsBrokenOnExtra or 0) + 1
        end
      else
        -- tried to extra-attack but nobody to hit
        world.stats.wasted_attacks[side] = (world.stats.wasted_attacks[side] or 0) + 1
      end
      _use_assigned_buff(world, color, "Extra Attack", { action=kind })
    end
  end

  -- Post-telemetry snapshot
  local from_after = from_before
  local to_after   = world.pieces[color].square
  local carryingAfter = world.pieces[color].hasFlag and true or false
  local threatAfter = _adjacent_enemy_count(world, to_after, side)
  local orthMovesAfter = _orth_legal_move_count(world, to_after)
  local delta = _progress_delta(side, carryingAfter, from_before, to_after)

  -- accumulate net progress + threat deltas
  world.stats.progress_total[side] = (world.stats.progress_total[side] or 0) + (delta or 0)
  local tdelta = (threatAfter or 0) - (threatBefore or 0)
  local td = world.stats.threat_delta[side]
  if tdelta > 0 then td.up = (td.up or 0) + 1
  elseif tdelta < 0 then td.down = (td.down or 0) + 1
  else td.flat = (td.flat or 0) + 1 end

  -- Buff effectiveness accounting
  local BE = world.stats.buff_effect[side]
  if usedExtraMoveTwoStep then
    local gain = math.max(0, delta - 1)
    BE.ExtraMove.distanceGain = (BE.ExtraMove.distanceGain or 0) + gain
    local _,r = parseSquare(world.pieces[color].square or "")
    local targetRank = (side==1) and 1 or 8
    if world.pieces[color].hasFlag and r == targetRank then
      BE.ExtraMove.twoStepFinishes = (BE.ExtraMove.twoStepFinishes or 0) + 1
    end
    if orthMovesBefore <= 1 and orthMovesAfter > orthMovesBefore then
      BE.ExtraMove.laneOpens = (BE.ExtraMove.laneOpens or 0) + 1
    end
  end
  if usedDiagonal then
    BE.DiagonalMove.diagonalsTaken = (BE.DiagonalMove.diagonalsTaken or 0) + 1
    if orthMovesBefore <= 1 and orthMovesAfter > orthMovesBefore then
      BE.DiagonalMove.laneOpens = (BE.DiagonalMove.laneOpens or 0) + 1
    end
    local _,r = parseSquare(world.pieces[color].square or "")
    local targetRank = (side==1) and 1 or 8
    if world.pieces[color].hasFlag and r==targetRank then
      BE.DiagonalMove.finishesEnabled = (BE.DiagonalMove.finishesEnabled or 0) + 1
    end
  end
  if usedExtraDefend then
    if extraDefendCover then
      BE.ExtraDefend.covers = (BE.ExtraDefend.covers or 0) + 1
    end
    if threatBefore>0 and threatAfter==0 then
      BE.ExtraDefend.escapes = (BE.ExtraDefend.escapes or 0) + 1
    end
  end

  -- Timeline log row
  local timeline_row = {
    t = writer and writer.turn_index+1 or world.stats.turns+1,
    round = world.round, side = (side==2) and "P2" or "P1",
    color = color, face = kind,
    from = from_before, to = to_after,
    buff = {
      kind = buffKind, seq = buffSeq,
      reveal = (world.buffs.zoneStatus[color]=="Revealed"),
      secondStep = (usedExtraMoveTwoStep and (aiLike.buffTarget or aiLike.location_buff)) or nil
    },
    carryingBefore = carryingBefore, carryingAfter = carryingAfter,
    threatBefore = threatBefore, threatAfter = threatAfter,
    progressDelta = delta,
    diagonalTaken = usedDiagonal or nil,
    twoStepExtraMove = usedExtraMoveTwoStep or nil,
    extraAttack = (canExtraAttack and { used=true, secondVictim=extraSecondVictim, secondKill=extraSecondHit, shieldBrokenOnSecond=extraShieldBrokenOnSecond }) or nil,
    extraDefend = (usedExtraDefend and { used=true, cover=extraDefendCover, escape=(threatBefore>0 and threatAfter==0) }) or nil
  }
  push(world.action_log, timeline_row)
end

--endregion Part2

--#region Part3
-- sim.lua (v3, Part 3/3)

------------------------------------------------------------
-- Action loop (alternating reveals)
------------------------------------------------------------
local function earliest_color_with_action(stacks, palette)
  for _,clr in ipairs(palette) do
    local s = stacks[clr] or {}
    for i=1,6 do
      local c=s[i]
      if c and not c.revealed and c.face~="BLANK" and c.face~="ACTION" then return clr end
    end
  end
  return nil
end

local function action_step(world, side, diffP1, diffP2, writer)
  world.phase = "Battle Phase"

  local stacks = (side==2) and world.stacks.P2 or world.stacks.P1
  local palette= (side==2) and COLORS_P2 or COLORS_P1
  local has = earliest_color_with_action(stacks, palette)
  if not has then return false end

  if side == 2 then
    _AIENV.side = 2
    local status = build_status_for_ai_full(world, diffP2)
    status.meta.currentTurn = 2
    local ai = call_ai({ type="Action", status=status }) or {}

    local color = ai.color or has
    if not stacks[color] or count_unrevealed_real(stacks[color])==0 then color = has end

    local revealed, face = reveal_next_nonblank(stacks[color])
    if not revealed then return false end

    execute_action(world, 2, color, face, {
      location_to = ai.location_to or ai.to,
      attackTarget= ai.attackTarget,
      buffKind    = ai.buffKind,
      sequence    = ai.sequence,
      buffTarget  = ai.buffTarget
    }, writer)

    world.stats.reveals_used[2] = world.stats.reveals_used[2] + 1
    world.stats.actions[2][(face or "MOVE"):upper()] = (world.stats.actions[2][(face or "MOVE"):upper()] or 0) + 1
    world.stats.turns = world.stats.turns + 1
    world.lastActorSide = 2
    return true

  else
    _AIENV.side = 1
    local statusM = build_status_for_ai_mirrored(world, diffP1, false)
    statusM.meta.currentTurn = 1

    local aiM = call_ai({ type="Action", status=statusM }) or {}

    local colorP2 = aiM.color or "Blue"
    local map = { Blue="Green", Pink="Yellow", Purple="Orange" }
    local color   = map[colorP2] or has
    if not stacks[color] or count_unrevealed_real(stacks[color])==0 then color = has end

    local revealed, face = reveal_next_nonblank(stacks[color])
    if not revealed then return false end

    local function mir(v) if type(v)=="string" then return mirror_square(v) else return v end end
    local atkT = aiM.attackTarget
    if type(atkT)=="string" and not atkT:match("^[A-H]") then
      -- piece id stays piece id
    else
      atkT = mir(atkT)
    end

    execute_action(world, 1, color, face, {
      location_to = mir(aiM.location_to or aiM.to),
      attackTarget= atkT,
      buffKind    = aiM.buffKind,
      sequence    = aiM.sequence,
      buffTarget  = mir(aiM.buffTarget)
    }, writer)

    world.stats.reveals_used[1] = world.stats.reveals_used[1] + 1
    world.stats.actions[1][(face or "MOVE"):upper()] = (world.stats.actions[1][(face or "MOVE"):upper()] or 0) + 1
    world.stats.turns = world.stats.turns + 1
    world.lastActorSide = 1
    return true
  end
end

------------------------------------------------------------
-- Statistics printer (brief terminal)
------------------------------------------------------------
local function pct(a,b) if (b or 0)<=0 then return "0%" end return string.format("%.0f%%", 100*(a/b)) end
local function rate(a,b) if (b or 0)<=0 then return 0 end return a/b end
local function statistics_brief(stats)
  local outcome = stats.winner or (stats.timeout and "TIMEOUT" or "UNKNOWN")
  local p1hr = pct(stats.attacks_hits[1], stats.attacks_attempted[1])
  local p2hr = pct(stats.attacks_hits[2], stats.attacks_attempted[2])
  local p1bu = 0; for _,v in pairs(stats.buffs_used[1]) do p1bu=p1bu+v end
  local p2bu = 0; for _,v in pairs(stats.buffs_used[2]) do p2bu=p2bu+v end
  if LOG_VERBOSITY >= 1 then
    print(string.format("Outcome:%-9s Rounds:%-3d Turns:%-3d Hit%% P1:%-4s P2:%-4s BuffsUsed P1:%-2d P2:%-2d",
      outcome, stats.rounds or 0, stats.turns or 0, p1hr, p2hr, p1bu, p2bu))
  end
end

------------------------------------------------------------
-- One full match — Player 1 ALWAYS goes first each round
------------------------------------------------------------
local function build_match_summary(world, stats)
  local function hr(s) return rate(stats.attacks_hits[s], stats.attacks_attempted[s]) end
  local function life(s) return rate(stats.shield_turns_total_broken[s], stats.shields_lost[s]) end
  local function buffs_used_map(s) return copy_shallow(stats.buffs_used[s]) end

  local function be_side(s)
    local src = stats.buff_effect[s]
    local out = {
      ["Extra Move"]   = { twoStepFinishes=src.ExtraMove.twoStepFinishes, distanceGain=src.ExtraMove.distanceGain, laneOpens=src.ExtraMove.laneOpens },
      ["Diagonal Move"]= { diagonalsTaken=src.DiagonalMove.diagonalsTaken, laneOpens=src.DiagonalMove.laneOpens, finishesEnabled=src.DiagonalMove.finishesEnabled },
      ["Extra Attack"] = { firstHitKills=src.ExtraAttack.firstHitKills, secondHitKills=src.ExtraAttack.secondHitKills, shieldsBrokenOnExtra=src.ExtraAttack.shieldsBrokenOnExtra },
      ["Extra Defend"] = { covers=src.ExtraDefend.covers, escapes=src.ExtraDefend.escapes,
                           avgShieldLifeAfter=(src.ExtraDefend._lifeCnt>0 and (src.ExtraDefend._lifeSum/src.ExtraDefend._lifeCnt) or 0),
                           preventedSendHome=src.ExtraDefend.preventedSendHome }
    }
    return out
  end

  return {
    winner = stats.winner or (stats.timeout and "TIMEOUT" or "UNKNOWN"),
    rounds = stats.rounds, turns = stats.turns, initiative = 1, -- P1 fixed first
    useRates = {
      P1 = { revealsUsed=stats.reveals_used[1], revealsAvail=stats.reveals_available[1], revealUseRate=rate(stats.reveals_used[1], stats.reveals_available[1]) },
      P2 = { revealsUsed=stats.reveals_used[2], revealsAvail=stats.reveals_available[2], revealUseRate=rate(stats.reveals_used[2], stats.reveals_available[2]) },
    },
    actions = { P1=stats.actions[1], P2=stats.actions[2] },
    attacks = {
      P1 = { attempts=stats.attacks_attempted[1], hits=stats.attacks_hits[1], hitRate=hr(1) },
      P2 = { attempts=stats.attacks_attempted[2], hits=stats.attacks_hits[2], hitRate=hr(2) },
    },
    wastedAttacks = { P1 = stats.wasted_attacks[1] or 0, P2 = stats.wasted_attacks[2] or 0 },
    progress = { P1 = stats.progress_total[1] or 0, P2 = stats.progress_total[2] or 0 },
    threatShifts = {
      P1 = copy_shallow(stats.threat_delta[1] or {}),
      P2 = copy_shallow(stats.threat_delta[2] or {}),
    },
    captures = { P1=stats.captures[1], P2=stats.captures[2] },
    shields  = {
      brokenByP1 = stats.shields_broken[1], brokenByP2 = stats.shields_broken[2],
      lostP1 = stats.shields_lost[1], lostP2 = stats.shields_lost[2],
      avgLifeTurns = { P1=life(1), P2=life(2) },
    },
    buffs = {
      drawn    = { P1=stats.buff_draws[1],    P2=stats.buff_draws[2] },
      assigned = { P1=stats.buff_assigned[1], P2=stats.buff_assigned[2] },
      used     = { P1=buffs_used_map(1),      P2=buffs_used_map(2) },
    },
    buffEffectiveness = { P1=be_side(1), P2=be_side(2) },
    luck = {
      tokenPickupsMove = { P1=stats.token_pickups_move[1], P2=stats.token_pickups_move[2] },
      tokenRespawnHits = { P1=stats.token_respawn_hits[1], P2=stats.token_respawn_hits[2] },
      avgFirstFlagPickTurn = {
        P1=stats.first_pick_turn[1] or -1,
        P2=stats.first_pick_turn[2] or -1
      }
    }
  }
end

local function run_match(dP1, dP2, writer, match_index)
    if REROLL_SEED_EACH_MATCH and SEED_BASE then
    _seed_rng((SEED_BASE + (match_index or 0)) % 2^31)
  else
    _seed_rng(SEED_BASE)
  end
  local world = new_world()
  world_ref = world
  do
    local t = os.time()
    -- simple, deterministic mixes so P1/P2 aren’t identical even if called in same second
    world.matchConst.P1 = ((t * 1103515245 + 12345) % 2^31) / 2^31
    world.matchConst.P2 = ((t * 1664525     + 1013904223) % 2^31) / 2^31
  end


  -- Initialise token + buff deck
  _place_token_initial(world)

  -- initial draws
  for i=1,2 do
    world._give_card(world, 1, world._draw_card(world.buff), false, "InitialDeal")
    world._give_card(world, 2, world._draw_card(world.buff), false, "InitialDeal")
  end

  -- P1 always goes first
  world.firstPlayer = 1
  world.stats.initiative = 1

  if writer then
    writer:match(match_index or 1)
    writer:T0(build_struct_snapshot(world))
    writer:round(world.round)
    writer:section("Placement")
  end

  placement_in_turn_order(world, world.firstPlayer, dP1, dP2, writer)

  local winner = nil
  local first_round = true
  while world.round <= MAX_ROUNDS_PER_MATCH do
    if not first_round and writer then writer:round(world.round) end

    _respawn_left_to_right(world)
    _reset_stacks_for_new_round(world)
    _buffdbg(world, { event="round_start" })

    -- Plan: P1 always picks first each round
    world.firstPlayer = 1
    Plan_in_turn_order(world, world.firstPlayer, dP1, dP2, writer)
    _buffdbg(world, { event="after_plan" })

    if writer then writer:section("Battle") end
    world.phase = "Battle Phase"
    local acted = true
    local turnSide = world.firstPlayer
    world.lastActorSide = nil
    while acted do
      acted = false
      if turnSide == 1 then
        if action_step(world, 1, dP1, dP2, writer) then
          acted = true
          if writer then writer:tick(build_struct_snapshot(world)) end
          local w = winner_or_nil(world); if w then winner = w; break end
          turnSide = 2
        end
        if action_step(world, 2, dP1, dP2, writer) then
          acted = true
          if writer then writer:tick(build_struct_snapshot(world)) end
          local w = winner_or_nil(world); if w then winner = w; break end
          turnSide = 1
        end
      else
        if action_step(world, 2, dP1, dP2, writer) then
          acted = true
          if writer then writer:tick(build_struct_snapshot(world)) end
          local w = winner_or_nil(world); if w then winner = w; break end
          turnSide = 1
        end
        if action_step(world, 1, dP1, dP2, writer) then
          acted = true
          if writer then writer:tick(build_struct_snapshot(world)) end
          local w = winner_or_nil(world); if w then winner = w; break end
          turnSide = 2
        end
      end
    end

    world.stats.rounds = world.stats.rounds + 1
    _end_round_cleanup(world)

    if winner then break end
    -- Do NOT alternate first player between rounds; keep P1 first.
    world.round = world.round + 1
    first_round = false
  end

  if not winner then world.stats.timeout=true end
  world.stats.winner = winner or "TIMEOUT"

  -- Append per-match telemetry blocks
  local ms = build_match_summary(world, world.stats)
  if writer then
    writer:append_json_block(("MATCH_SUMMARY (%d)"):format(tonumber(match_index) or 1), ms)
    writer:dump_jsonl(("ACTION_TIMELINE_JSONL (%d)"):format(tonumber(match_index) or 1), world.action_log)
    if DEBUG_BUFF then
      writer:dump_jsonl(("BUFF_DEBUG_JSONL (%d)"):format(tonumber(match_index) or 1), world.buff_debug or {})
    end
    if world.ai_debug and #world.ai_debug>0 then
      writer:dump_jsonl(("AI_DEBUG_JSONL (%d)"):format(tonumber(match_index) or 1), world.ai_debug)
    end
  end

  return world.stats, ms
end

------------------------------------------------------------
-- All-match aggregator
------------------------------------------------------------
local function new_agg()
  return {
    matches=0,
    wins={ P1=0, P2=0, TIMEOUT=0 },
    rounds=0, turns=0,
    initiative={ P1=0, P2=0 },
    reveals_used={ [1]=0,[2]=0 }, reveals_avail={ [1]=0,[2]=0 },
    actions={ [1]={MOVE=0,ATTACK=0,DEFEND=0}, [2]={MOVE=0,ATTACK=0,DEFEND=0} },
    attacks_attempted={ [1]=0,[2]=0 }, attacks_hits={ [1]=0,[2]=0 },
    wasted_attacks={ [1]=0,[2]=0 },
    progress_total={ [1]=0,[2]=0 },
    threat_delta={
      [1]={up=0,down=0,flat=0},
      [2]={up=0,down=0,flat=0},
    },
    buffs_drawn={ [1]=0,[2]=0 }, buffs_assigned={ [1]=0,[2]=0 },
    token_pickups_move={ [1]=0,[2]=0 }, token_respawn_hits={ [1]=0,[2]=0 },
    captures={ [1]=0,[2]=0 },
    shields_broken={ [1]=0,[2]=0 }, shields_lost={ [1]=0,[2]=0 },
    shield_turns_total_broken={ [1]=0,[2]=0 },
    flag_picks={ [1]=0,[2]=0 },
    first_pick_turn_sum={ [1]=0,[2]=0 }, first_pick_turn_cnt={ [1]=0,[2]=0 },

    -- aggregated effectiveness
    buff_effect = {
      [1]=_init_buff_effect_bucket(),
      [2]=_init_buff_effect_bucket(),
    }
  }
end

local function _add_be(dst, src)
  local function inc(sub, field, v)
    if not sub then return end
    if v and v ~= 0 then sub[field] = (sub[field] or 0) + v end
  end

  local em = dst.ExtraMove
  inc(em, "twoStepFinishes",      src.ExtraMove and src.ExtraMove.twoStepFinishes)
  inc(em, "distanceGain",         src.ExtraMove and src.ExtraMove.distanceGain)
  inc(em, "laneOpens",            src.ExtraMove and src.ExtraMove.laneOpens)

  local dm = dst.DiagonalMove
  inc(dm, "diagonalsTaken",       src.DiagonalMove and src.DiagonalMove.diagonalsTaken)
  inc(dm, "laneOpens",            src.DiagonalMove and src.DiagonalMove.laneOpens)
  inc(dm, "finishesEnabled",      src.DiagonalMove and src.DiagonalMove.finishesEnabled)

  local ea = dst.ExtraAttack
  inc(ea, "firstHitKills",        src.ExtraAttack and src.ExtraAttack.firstHitKills)
  inc(ea, "secondHitKills",       src.ExtraAttack and src.ExtraAttack.secondHitKills)
  inc(ea, "shieldsBrokenOnExtra", src.ExtraAttack and src.ExtraAttack.shieldsBrokenOnExtra)

  local ed = dst.ExtraDefend
  inc(ed, "covers",               src.ExtraDefend and src.ExtraDefend.covers)
  inc(ed, "escapes",              src.ExtraDefend and src.ExtraDefend.escapes)
  ed._lifeSum          = (ed._lifeSum or 0) + ((src.ExtraDefend and src.ExtraDefend._lifeSum) or 0)
  ed._lifeCnt          = (ed._lifeCnt or 0) + ((src.ExtraDefend and src.ExtraDefend._lifeCnt) or 0)
  ed.preventedSendHome = (ed.preventedSendHome or 0) + ((src.ExtraDefend and src.ExtraDefend.preventedSendHome) or 0)
  ed.avgShieldLifeAfter = (ed._lifeCnt or 0) > 0 and (ed._lifeSum / ed._lifeCnt) or 0
end

local function agg_add(agg, stats)
  agg.matches = agg.matches + 1
  if stats.winner == "PLAYER 1" then agg.wins.P1 = agg.wins.P1 + 1
  elseif stats.winner == "COMPUTER" then agg.wins.P2 = agg.wins.P2 + 1
  else agg.wins.TIMEOUT = agg.wins.TIMEOUT + 1 end

  -- Initiative is always P1 in this build
  agg.initiative.P1 = agg.initiative.P1 + 1

  agg.rounds = agg.rounds + (stats.rounds or 0)
  agg.turns  = agg.turns  + (stats.turns  or 0)

  for s=1,2 do
    agg.reveals_used[s]  = agg.reveals_used[s]  + (stats.reveals_used[s] or 0)
    agg.reveals_avail[s] = agg.reveals_avail[s] + (stats.reveals_available[s] or 0)
    agg.attacks_attempted[s] = agg.attacks_attempted[s] + (stats.attacks_attempted[s] or 0)
    agg.attacks_hits[s]      = agg.attacks_hits[s]      + (stats.attacks_hits[s] or 0)
    agg.wasted_attacks[s]    = agg.wasted_attacks[s]    + (stats.wasted_attacks[s] or 0)
    agg.progress_total[s]    = agg.progress_total[s]    + (stats.progress_total[s] or 0)
    local td = stats.threat_delta[s] or {}
    agg.threat_delta[s].up   = agg.threat_delta[s].up   + (td.up or 0)
    agg.threat_delta[s].down = agg.threat_delta[s].down + (td.down or 0)
    agg.threat_delta[s].flat = agg.threat_delta[s].flat + (td.flat or 0)

    agg.buffs_drawn[s]    = agg.buffs_drawn[s]    + (stats.buff_draws[s] or 0)
    agg.buffs_assigned[s] = agg.buffs_assigned[s] + (stats.buff_assigned[s] or 0)
    agg.token_pickups_move[s] = agg.token_pickups_move[s] + (stats.token_pickups_move[s] or 0)
    agg.token_respawn_hits[s] = agg.token_respawn_hits[s] + (stats.token_respawn_hits[s] or 0)
    agg.captures[s] = agg.captures[s] + (stats.captures[s] or 0)
    agg.shields_broken[s] = agg.shields_broken[s] + (stats.shields_broken[s] or 0)
    agg.shields_lost[s]   = agg.shields_lost[s]   + (stats.shields_lost[s] or 0)
    agg.shield_turns_total_broken[s] = agg.shield_turns_total_broken[s] + (stats.shield_turns_total_broken[s] or 0)
    agg.flag_picks[s] = agg.flag_picks[s] + (stats.flag_picks[s] or 0)
    agg.actions[s].MOVE   = agg.actions[s].MOVE   + (stats.actions[s].MOVE   or 0)
    agg.actions[s].ATTACK = agg.actions[s].ATTACK + (stats.actions[s].ATTACK or 0)
    agg.actions[s].DEFEND = agg.actions[s].DEFEND + (stats.actions[s].DEFEND or 0)
  end

  for s=1,2 do
    local fpt = stats.first_pick_turn[s]
    if fpt then
      agg.first_pick_turn_sum[s] = agg.first_pick_turn_sum[s] + fpt
      agg.first_pick_turn_cnt[s] = agg.first_pick_turn_cnt[s] + 1
    end
  end

  _add_be(agg.buff_effect[1], stats.buff_effect[1])
  _add_be(agg.buff_effect[2], stats.buff_effect[2])
end

local function build_all_matches_summary(agg, d1, d2)
  local function rate(a,b) if (b or 0)<=0 then return 0 end return a/b end
  local function be_side_totals(s)
    local src = agg.buff_effect[s]
    return {
      ["Extra Move"]   = { twoStepFinishes=src.ExtraMove.twoStepFinishes, distanceGain=src.ExtraMove.distanceGain, laneOpens=src.ExtraMove.laneOpens },
      ["Diagonal Move"]= { diagonalsTaken=src.DiagonalMove.diagonalsTaken, laneOpens=src.DiagonalMove.laneOpens, finishesEnabled=src.DiagonalMove.finishesEnabled },
      ["Extra Attack"] = { firstHitKills=src.ExtraAttack.firstHitKills, secondHitKills=src.ExtraAttack.secondHitKills, shieldsBrokenOnExtra=src.ExtraAttack.shieldsBrokenOnExtra },
      ["Extra Defend"] = { covers=src.ExtraDefend.covers, escapes=src.ExtraDefend.escapes,
                           avgShieldLifeAfter=(src.ExtraDefend._lifeCnt>0 and (src.ExtraDefend._lifeSum/src.ExtraDefend._lifeCnt) or 0),
                           preventedSendHome=src.ExtraDefend.preventedSendHome }
    }
  end

  return {
    matches = agg.matches,
    wins = { P1=agg.wins.P1, P2=agg.wins.P2, TIMEOUT=agg.wins.TIMEOUT },
    avgRounds = rate(agg.rounds, agg.matches),
    avgTurns  = rate(agg.turns,  agg.matches),
    initiative = { P1=agg.initiative.P1, P2=agg.initiative.P2 },
    global = {
      actions = agg.actions,
      hitRates = {
        P1 = rate(agg.attacks_hits[1], agg.attacks_attempted[1]),
        P2 = rate(agg.attacks_hits[2], agg.attacks_attempted[2])
      },
      wastedAttackRate = {
        P1 = rate(agg.wasted_attacks[1], agg.attacks_attempted[1]),
        P2 = rate(agg.wasted_attacks[2], agg.attacks_attempted[2]),
      },
      progress = { P1=agg.progress_total[1], P2=agg.progress_total[2] },
      threatShifts = agg.threat_delta,
      kd = {
        P1 = rate(agg.captures[1], agg.captures[2]),
        P2 = rate(agg.captures[2], agg.captures[1])
      },
      shieldAvgLife = {
        P1 = rate(agg.shield_turns_total_broken[1], agg.shields_lost[1]),
        P2 = rate(agg.shield_turns_total_broken[2], agg.shields_lost[2]),
      },
      buffs = {
        drawn    = { P1=agg.buffs_drawn[1],    P2=agg.buffs_drawn[2] },
        assigned = { P1=agg.buffs_assigned[1], P2=agg.buffs_assigned[2] },
      },
      luck = {
        tokenPickupsMove = { P1=agg.token_pickups_move[1], P2=agg.token_pickups_move[2] },
        tokenRespawnHits = { P1=agg.token_respawn_hits[1], P2=agg.token_respawn_hits[2] },
        avgFirstFlagPickTurn = {
          P1 = rate(agg.first_pick_turn_sum[1], agg.first_pick_turn_cnt[1]),
          P2 = rate(agg.first_pick_turn_sum[2], agg.first_pick_turn_cnt[2]),
        }
      }
    },
    buffEffectivenessTotals = { P1=be_side_totals(1), P2=be_side_totals(2) },
    difficulty = { P1=d1, P2=d2 }
  }
end

------------------------------------------------------------
-- Summary file writer
------------------------------------------------------------
local function _open_file(name, mode)
  local f, err = io.open(name, mode or "w")
  if not f then
    io.stderr:write("❌ Failed to open "..tostring(name)..": "..tostring(err).."\n")
  end
  return f
end

local function _summ_line(f, s) f:write(s.."\n") end

local function write_sim_summary(summary_filename, run_meta, per_pair, globalAgg, per_match_rows)
  local f = _open_file(summary_filename, "w"); if not f then return end

  _summ_line(f, string.format("=== BattlePlan Simulation Summary %s ===", RUN_ID_SUFFIX ~= "" and RUN_ID_SUFFIX or ""))
  _summ_line(f, string.format("Timestamp UTC: %s", os.date("!%Y-%m-%dT%H:%M:%SZ")))
  _summ_line(f, string.format("Config: GAMES_PER_PAIR=%d  DEBUG_BUFF=%s  JSON_BLOCKS=%s", GAMES_PER_PAIR, tostring(DEBUG_BUFF), tostring(INCLUDE_JSON_BLOCKS_IN_MATCH_LOG)))
  _summ_line(f, string.format("Difficulty Mode: %s", run_meta.diffMode))
  _summ_line(f, "First player is fixed to P1 every round in this run.")
  _summ_line(f, "")

  -- === How-to-read guide (for humans & AI) ===
  local HOW_TO_READ = [[
AI_README_START
How to read this summary: The file is plain text with four human-friendly sections followed by a JSON tail.
1) "By Difficulty Pair" shows results per (P1 difficulty, P2 difficulty): Games, Wins, and averages; key rates include
   HitRate = hits/attempts, WastedAtkRate = wasted/attempts, K/D = captures_for / captures_against,
   ShieldAvgLife = average turns a broken shield had been up.
2) "Global Totals" aggregates across all games. Progress is signed net movement toward finish (more positive = more
   forward for that side). "Threat Δ" counts turns where adjacent-enemy pressure went up/down/flat.
3) "Per-Match Rows (CSV)" is a comma-separated table with a header; rates are decimals in [0,1].
4) "Healthchecks" lists quick sanity checks.
Tail JSON: between "SUMMARY_JSON_START" and "SUMMARY_JSON_END" there is a single JSON object: { run, per_pair:[{P1,P2,summary}], global:{...} }.
Implementation note: In this run, P1 always acts first each round.
AI_README_END
]]
  for line in HOW_TO_READ:gmatch("[^\r\n]+") do _summ_line(f, line) end
  _summ_line(f, "")


  if SUMMARY_INCLUDE_BY_DIFFICULTY then
    _summ_line(f, "== By Difficulty Pair ==")
    for _,pp in ipairs(per_pair) do
      local agg = pp.agg
      local p1d, p2d = pp.p1, pp.p2
      local total = agg.matches
      local wP1, wP2, to = agg.wins.P1, agg.wins.P2, agg.wins.TIMEOUT
      _summ_line(f, string.format("P1=%d vs P2=%d — Games=%d  W(P1)=%d  W(P2)=%d  TO=%d", p1d, p2d, total, wP1, wP2, to))
      _summ_line(f, string.format("  Avg Rounds=%.2f  Avg Turns=%.2f", rate(agg.rounds,total), rate(agg.turns,total)))
      _summ_line(f, string.format("  HitRate P1=%.3f  P2=%.3f", rate(agg.attacks_hits[1],agg.attacks_attempted[1]), rate(agg.attacks_hits[2],agg.attacks_attempted[2])))
      _summ_line(f, string.format("  WastedAtkRate P1=%.3f  P2=%.3f", rate(agg.wasted_attacks[1],agg.attacks_attempted[1]), rate(agg.wasted_attacks[2],agg.attacks_attempted[2])))
      _summ_line(f, string.format("  K/D P1=%.3f  P2=%.3f", rate(agg.captures[1],agg.captures[2]), rate(agg.captures[2],agg.captures[1])))
      _summ_line(f, string.format("  ShieldAvgLife P1=%.2f  P2=%.2f", rate(agg.shield_turns_total_broken[1], agg.shields_lost[1]), rate(agg.shield_turns_total_broken[2], agg.shields_lost[2])))
      _summ_line(f, "")
    end
  end

  if SUMMARY_INCLUDE_GLOBAL then
    _summ_line(f, "== Global Totals ==")
    local ga = globalAgg
    _summ_line(f, string.format("Games=%d  Wins: P1=%d P2=%d TO=%d", ga.matches, ga.wins.P1, ga.wins.P2, ga.wins.TIMEOUT))
    _summ_line(f, string.format("Avg Rounds=%.2f  Avg Turns=%.2f", rate(ga.rounds,ga.matches), rate(ga.turns,ga.matches)))
    _summ_line(f, string.format("HitRate P1=%.3f  P2=%.3f", rate(ga.attacks_hits[1],ga.attacks_attempted[1]), rate(ga.attacks_hits[2],ga.attacks_attempted[2])))
    _summ_line(f, string.format("WastedAtkRate P1=%.3f  P2=%.3f", rate(ga.wasted_attacks[1],ga.attacks_attempted[1]), rate(ga.wasted_attacks[2],ga.attacks_attempted[2])))
    _summ_line(f, string.format("Progress (net toward finish): P1=%d  P2=%d", ga.progress_total[1], ga.progress_total[2]))
    _summ_line(f, string.format("Threat Δ (up/down/flat) P1=%d/%d/%d  P2=%d/%d/%d",
      ga.threat_delta[1].up, ga.threat_delta[1].down, ga.threat_delta[1].flat,
      ga.threat_delta[2].up, ga.threat_delta[2].down, ga.threat_delta[2].flat))
    _summ_line(f, string.format("K/D P1=%.3f  P2=%.3f", rate(ga.captures[1],ga.captures[2]), rate(ga.captures[2],ga.captures[1])))
    _summ_line(f, string.format("RevealsUse P1=%.3f  P2=%.3f",
      rate(ga.reveals_used[1], ga.reveals_avail[1]),
      rate(ga.reveals_used[2], ga.reveals_avail[2])))
    _summ_line(f, string.format("Buffs Drawn P1=%d P2=%d  Assigned P1=%d P2=%d",
      ga.buffs_drawn[1], ga.buffs_drawn[2], ga.buffs_assigned[1], ga.buffs_assigned[2]))
    _summ_line(f, string.format("Token pickups (move): P1=%d P2=%d", ga.token_pickups_move[1], ga.token_pickups_move[2]))
    _summ_line(f, "")
  end

  if SUMMARY_INCLUDE_PER_MATCH_ROWS and per_match_rows and #per_match_rows>0 then
    _summ_line(f, "== Per-Match Rows (CSV) ==")
    _summ_line(f, "pairIndex,matchIndex,P1_diff,P2_diff,winner,rounds,turns,hitRateP1,hitRateP2,capturesP1,capturesP2,wastedP1,wastedP2,seed")
    for _,r in ipairs(per_match_rows) do
      _summ_line(f, table.concat({
        r.pairIndex, r.matchIndex, r.p1, r.p2, r.winner, r.rounds, r.turns,
        string.format("%.4f", r.hitRateP1 or 0), string.format("%.4f", r.hitRateP2 or 0),
        r.capturesP1 or 0, r.capturesP2 or 0,
        r.wastedP1 or 0, r.wastedP2 or 0,
        r.seed or -1
      }, ","))
    end
    _summ_line(f, "")
  end

  if SUMMARY_INCLUDE_HEALTHCHECKS then
    _summ_line(f, "== Healthchecks ==")
    local ga = globalAgg
    local hr1 = rate(ga.attacks_hits[1],ga.attacks_attempted[1])
    local hr2 = rate(ga.attacks_hits[2],ga.attacks_attempted[2])
    local ok_hr = (hr1 >= 0.05 and hr1 <= 0.95) and (hr2 >= 0.05 and hr2 <= 0.95)
    _summ_line(f, string.format("Hit rates within [0.05,0.95]? %s (P1=%.3f P2=%.3f)", tostring(ok_hr), hr1, hr2))
    _summ_line(f, "")
  end

  -- JSON tail for machines
  local tail = {
    run = run_meta,
    per_pair = (function()
      local arr = {}
      for _,pp in ipairs(per_pair) do
        arr[#arr+1] = {
          P1 = pp.p1, P2 = pp.p2,
          summary = build_all_matches_summary(pp.agg, pp.p1, pp.p2)
        }
      end
      return arr
    end)(),
    global = build_all_matches_summary(globalAgg, -1, -1)
  }
  _summ_line(f, "--- SUMMARY_JSON_START ---")
  _summ_line(f, JSON.encode(tail))
  _summ_line(f, "--- SUMMARY_JSON_END ---")

  f:close()
end

------------------------------------------------------------
-- Runner (no prompts; uses CONFIG)
------------------------------------------------------------
local function _pairs_to_run()
  if P1_DIFFICULTY == 0 then
    local pairs = {}
    for _,a in ipairs(P1_DIFFICULTY_SET) do
      for _,b in ipairs(P2_DIFFICULTY_SET) do
        pairs[#pairs+1] = {a,b}
      end
    end
    return pairs, string.format("Sweep P1 in %s × P2 in %s", JSON.encode(P1_DIFFICULTY_SET), JSON.encode(P2_DIFFICULTY_SET))
  else
    return { {P1_DIFFICULTY, P2_DIFFICULTY} },
           string.format("Fixed P1=%d P2=%d", P1_DIFFICULTY, P2_DIFFICULTY)
  end
end

local function _ensure_overwrite_ok(fname)
  if not CONFIRM_OVERWRITE then return true end
  -- no prompt requested; but if enabled, abort rather than prompt
  local f = io.open(fname, "r")
  if f then f:close(); io.stderr:write("Refusing to overwrite "..fname.." because CONFIRM_OVERWRITE=true.\n"); return false end
  return true
end

local function main()
  print((
  "Config: \nP1_SET={%s} P2_SET={%s} \nGames=%d \nMaxRounds=%d " ..
  "\nWriteLog=%s Summary=%s JSON=%s DebugBuff=%s SeedBase=%s RerollEachMatch=%s RunId=\"%s\""
):format(
  table.concat(P1_DIFFICULTY_SET, ","),
  table.concat(P2_DIFFICULTY_SET, ","),
  GAMES_PER_PAIR,
  MAX_ROUNDS_PER_MATCH,
  tostring(WRITE_MATCH_LOG),
  tostring(WRITE_SIM_SUMMERY),
  tostring(INCLUDE_JSON_BLOCKS_IN_MATCH_LOG),
  tostring(DEBUG_BUFF),
  tostring(SEED_BASE),
  tostring(REROLL_SEED_EACH_MATCH),
  tostring(RUN_ID_SUFFIX)
))


  local pairs, diffMode = _pairs_to_run()
  local run_meta = {
    run = os.date("!%Y%m%dT%H%M%SZ") .. (RUN_ID_SUFFIX or ""),
    diffMode = diffMode,
    seedBase = SEED_BASE,
    reroll = REROLL_SEED_EACH_MATCH
  }

  -- Open match log if enabled
  local writer = nil
  if WRITE_MATCH_LOG then
    if not _ensure_overwrite_ok(FILENAME_MATCH_LOG) then return end
    local f = _open_file(FILENAME_MATCH_LOG, "w")
    if not f then return end
    writer = new_writer(f)
    writer:header({ run=run_meta.run, diff=diffMode })
  end

  local globalAgg = new_agg()
  local per_pair = {}
  local per_match_rows = {}
  local global_match_index = 0

  for pairIndex, pr in ipairs(pairs) do
    local d1, d2 = pr[1], pr[2]
    local agg = new_agg()

    if writer then writer:pair_header(d1, d2, GAMES_PER_PAIR) end

    for g = 1, GAMES_PER_PAIR do
      global_match_index = global_match_index + 1
      local seed = REROLL_SEED_EACH_MATCH and (SEED_BASE + global_match_index) or SEED_BASE
      _seed_rng(seed)

      local stats, ms = run_match(d1, d2, writer, global_match_index)
      agg_add(agg, stats)
      agg_add(globalAgg, stats)

      if LOG_VERBOSITY >= 2 then statistics_brief(stats) end

      per_match_rows[#per_match_rows+1] = {
        pairIndex=pairIndex, matchIndex=global_match_index,
        p1=d1, p2=d2,
        winner=stats.winner, rounds=stats.rounds, turns=stats.turns,
        hitRateP1 = rate(stats.attacks_hits[1], stats.attacks_attempted[1]),
        hitRateP2 = rate(stats.attacks_hits[2], stats.attacks_attempted[2]),
        capturesP1 = stats.captures[1], capturesP2 = stats.captures[2],
        wastedP1 = stats.wasted_attacks[1] or 0,
        wastedP2 = stats.wasted_attacks[2] or 0,
        seed=seed
      }

      if MAX_MATCH_LOG_LINES and writer and writer.f then
        -- soft guard: if file grows too large, stop writing further matches to log (but keep sim)
        -- (placeholder; implement rotation if needed)
      end
    end

    per_pair[#per_pair+1] = { p1=d1, p2=d2, agg=agg }

    if LOG_VERBOSITY >= 1 then
      print(string.format("[Pair %d] P1=%d vs P2=%d — Games=%d  Wins: P1=%d P2=%d TO=%d",
        pairIndex, d1, d2, agg.matches, agg.wins.P1, agg.wins.P2, agg.wins.TIMEOUT))
    end
  end

  -- Close writer before appending tail JSON (re-open append)
  local headerWritten = false
  if writer and writer.f then
    writer:append_json_block("ALL_MATCHES_SUMMARY", build_all_matches_summary(globalAgg, -1, -1))
    writer.f:close()
    headerWritten = true
  end

  if WRITE_SIM_SUMMERY then
    if not _ensure_overwrite_ok(FILENAME_SIM_SUMMERY) then return end
    write_sim_summary(FILENAME_SIM_SUMMERY, run_meta, per_pair, globalAgg, per_match_rows)
    if LOG_VERBOSITY >= 1 then
  print_overall_console_stats(globalAgg)
end
    if LOG_VERBOSITY >= 1 then print("Summary written to "..FILENAME_SIM_SUMMERY) end
  end

  if WRITE_MATCH_LOG and headerWritten then
    if LOG_VERBOSITY >= 1 then print("Match log written to "..FILENAME_MATCH_LOG) end
  end
end

-- Kick it off
main()

--#endregion Part 3/3