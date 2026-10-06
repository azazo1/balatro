-- 执行补丁源码内的真实复制和排序函数, 不依赖游戏窗口.
local root = (arg[1] or '.tmp/engine-audit/modded-tree') .. '/'
local function load_function(path, signature)
    local file = assert(io.open(root .. path, 'r'))
    local text = file:read('*a'); file:close()
    local first = assert(text:find(signature, 1, true))
    local last = text:find('\nfunction ', first + #signature, true) or (#text + 1)
    assert(loadstring(text:sub(first, last - 1)))()
end
SMODS = {
    enh_cache = {write = function() end},
    Ranks = {['2'] = {nominal = 2, face_nominal = 0, id = 2},
        Ace = {nominal = 11, face_nominal = 0.4, id = 14}},
    Suits = {Clubs = {suit_nominal = 0.02}, Diamonds = {suit_nominal = 0.01},
        Hearts = {suit_nominal = 0.03}, Spades = {suit_nominal = 0.04}},
    has_no_suit = function(card) return card.ability.name == 'Stone Card' end,
    has_no_rank = function(card) return card.ability.name == 'Stone Card' end,
}
G = {CARD_W = 1, CARD_H = 1, C = {SUITS = {}}, P_CARDS = {empty = {}},
    P_CENTERS = {c_base = {name = 'Base Card'}}, GAME = {selected_back = {pos = {}}}}
for _, suit in ipairs({'Clubs', 'Diamonds', 'Hearts', 'Spades'}) do
    G.P_CARDS[suit .. '_2'] = {suit = suit, value = '2', name = suit .. ' 2'}
    G.P_CARDS[suit .. '_A'] = {suit = suit, value = 'Ace', name = suit .. ' A'}
end
function check_for_unlock() end
function copy_table(value)
    local result = {}; for key, entry in pairs(value) do
        result[key] = type(entry) == 'table' and copy_table(entry) or entry
    end; return result
end
Card = {}
Card.__index = Card
function Card:set_sprites() end
function Card:set_ability(center) self.config.center = center; self.ability = {name = center.name, type = ''} end
function Card:set_edition(edition) self.edition = next(edition) and copy_table(edition) or nil end
function Card:set_seal(seal) self.seal = seal end
function Card:set_cost() end
setmetatable(Card, {__call = function(_, x, y, w, h, front, center)
    local card = setmetatable({T = {x = x, y = y}, config = {}, unique_val = 1}, Card)
    card:set_base(front, true); card:set_ability(center); return card
end})
load_function('card.lua', 'function Card:set_base(')
load_function('card.lua', 'function Card:get_nominal(')
load_function('functions/common_events.lua', 'function copy_card(')
local source = Card(0, 0, 1, 1, G.P_CARDS.Diamonds_A, G.P_CENTERS.c_base)
source:set_base(G.P_CARDS.Hearts_A)
source.unique_val = 1 - 29 / 1603301
source.ability.played_this_ante = true
local target = Card(0, 0, 1, 1, G.P_CARDS.Clubs_2, G.P_CENTERS.c_base)
target.unique_val = 1 - 17 / 1603301
copy_card(source, target)
local duplicate = copy_card(source)
duplicate.unique_val = 1 - 31 / 1603301
for _, entry in ipairs({{'source', source}, {'target', target}, {'duplicate', duplicate}}) do
    print(string.format('%s %.3f %.15f %.15f', entry[1],
        entry[2].base.suit_nominal_original, entry[2]:get_nominal(), entry[2]:get_nominal('suit')))
end
assert(source.base.suit_nominal_original == 0.01)
assert(target.base.suit_nominal_original == 0.02)
assert(duplicate.base.suit_nominal_original == 0)
assert(target.ability.played_this_ante == true)
assert(duplicate.ability.played_this_ante == true)
source.ability.name = 'Stone Card'
print(string.format('stone %.15f %.15f', source:get_nominal(), source:get_nominal('suit')))
assert(target:get_nominal('suit') > duplicate:get_nominal('suit'))

-- 使用真实注册缓冲区方法和花色注册声明确定随机池顺序,不能沿用原版硬编码表.
local game_object_path = root .. 'lovely_shim/mods/Steamodded/src/game_object.lua'
local file = assert(io.open(game_object_path, 'r'))
local definitions = file:read('*a'); file:close()
SMODS.GameObject = {}
for _, signature in ipairs({'function SMODS.GameObject:__internal_register(',
    'function SMODS.GameObject:obj_list('}) do
    local first = assert(definitions:find(signature, 1, true))
    local last = assert(definitions:find('\n    end', first, true)) + #'\n    end'
    assert(loadstring(definitions:sub(first, last)))()
end
SMODS.Suit = setmetatable({obj_table = {}, obj_buffer = {}}, {
    __index = SMODS.GameObject,
    __call = function(class, object) class:__internal_register(object, {}) end,
})
for body in definitions:gmatch('SMODS%.Suit%s*{(.-)\n%s*}') do
    assert(loadstring('SMODS.Suit {' .. body .. '\n}'))()
end
local keys = {}
for _, suit in ipairs(SMODS.Suit:obj_list(true)) do keys[#keys+1] = suit.card_key end
assert(table.concat(keys, ',') == 'S,H,C,D')
print('suit_buffer ' .. table.concat(keys, ','))

local rank_class = assert(definitions:find('SMODS.Rank = SMODS.GameObject:extend', 1, true))
local register_start = assert(definitions:find('register = function(self)', rank_class, true)) + #'register = '
local register_end = assert(definitions:find('\n        end,', register_start, true)) + #'\n        end' - 1
local rank_register = assert(loadstring('return ' .. definitions:sub(register_start, register_end)))()
SMODS.Rank = setmetatable({obj_table = {}, obj_buffer = {}, used_card_keys = {},
    max_id = {value = 1}, max_sort_id = {value = 13}, register = rank_register,
    check_dependencies = function() return true end}, {
    __index = SMODS.GameObject,
    __call = function(class, object)
        setmetatable(object, {__index = class}); class.register(object)
    end,
})
local rank_start = assert(definitions:find('for _, v in ipairs({ 2, 3, 4, 5, 6, 7, 8, 9 }) do', rank_class, true))
local rank_end = assert(definitions:find('-- make consumable effects compatible', rank_start, true))
assert(loadstring(definitions:sub(rank_start, rank_end - 1)))()
keys = {}
for _, rank in ipairs(SMODS.Rank:obj_list()) do keys[#keys+1] = rank.card_key end
assert(table.concat(keys, ',') == '2,3,4,5,6,7,8,9,T,J,Q,K,A')
print('rank_buffer ' .. table.concat(keys, ','))

-- 注册缓冲区只是中间态,真实选择函数还会再次按对象 sort_id 排序.
load_function('functions/misc_functions.lua', 'function pseudorandom_element(')
SMODS.Suits = SMODS.Suit.obj_table
SMODS.Ranks = SMODS.Rank.obj_table
local original_random = math.random
local final_suits, final_ranks = {}, {}
for i = 1, 4 do
    math.random = function(count) assert(count == 4); return i end
    final_suits[i] = pseudorandom_element(SMODS.Suits).card_key
end
for i = 1, 13 do
    math.random = function(count) assert(count == 13); return i end
    final_ranks[i] = pseudorandom_element(SMODS.Ranks).card_key
end
-- 同一终端 picker 对 Card 对象按出生身份选择,不因合法区域重排而改变候选顺序.
local born_first, born_second = {sort_id=17, key='first'}, {sort_id=29, key='second'}
for index = 1, 2 do
    math.random = function(count) assert(count == 2); return index end
    local forward = pseudorandom_element({born_first, born_second})
    local reverse = pseudorandom_element({born_second, born_first})
    assert(forward == reverse)
    assert(forward == (index == 1 and born_first or born_second))
end
math.random = original_random
assert(table.concat(final_suits, ',') == 'S,H,D,C')
assert(table.concat(final_ranks, ',') == '2,3,4,5,6,7,8,9,T,J,Q,K,A')
print('final_suit_pool ' .. table.concat(final_suits, ','))
print('final_rank_pool ' .. table.concat(final_ranks, ','))
