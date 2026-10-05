-- 从补丁树和 SMODS 提取真实牌型函数. 入参可指定补丁树目录.
local root = (arg[1] or '.tmp/engine-audit/modded-tree'):gsub('/$', '') .. '/'
local function source(path)
    local f = assert(io.open(path, 'r'))
    local text = f:read('*a'); f:close(); return text
end
local function extract(path, begin_marker, end_marker)
    local text = source(path)
    local begin = assert(text:find(begin_marker, 1, true))
    local finish = assert(text:find(end_marker, begin + #begin_marker, true))
    assert((loadstring or load)(text:sub(begin, finish - 1), '@' .. path))()
end
SMODS = {Ranks = {}, Rank = {obj_buffer = {}, max_id = {value = 14}}, Suit = {obj_buffer = {'Spades','Hearts','Clubs','Diamonds'}}}
for rank = 2, 14 do
    local key = tostring(rank)
    SMODS.Rank.obj_buffer[#SMODS.Rank.obj_buffer + 1] = key
    SMODS.Ranks[key] = {id = rank, next = {tostring(rank == 14 and 2 or rank+1)}, straight_edge = rank == 14}
end
local four, shortcut, smeared = false, false, false
SMODS.four_fingers = function() return four and 4 or 5 end
SMODS.shortcut = function() return shortcut end
SMODS.wrap_around_straight = function() return false end
SMODS.has_no_rank = function(c) return c.stone end
SMODS.has_no_suit = function(c) return c.stone end
SMODS.merge_lists = function(...)
    local result, seen = {}, {}
    for _, lists in ipairs({...}) do for _, group in ipairs(lists) do for _, c in ipairs(group) do
        if not seen[c] then result[#result+1] = c; seen[c] = true end
    end end end
    return result
end
extract(root .. 'functions/misc_functions.lua', 'function get_flush(hand)', '-- Function overridden')
extract(root .. 'functions/misc_functions.lua', 'function get_X_same(num, hand, or_more)', 'function get_highest(hand)')
extract(root .. 'functions/misc_functions.lua', 'function get_highest(hand)', 'function ')
extract(root .. 'lovely_shim/mods/Steamodded/src/overrides.lua', 'function get_straight(hand, min_length, skip, wrap)', 'function G.UIDEF.deck_preview')
Card = {}
extract(root .. 'card.lua', 'function Card:get_nominal(mod)', 'function Card:get_id()')
SMODS.PokerHands = {}
G = {init_game_object = function() return {hands = setmetatable({}, {__index = function() return {} end})} end}
handlist = {'Flush Five','Flush House','Five of a Kind','Straight Flush','Four of a Kind','Full House','Flush','Straight','Three of a Kind','Two Pair','Pair','High Card'}
G.handlist = handlist
copy_table = function(t) return t end
SMODS.PokerHand = function(hand) SMODS.PokerHands[hand.key] = hand end
extract(root .. 'lovely_shim/mods/Steamodded/src/game_object.lua', '    local hands = G:init_game_object().hands', '    -------------------------------------------------------------------------------------------------')
local suit_name = {S='Spades', H='Hearts', C='Clubs', D='Diamonds'}
local suit_nominal = {S=0.04,H=0.03,C=0.02,D=0.01}
local rank_id = {A=14,K=13,Q=12,J=11,T=10}
local function card(code, index)
    local suit, rank = code:match('([SHCD])_(.+)')
    local id = rank_id[rank] or tonumber(rank)
    local c = {index=index, id=id, suit=suit_name[suit], stone=false, wild=false, debuff=false, unique_val=1-index/1603301}
    c.base = {nominal = id == 14 and 11 or math.min(id,10), face_nominal = (id >= 11 and id <= 13) and (id-10)*0.1 or 0, suit_nominal=suit_nominal[suit], suit_nominal_original=suit_nominal[suit]}
    c.get_id = function(self) return self.stone and -100-index or self.id end
    c.get_nominal = Card.get_nominal
    c.is_suit = function(self, target)
        if self.stone then return false end
        if self.wild and not self.debuff then return true end
        local red = {Hearts=true, Diamonds=true}
        return self.suit == target or (smeared and not not red[self.suit] == not not red[target])
    end
    return c
end
local function evaluate(hand)
    local pairs = get_X_same(2, hand, true)
    local parts = {_highest=get_highest(hand), _straight=get_straight(hand, SMODS.four_fingers(), shortcut, false), _flush=get_flush(hand), _all_pairs={}}
    if #pairs > 0 then parts._all_pairs = {SMODS.merge_lists(pairs)} end
    for i=2,5 do parts['_'..i] = get_X_same(i, hand, true) end
    local result = {}
    for _, key in ipairs(handlist) do result[key] = SMODS.PokerHands[key].evaluate(parts, hand) or {} end
    return result
end
local cases = {
    {codes={'S_2','S_3','S_4','H_5','S_K'}, four=true},
    {codes={'S_2','H_4','C_6','D_8','S_T'}, shortcut=true},
    {codes={'S_Q','H_K','C_A','D_2','S_3'}, shortcut=true},
    {codes={'S_2','H_2','S_3','H_3','S_4','H_4'}},
    {codes={'S_2','H_3','C_4','D_5','S_6','H_7'}},
    {codes={'S_2','S_3','S_4','S_5','S_6','S_7'}},
    {codes={'S_2','H_2','C_2','S_3','H_3'}},
    {codes={'S_2','H_2','C_2','D_2','S_2'}},
    {codes={'S_2','H_3','C_4','D_5','S_5'}, four=true},
    {codes={'H_2','D_3','H_4','D_5','H_6'}, smeared=true},
}
for _, case in ipairs(cases) do
    four, shortcut, smeared = not not case.four, not not case.shortcut, not not case.smeared
    local hand = {}; for index, code in ipairs(case.codes) do hand[index] = card(code, index) end
    local result = evaluate(hand)
    for _, key in ipairs(handlist) do if #result[key] > 0 then
        local indices = {}; for _, c in ipairs(result[key][1]) do indices[#indices+1] = c.index-1 end
        table.sort(indices)
        print(table.concat(case.codes, ',') .. '\t' .. (four and '1' or '0') .. (shortcut and '1' or '0') .. (smeared and '1' or '0') .. '\t' .. key .. '\t' .. table.concat(indices, ','))
    end end
end
