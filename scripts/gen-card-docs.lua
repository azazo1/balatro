-- 从 1.0.1o 游戏原型和本地化生成 agent 卡牌参考目录.
-- 只加载静态原型和描述函数, 不启动 LÖVE, 不读取或写入存档.
local function read_source(path)
    local f = assert(io.open(path, 'rb'))
    local text = f:read('*a'); f:close()
    return text
end
local function log(message) io.stderr:write('[card-docs] '..message..'\n') end
local function function_source(path, signature)
    local text = read_source(path)
    local first = assert(text:find(signature, 1, true), signature)
    local last = text:find('\nfunction ', first + #signature, true)
    return text:sub(first, last and last - 1 or #text)
end
local function execute(text, name) assert(loadstring(text, '@'..name))() end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local function sorted_keys(t)
    local keys = {}; for k in pairs(t) do keys[#keys+1] = k end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
    return keys
end
local function quote(s)
    return '"'..s:gsub('[%z\1-\31\\"]', function(c)
        local special = {['\n']='\\n', ['\r']='\\r', ['\t']='\\t', ['\\']='\\\\', ['"']='\\"'}
        return special[c] or string.format('\\u%04x', c:byte())
    end)..'"'
end
local array_mt = {}
local function array(t) return setmetatable(t or {}, array_mt) end
local function json(value, indent)
    local kind = type(value)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' or kind == 'number' then return tostring(value) end
    if kind == 'string' then return quote(value) end
    assert(kind == 'table', '非 JSON 类型: '..kind)
    local parts = {}
    local next_indent = indent and indent+2 or nil
    local is_array=getmetatable(value) == array_mt or #value > 0
    if is_array then
        for i = 1, #value do parts[#parts+1] = json(value[i],next_indent) end
    else
        for _, k in ipairs(sorted_keys(value)) do
            parts[#parts+1] = quote(tostring(k))..(indent and ': ' or ':')..json(value[k],next_indent)
        end
    end
    local open,close=is_array and '[' or '{',is_array and ']' or '}'
    if #parts==0 then return open..close end
    if indent then
        return open..'\n'..string.rep(' ',next_indent)..table.concat(parts,',\n'..string.rep(' ',next_indent))..'\n'..string.rep(' ',indent)..close
    end
    return open..table.concat(parts,',')..close
end
local function write_file(path, contents)
    local old = io.open(path, 'rb')
    if old then old:read('*a'); old:close() end
    local f = assert(io.open(path, 'wb')); assert(f:write(contents)); f:close()
end
local punctuation = {['。']='.', ['，']=',', ['“']='"', ['”']='"', ['‘']="'", ['’']="'", ['；']=';', ['：']=':', ['！']='!', ['？']='?', ['（']='(', ['）']=')', ['【']='[', ['】']=']', ['、']=','}
local function clean(text)
    for a, b in pairs(punctuation) do text = text:gsub(a,b) end
    local chars, previous = {}, nil
    for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local kind = char:byte() >= 228 and 'han' or char:match('[A-Za-z0-9$]') and 'ascii' or 'other'
        if previous and ((previous=='han' and kind=='ascii') or (previous=='ascii' and kind=='han')) then chars[#chars+1]=' ' end
        chars[#chars+1]=char; previous=kind
    end
    return table.concat(chars)
end

log('加载原型, 禁止访问存档')
execute(read_source('game/engine/object.lua'), 'game/engine/object.lua')
Moveable = Object
G = {C = {UI={}, SUITS={}, HAND_LEVELS={}}, UIT={}, SETTINGS={profile=1}, OVERLAY_MENU=true}
HEX = function() return {} end
DynaText = function() return {} end
number_format = tostring
copy_table = copy
pseudoseed = function() return 0 end
pseudorandom_element = function(t) return t[1] end
get_starting_params = function() return {} end
get_challenge_int_from_id = function() return nil end
desc_from_rows = function(rows) return rows end
local dictionaries = {
            zh = assert(loadfile('game/localization/zh_CN.lua'))(),
    en = assert(loadfile('game/localization/en-us.lua'))(),
}
local lang = 'zh'
local current_render_key, dynamic_values
local missing = {}
local function render_line(line, vars)
    line = line:gsub('{[^}]*}', ''):gsub('#(%d+)#', function(i)
        local value = vars and vars[tonumber(i)]
        if value == nil then
            missing[#missing+1] = lang..': '..line..' #'..i..'#'
            return '[缺失变量 '..i..']'
        end
        return tostring(value)
    end)
    return clean(line)
end
function localize(args, category)
    local loc = dictionaries[lang]
    if type(args) == 'string' then return (loc.misc[category or 'dictionary'] or {})[args] or args end
    if args.type == 'variable' then
        local value = assert(loc.misc.v_dictionary[args.key], args.key)
        if type(value) == 'table' then value = table.concat(value, ' ') end
        return render_line(value, args.vars)
    end
    local group = (args.type == 'other') and 'Other' or args.set
    local entry = assert((loc.descriptions[group] or {})[args.key], tostring(group)..'/'..tostring(args.key))
    if args.type == 'name_text' or args.type == 'name' then return clean(type(entry.name)=='table' and table.concat(entry.name,' ') or entry.name) end
    local result = array()
    local variables = copy(args.vars or {})
    if args.type ~= 'unlocks' and args.key == current_render_key then
        for i, value in pairs((dynamic_values or {})[args.key] or {}) do variables[i] = value end
    end
    local lines = args.type == 'unlocks' and (entry.unlock or {}) or (entry.text or {})
    for _, line in ipairs(lines) do
        result[#result+1] = render_line(line, variables)
        if args.nodes then args.nodes[#args.nodes+1] = result[#result] end
    end
    return result
end
execute('Game = Object:extend()\n'..function_source('game/game.lua', 'function Game:init_game_object()'), 'game/game.lua')
local init = function_source('game/game.lua', 'function Game:init_item_prototypes()')
local cut = assert(init:find('    self.P_CENTER_POOLS = {', 1, true))
execute(init:sub(1, cut-1)..'\nend', 'game/game.lua')
Game.init_item_prototypes(G)
for _, group in ipairs({G.P_CENTERS, G.P_TAGS, G.P_BLINDS, G.P_STAKES}) do
    for k, center in pairs(group) do center.key = k end
end
G.GAME = Game.init_game_object(G)
G.GAME.probabilities.normal = '[概率倍率 normal, 默认 1]'
G.GAME.consumeable_usage = {}
G.jokers = {cards={}, config={card_limit=5}}
G.consumeables = {cards={}}
G.PROFILES = {{career_stats=setmetatable({}, {__index=function() return '[当前存档累计值]' end}), voucher_usage={v_blank={count='[当前存档空白兑换次数]'}}}}
local original_ui_source = function_source('game/functions/common_events.lua', 'function generate_card_ui(')
execute(original_ui_source, 'game/functions/common_events.lua')
local original_ui = generate_card_ui
local dynamic = {
    j_fortune_teller={[2]='[已使用塔罗牌总数]'}, j_steel_joker={[2]='[当前乘倍率]'},
    j_stone={[2]='[当前筹码]'}, j_green_joker={[3]='[当前倍率]'}, j_blue_joker={[2]='[剩余抽牌堆张数乘 2]'},
    j_stencil={[1]='[空槽数加模板张数]'}, j_ceremonial={[1]='[当前倍率]'}, j_loyalty_card={[3]='[距下次激活的倒计数]'},
    j_abstract={[2]='[当前小丑张数乘 3]'}, j_trousers={[3]='[当前倍率]'}, j_ride_the_bus={[2]='[当前倍率]'},
    j_todo_list={[2]='[本回合目标牌型]'}, j_constellation={[2]='[当前乘倍率]'}, j_swashbuckler={[1]='[其他小丑售价总和]'},
    j_throwback={[2]='[当前乘倍率]'}, j_glass={[2]='[当前乘倍率]'}, j_wee={[1]='[当前筹码]'},
    j_idol={[2]='[本回合目标点数]',[3]='[本回合目标花色]'}, j_hit_the_road={[2]='[本回合当前乘倍率]'},
    j_red_card={[2]='[当前倍率]'}, j_madness={[2]='[当前乘倍率]'}, j_square={[1]='[当前筹码]'},
    j_vampire={[2]='[当前乘倍率]'}, j_hologram={[2]='[当前乘倍率]'}, j_cloud_9={[2]='[完整牌组中 9 的张数]'},
    j_rocket={[1]='[当前收入, 初始 1]'}, j_obelisk={[2]='[当前乘倍率]'}, j_turtle_bean={[1]='[当前手牌加成, 初始 5]'},
    j_erosion={[2]='[当前倍率]',[3]='[本局初始牌组张数]'}, j_mail={[2]='[本回合目标点数]'}, j_bull={[2]='[非负金钱乘 2]'},
    j_runner={[1]='[当前筹码, 初始 0]'}, j_ice_cream={[1]='[当前筹码, 初始 100]'},
    j_lucky_cat={[2]='[当前乘倍率]'}, j_selzer={[1]='[剩余有效出牌次数, 初始 10]'},
    j_flash={[2]='[当前倍率]'}, j_popcorn={[1]='[当前倍率, 初始 20]'}, j_ramen={[1]='[当前乘倍率, 初始 2]'},
    j_ancient={[2]='[本回合目标花色]'}, j_castle={[2]='[本回合目标花色]',[3]='[当前筹码]'},
    j_campfire={[2]='[当前乘倍率]'}, j_invisible={[2]='[已持有回合数]'}, j_satellite={[2]='[已使用不同星球种数]'},
    j_drivers_license={[2]='[增强牌总数]'}, j_bootstraps={[3]='[当前倍率]'}, j_caino={[2]='[当前乘倍率]'},
    j_yorick={[3]='[距下次增长所需弃牌张数]',[4]='[当前乘倍率]'},
    c_temperance={[2]='[当前可得金额]'}, c_fool={[1]='[上次使用的塔罗或星球]'},
    c_ectoplasm={[1]='[本局灵质使用次数加 1]'},
    tag_orbital={[1]='[该标签指定牌型]'},
    tag_handy={[2]='[累计出牌次数]'}, tag_garbage={[2]='[累计未用弃牌次数]'},
    tag_skip={[2]='[累计跳过数含本次, 乘 5]'},
    bl_ox={[1]='[本盲注固定惩罚牌型]'},
}
for key, center in pairs(G.P_CENTERS) do
    if center.set=='Planet' then dynamic[key] = {[1]='[当前等级]'} end
end
dynamic_values = dynamic
local captured_vars
function generate_card_ui(center, full, vars, ...)
    if not full then
        vars = copy(vars or {})
        for i, v in pairs(dynamic[center.key] or {}) do vars[i] = v end
        captured_vars = copy(vars)
    end
    return original_ui(center, full, vars, ...)
end
execute('Card = Moveable:extend()\n'..function_source('game/card.lua', 'function Card:set_ability(')..'\n'..function_source('game/card.lua', 'function Card:generate_UIBox_ability_table()'), 'game/card.lua')
execute('Tag = Object:extend()\n'..function_source('game/tag.lua', 'function Tag:get_uibox_table('), 'game/tag.lua')
execute('Back = Object:extend()\n'..function_source('game/back.lua', 'function Back:generate_UI('), 'game/back.lua')
G.CHALLENGES = {}; execute(read_source('game/challenges.lua'), 'game/challenges.lua')

local function render_center(center)
    current_render_key = center.key
    local c = copy(center); c.discovered = true; c.unlocked = true
    if c.set == 'Joker' then
        local card = setmetatable({T={x=0,y=0,w=1,h=1}, config={center=c,card={}},params={},base={},
            bypass_lock=true, bypass_discovery_ui=true, set_sprites=function() end}, Card)
        card:set_ability(c, true)
        local result = card:generate_UIBox_ability_table()
        if c.key == 'j_misprint' then return array({lang=='zh' and '+0 至 +23 倍率, 每次出牌随机取值.' or '+0 to +23 Mult, sampled on each hand.'}) end
        return array(result.main)
    elseif c.set == 'Back' then
        local back = {name=c.name,effect={center=c, config=c.config}}
        local result = Back.generate_UI(back)
        return array(result.nodes[1])
    elseif c.set == 'Tag' then
        local result = Tag.get_uibox_table({name=c.name,key=c.key,config=c.config,ability={orbital_hand='High Card'}}, {})
        return array(result.ability_UIBox_table.main)
    elseif c.set == 'Blind' or c.set == 'Stake' or c.set == 'Seal' then
        return localize{type='raw_descriptions',set=c.set=='Seal' and 'Other' or c.set,
            key=c.set=='Seal' and c.key:lower()..'_seal' or c.key, vars=c.vars or {}}
    end
    local result = generate_card_ui(c, nil, nil, c.set)
    local lines = array()
    for _, line in ipairs(result.main) do if type(line)=='string' then lines[#lines+1] = line end end
    return lines
end
local function source_line(path, key, pattern)
    local text = read_source(path)
    local position = assert(text:find(key, 1, not pattern), key)
    if pattern and text:sub(position,position)=='\n' then position=position+1 end
    local _, lines = text:sub(1,position-1):gsub('\n','\n')
    return lines+1
end
local categories = {
    {set='Joker',file='jokers',title='小丑牌',expected=150},
    {set='Tarot',file='tarots',title='塔罗牌',expected=22},
    {set='Planet',file='planets',title='星球牌',expected=12},
    {set='Spectral',file='spectrals',title='幻灵牌',expected=18},
    {set='Voucher',file='vouchers',title='优惠券',expected=32},
    {set='Back',file='decks',title='牌组',expected=15},
    {set='Tag',file='tags',title='标签',expected=24,group=G.P_TAGS},
    {set='Booster',file='boosters',title='补充包',expected=32},
    {set='Blind',file='blinds',title='盲注',expected=30,group=G.P_BLINDS},
    {set='Enhanced',file='enhancements',title='增强',expected=8},
    {set='Edition',file='editions',title='版本',expected=5},
    {set='Seal',file='seals',title='蜡封',expected=4,group=G.P_SEALS},
    {set='Stake',file='stakes',title='赌注',expected=8,group=G.P_STAKES},
}
local rarity = {'普通 Common','罕见 Uncommon','稀有 Rare','传奇 Legendary'}
local version = read_source('game/version.jkr'):match('([^\n]+)'):gsub('%-FULL','')
assert(version == '1.0.1o', '生成器只针对 1.0.1o 校验')
local catalog = {schema_version=1, game_version=version, records=array(), counts={},
    description_semantics='静态规则文本中的动态值用方括号标记. 不能代替实际局内 ability 状态. unlock_condition 是原型条件, initially_unlocked 不是当前存档解锁状态.'}
for _, category in ipairs(categories) do
    local centers = {}
    for k, center in pairs(category.group or G.P_CENTERS) do
        if (category.group or center.set == category.set) and not center.omit then
            local c = copy(center); c.key=k; c.set=category.set; centers[#centers+1]=c
        end
    end
    table.sort(centers, function(a,b) return a.order < b.order end)
    assert(#centers == category.expected, category.set..' 数量错误: '..#centers)
    catalog.counts[category.set] = #centers
    log(category.set..': '..#centers)
    local markdown = {'# '..category.title..'目录\n',
        '版本: '..version..'. 共 '..#centers..' 项. [总索引](<../README.md>).\n',
        '以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.\n',
        '小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.\n',
        '## 快速定位\n'}
    local records = {}
    for _, center in ipairs(centers) do
        local record = {id=center.key,category=category.set,order=center.order,base_cost=center.cost,
            config=copy(center.config or {}), initially_unlocked=center.unlocked, unlock_condition=copy(center.unlock_condition),
            requires=copy(center.requires),hidden=center.hidden,enhancement_gate=center.enhancement_gate,
            yes_pool_flag=center.yes_pool_flag,no_pool_flag=center.no_pool_flag,rarity=center.rarity,
            blueprint_compat=center.blueprint_compat,eternal_compat=center.eternal_compat,perishable_compat=center.perishable_compat,
            min_ante=center.min_ante,weight=center.weight,kind=center.kind,boss=copy(center.boss),
            blind_multiplier=center.mult,reward_dollars=center.dollars,debuff=copy(center.debuff)}
        local file = 'game/game.lua'
        record.source = {path=file,line=source_line(file,'\n *'..center.key..'%s*=',true)}
        for _, language in ipairs({'zh','en'}) do
            lang=language
            local loc_group = category.set=='Seal' and 'Other' or category.set
            local loc_key = category.set=='Seal' and center.key:lower()..'_seal' or center.key
            if category.set=='Booster' then loc_group='Other'; loc_key=center.key:gsub('_%d+$','') end
            record['name_'..language] = localize{type='name_text',set=loc_group,key=loc_key}
            record['effect_'..language] = render_center(center)
            if center.unlock_condition and category.set~='Back' then
                local unlocked = generate_card_ui(center, nil, {not_hidden=true}, 'Locked')
                record['unlock_'..language] = array(unlocked.main)
            end
        end
        records[#records+1]=record; catalog.records[#catalog.records+1]=record
        markdown[#markdown+1] = '- ['..record.name_zh..' / '..center.key..'](#'..center.key:gsub('_','-')..')\n'
    end
    markdown[#markdown+1]='\n## 完整条目\n'
    for _, r in ipairs(records) do
        markdown[#markdown+1]='\n<a id="'..r.id:gsub('_','-')..'"></a>\n\n### '..r.order..'. '..r.name_zh..' / '..r.name_en..'\n\n- ID: `'..r.id..'`.\n'
        if r.base_cost then markdown[#markdown+1]='- 基价: $'..r.base_cost..'.\n' end
        if r.rarity then
            markdown[#markdown+1]='- 稀有度: '..rarity[r.rarity]..'.\n'
            markdown[#markdown+1]='- 可蓝图复制: '..tostring(r.blueprint_compat)..'; 可永恒: '..tostring(r.eternal_compat)..'; 可易腐: '..tostring(r.perishable_compat)..'.\n'
        end
        if r.initially_unlocked~=nil then markdown[#markdown+1]='- 新档初始解锁: '..tostring(r.initially_unlocked)..'.\n' end
        local effect = table.concat(r.effect_zh,' / ')
        markdown[#markdown+1]='- 效果: '..(effect~='' and effect or '无特殊效果')..'\n'
        if r.unlock_zh and #r.unlock_zh>0 then markdown[#markdown+1]='- 解锁说明: '..table.concat(r.unlock_zh,' / ')..'\n' end
        if r.unlock_condition then markdown[#markdown+1]='- 解锁条件原型: `'..json(r.unlock_condition)..'`.\n' end
        if r.requires then
            local meaning = r.category=='Tag' and '存档发现前置' or r.category=='Voucher' and '本局已兑换前置' or '前置原型字段'
            markdown[#markdown+1]='- '..meaning..': `'..json(r.requires)..'`.\n'
        end
        if r.enhancement_gate then markdown[#markdown+1]='- 入池增强门槛: `'..r.enhancement_gate..'`.\n' end
        if r.yes_pool_flag then markdown[#markdown+1]='- 入池要求标记: `'..r.yes_pool_flag..'`.\n' end
        if r.no_pool_flag then markdown[#markdown+1]='- 排除标记: `'..r.no_pool_flag..'`.\n' end
        if next(r.config) then markdown[#markdown+1]='- 原型参数: `'..json(r.config)..'`.\n' end
        if r.blind_multiplier then markdown[#markdown+1]='- 基础分乘数: '..r.blind_multiplier..'; 击败奖励: $'..r.reward_dollars..'.\n' end
        if r.boss then markdown[#markdown+1]='- Boss 候选条件原型: `'..json(r.boss)..'`.\n' end
        if r.weight then markdown[#markdown+1]='- 补充包原型抽取权重: '..r.weight..'.\n' end
        if r.min_ante then markdown[#markdown+1]='- 标签最早底注: '..r.min_ante..'.\n' end
        markdown[#markdown+1]='- 来源: [原型:'..r.source.line..'](<../../../'..r.source.path..'#L'..r.source.line..'>).\n'
    end
    write_file('docs/game/cards/'..category.file..'.md',table.concat(markdown))
end

log('挑战和 52 张基础扑克牌')
catalog.challenges=array(copy(G.CHALLENGES)); catalog.counts.Challenge=#G.CHALLENGES
assert(#catalog.challenges==20)
local challenge_md={'# 挑战目录\n\n版本: '..version..'. 共 20 项. [总索引](<../README.md>). 这里记录完整初始条件和禁用项, 自定义规则的实际含义见 [牌组与挑战机制](<../mechanics/run-modifiers.md>).\n'}
lang='zh'
for i,c in ipairs(catalog.challenges) do
    for _, field in ipairs({'jokers','consumeables','vouchers'}) do c[field]=array(c[field] or {}) end
    c.rules.custom=array(c.rules.custom or {}); c.rules.modifiers=array(c.rules.modifiers or {})
    for _, field in ipairs({'banned_cards','banned_tags','banned_other'}) do c.restrictions[field]=array(c.restrictions[field] or {}) end
    c.name_en=c.name; c.name_zh=localize(c.id,'challenge_names')
    challenge_md[#challenge_md+1]='\n## '..i..'. '..c.name_zh..' / '..c.name_en..'\n\n- ID: `'..c.id..'`.\n'
    for _,field in ipairs({'rules','jokers','consumeables','vouchers','deck','restrictions'}) do
        challenge_md[#challenge_md+1]='\n### '..field..'\n\n```json\n'..json(c[field])..'\n```\n'
    end
    local line=source_line('game/challenges.lua',"id = '"..c.id.."'")
    challenge_md[#challenge_md+1]='\n来源: [挑战原型:'..line..'](<../../../game/challenges.lua#L'..line..'>).\n'
end
write_file('docs/game/cards/challenges.md', table.concat(challenge_md))
catalog.playing_cards=array()
local playing_md={'# 基础扑克牌目录\n\n[总索引](<../README.md>). 标准牌组包含 4 花色乘 13 点数共 52 张, 每种 1 张. A 给 11 筹码, J/Q/K 给 10 筹码, 2-10 按点数给筹码. 石头牌不使用基础点数筹码.\n\n| ID | 花色 | 点数 | 基础筹码 |\n| --- | --- | --- | --- |\n'}
for _,key in ipairs(sorted_keys(G.P_CARDS)) do
    local c=copy(G.P_CARDS[key]); c.id=key
    c.nominal_chips = c.value=='Ace' and 11 or tonumber(c.value) or 10
    c.suit_zh=localize(c.suit,'suits_singular'); c.rank_zh=localize(c.value,'ranks')
    catalog.playing_cards[#catalog.playing_cards+1]=c
    playing_md[#playing_md+1]='| `'..key..'` | '..c.suit_zh..' | '..c.rank_zh..' | '..c.nominal_chips..' |\n'
end
catalog.counts.PlayingCard=#catalog.playing_cards
assert(#catalog.playing_cards==52)
playing_md[#playing_md+1]='\n来源: [52 张原型](<../../../game/game.lua#L299-L352>), [基础牌赋值](<../../../game/card.lua#L173-L219>).\n'
write_file('docs/game/cards/playing-cards.md',table.concat(playing_md))
catalog.hands=copy(G.GAME.hands)
catalog.modifiers=array()
local modifier_md={'# 特殊修饰目录\n\n[总索引](<../README.md>). 这里补充小丑贴纸, 固定位置和负片消耗牌. 计分及失效规则见 [卡牌修饰规则](<../rules/card-modifiers.md>).\n'}
for _, spec in ipairs({
    {id='eternal',set='Other',vars={}},
    {id='perishable',set='Other',vars={5,'[剩余有效回合]'}},
    {id='rental',set='Other',vars={3}},
    {id='pinned_left',set='Other',vars={}},
    {id='e_negative_consumable',set='Edition',vars={1}},
}) do
    local r={id=spec.id,category=spec.set,vars=spec.vars}
    for _, language in ipairs({'zh','en'}) do
        lang=language
        r['name_'..language]=localize{type='name_text',set=spec.set,key=spec.id}
        r['effect_'..language]=localize{type='raw_descriptions',set=spec.set,key=spec.id,vars=spec.vars}
    end
    catalog.modifiers[#catalog.modifiers+1]=r
    modifier_md[#modifier_md+1]='\n## '..r.name_zh..' / '..r.name_en..'\n\n- ID: `'..r.id..'`.\n- 效果: '..table.concat(r.effect_zh,' / ')..'\n'
end
catalog.counts.SpecialModifier=#catalog.modifiers
modifier_md[#modifier_md+1]='\n来源: [小丑修饰提示](<../../../game/functions/common_events.lua#L2722-L2737>), [版本与负片消耗牌](<../../../game/localization/en-us.lua#L332-L373>).\n'
write_file('docs/game/cards/modifiers.md',table.concat(modifier_md))
if #missing>0 then error('描述变量缺失:\n'..table.concat(missing,'\n')) end
write_file('docs/game/data/catalog.json',json(catalog,0)..'\n')
log('完成: '..#catalog.records..' 个卡牌/规则对象, 20 挑战, 52 扑克牌, 12 牌型')
