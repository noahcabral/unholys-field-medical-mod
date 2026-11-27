dofile("tests/helpers.lua")
field_medical_catalog_monolith = addon_script("field_medical_catalog_monolith")
field_medical_fetch_monolith = addon_script("field_medical_fetch_monolith")

local settings = read_settings()
settings.catalog.enabled = "true"
settings.medkits.medkit_disabled = 0
local kinds = {
    bandage = "i_medical", medkit = "i_medical", medkit_disabled = "i_medical",
    glucose_s = "i_food", tetanus = "i_medical", yadylin = "i_drug",
    booster_from_a_mod = "i_medical", water = "i_drink", bread = "i_food",
}
function ini_file()
    local ini = {}
    function ini:r_bool(section, key) return settings[section][key] == "true" end
    function ini:r_float(section, key) return settings[section][key] end
    function ini:r_string(section, key) return settings[section][key] end
    function ini:line_exist(section, key) return settings[section][key] ~= nil end
    function ini:line_count(section)
        local n = 0
        for _ in pairs(settings[section]) do n = n + 1 end
        return n
    end
    function ini:r_line(section, index)
        local i = 0
        for key, value in pairs(settings[section]) do
            if i == index then return true, key, value end
            i = i + 1
        end
        return false
    end
    return ini
end
function system_ini()
    return {
        section_exist = function(_, name) return kinds[name] ~= nil end,
        line_exist = function(_, name, key) return key == "kind" and kinds[name] ~= nil end,
        r_string = function(_, name) return kinds[name] end,
    }
end
game = {translate_string = function() return "Points" end}
local logs, callbacks = {}, {}
function printf(_, message) logs[#logs + 1] = message end
function RegisterScriptCallback(event, handler) callbacks[event] = handler end
-- The live Romeo pack has this conflict. Catalog must still start in the menu.
grok_actor_damage_balancer = {on_game_start = true, shit_booster = true}
local adapter = addon_script("zzz_field_medical_monolith")
assert(not adapter.allow_starting_item("glucose_s"))
assert(adapter.allow_starting_item("bandage"))
assert(adapter.allow_generated_item("glucose_s")) -- No world yet.

local function container()
    local cc = {cell = {}}
    function cc:Reinit(sections, values)
        self.cell = {}
        local elements = {}
        for index, section in ipairs(sections) do
            local value = values[index]
            local key = section .. ":" .. value
            if elements[key] then
                elements[key].count = elements[key].count + 1
            else
                local cell = {
                    section = section, flags = {info = value}, count = 1,
                    IsShown = function() return true end,
                    CountChilds = function(self) return self.count - 1 end,
                }
                self.cell[#self.cell + 1] = cell
                elements[key] = cell
            end
        end
    end
    return cc
end
local function contents(cc)
    local by_section = {}
    for _, cell in ipairs(cc.cell) do
        by_section[cell.section] = (by_section[cell.section] or 0) + cell.count
    end
    return by_section
end
local function label()
    return {SetText = function(self, value) self.text = value end}
end

local start_contents
local screen = {
    LoadLoadout = function(dialog, randomized)
        local inventory = {"water", "bread", "yadylin"}
        local costs = {0, 0, 0}
        if randomized then
            inventory = {"water", "bread", "yadylin", "tetanus", "tetanus", "medkit"}
            costs = {0, 0, 0, 60, 60, 20}
        end
        dialog.CC.inventory:Reinit(inventory, costs)
        dialog.CC.loadout:Reinit({"glucose_s", "booster_from_a_mod", "bandage", "bandage", "medkit_disabled"},
            {15, 25, 10, 10, 20})
        dialog.points_used = randomized and 140 or 0
        dialog.points_left = 700 - dialog.points_used
    end,
    OnStartGame = function(dialog) start_contents = contents(dialog.CC.inventory) end,
}
ui_mm_faction_select = {UINewGame = screen}
local inserted, trade, spawned = 0, 0, 0
new_game_loadout_injector_mcm = {add_item = function() inserted = inserted + 1 end}
utils_item = {get_item_trade_status = function() return 1 end}
ui_inventory = {UIInventory = {TMode_Buy = function() trade = trade + 1 end}}
trader_autoinject = {spawn_items = function(_, items)
    assert(not items.tetanus and items.water == 3)
    spawned = spawned + 1
end}
local uses = 0
function CInventory__eat()
    uses = uses + 1
    return true
end

adapter.on_game_start()
assert(logs[1] == "medical catalog registered" and logs[2]:find("Grok", 1, true))
assert(not callbacks.actor_on_update)
local dialog = setmetatable({
    CC = {inventory = container(), loadout = container()},
    text_points_left = label(),
    text_points_used = label(),
}, {__index = screen})
dialog:LoadLoadout(false)
local available = contents(dialog.CC.loadout)
assert(available.bandage == 2 and not available.glucose_s and not available.booster_from_a_mod)
assert(not available.medkit_disabled)
assert(contents(dialog.CC.inventory).water == 1 and not contents(dialog.CC.inventory).yadylin)
dialog:LoadLoadout(true)
assert(dialog.points_used == 20 and dialog.points_left == 680)
assert(dialog.text_points_used.text == "20" and dialog.text_points_left.text == "680")
assert(contents(dialog.CC.inventory).medkit == 1 and not contents(dialog.CC.inventory).tetanus)
dialog.CC.inventory:Reinit({"bread", "glucose_s"}, {0, 15})
dialog:OnStartGame()
assert(start_contents.bread == 1 and not start_contents.glucose_s)

new_game_loadout_injector_mcm.add_item({section = "yadylin"})
new_game_loadout_injector_mcm.add_item({section = "water"})
assert(inserted == 1)
db = {actor = {}}
assert(not adapter.allow_generated_item("yadylin"))
local item = function(section) return {section = function() return section end} end
local medicine = item("tetanus")
assert(not CInventory__eat(medicine) and uses == 0)
assert(CInventory__eat(item("water")) and uses == 1)
local flags = {ret_value = true}
callbacks.actor_on_item_before_use(medicine, flags)
assert(not flags.ret_value)
assert(utils_item.get_item_trade_status(medicine) == 3)
assert(utils_item.get_item_trade_status(item("water")) == 1)
trader_autoinject.spawn_items({}, {tetanus = 2, water = 3})
assert(spawned == 1)
level = {object_by_id = function(id) return id == 1 and medicine or item("water") end}
local buy = ui_inventory.UIInventory.TMode_Buy
buy({CC = {npc_trade = {indx_id = {[1] = true}}}})
assert(trade == 0)
buy({CC = {npc_trade = {indx_id = {[2] = true}}}})
assert(trade == 1)
