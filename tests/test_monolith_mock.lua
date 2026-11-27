dofile("tests/helpers.lua")
field_medical_model = addon_script("field_medical_model")
field_medical_fractures = addon_script("field_medical_fractures")
field_medical_fractures_monolith = addon_script("field_medical_fractures_monolith")
field_medical_tourniquet = addon_script("field_medical_tourniquet")
field_medical_catalog_monolith = addon_script("field_medical_catalog_monolith")
field_medical_fetch_monolith = addon_script("field_medical_fetch_monolith")
local settings = read_settings()
local native = {
    armor = {},
    helmet = {fire_wound_param_1 = 0.5, fire_wound_param_2 = 0.8},
    cartridge = {k_ap = 0.3},
    weapon = {ap_modifier = 2},
    bandage = {},
    medkit = {},
    medkit_army = {},
    medkit_scientic = {},
}
local function ini_parser(data)
    local result = {}
    function result:section_exist(name) return data[name] ~= nil end
    function result:line_exist(name, key) return data[name] and data[name][key] ~= nil end
    function result:r_float(name, key) return assert(data[name][key], key) end
    function result:r_string(name, key) return data[name][key] end
    function result:r_bool(name, key) return data[name][key] == "true" end
    function result:line_count(name) local n = 0; for _ in pairs(data[name]) do n = n + 1 end; return n end
    function result:r_line(name, row)
        local n = 0
        for key, value in pairs(data[name]) do
            if n == row then return true, key, value end
            n = n + 1
        end
        return false
    end
    return result
end
function ini_file() return ini_parser(settings) end
function system_ini() return ini_parser(native) end
local last_log
function printf(_, message) last_log = message end

local callbacks = {}
function RegisterScriptCallback(name, fn) callbacks[name] = fn end
local now = 0
function time_global() return now end
callbacks_gameobject = {}
function CBeforeHitAfterCalcs() end
function CBulletOnImpact() end
hit = {fire_wound = 1, wound = 2, wound_2 = 3, burn = 4, strike = 5, explosion = 6}

local conditions = {power = 1, native_wounds = 0}
function conditions:ClearWounds() self.native_wounds = 0 end
function conditions:BleedingSpeed() return self.native_wounds end
function conditions:GetSatiety() return 1 end
function conditions:GetPower() return self.power end
function conditions:SetPower(value) self.power = value end
function conditions:GetMaxPower() return 1 end

local actor = {health = 1, cash = 9000, radiation = 0.3, gear = {}, speed = 1, sprint = 0, sway = 1}
function actor:id() return 0 end
function actor:alive() return self.health > 0 end
function actor:max_health() return 1 end
function actor:set_health_ex(value) self.health = value end
function actor:cast_Actor() return self end
function actor:conditions() return conditions end
function actor:item_in_slot(slot) return self.gear[slot] end
function actor:active_item() return self.held end
function actor:money() return self.cash end
function actor:get_actor_walk_accel() return self.speed end
function actor:set_actor_walk_accel(value) self.speed = value end
function actor:allow_sprint(allowed) self.sprint = self.sprint + (allowed and -1 or 1) end
function actor:set_zoom_inertion_factor(value) self.sway = value end
local bones = {
    [8] = "bip01_l_thigh", [9] = "bip01_l_upperarm", [10] = "bip01_r_forearm",
    [11] = "bip01_spine2", [12] = "bip01_r_calf", [13] = "bip01_head",
}
function actor:bone_name(id) return bones[id] end
db = {actor = actor}

local weapon = {dispersion = 1, ads = 0.5}
function weapon:section() return "weapon" end
function weapon:id() return 11 end
function weapon:cast_Weapon() return self end
function weapon:GetCamDispersion() return self.dispersion end
function weapon:SetCamDispersion(n) self.dispersion = n end
function weapon:GetZoomCamDispersion() return self.ads end
function weapon:SetZoomCamDispersion(n) self.ads = n end
actor.held = weapon

local gear = {armor = 0.6, wear = 1, name = "armor"}
function gear:cast_CustomOutfit() return self end
function gear:cast_Helmet() return self end
function gear:GetBoneArmor() return self.armor end
function gear:condition() return self.wear end
function gear:section() return self.name end
actor.gear[7] = gear

local shade, released, camera = 0, false, nil
level = {
    object_by_id = function(id) return id == 11 and weapon end,
    add_pp_effector = function() shade = 0 end,
    set_pp_effector_factor = function(_, factor) shade = factor end,
    remove_pp_effector = function() shade = 0 end,
    release_action = function() released = true end,
    add_cam_effector = function(path) camera = path end,
    remove_cam_effector = function() camera = nil end,
}
key_bindings = {kWPN_FIRE = 5, kSPRINT_TOGGLE = 23}
function bind_to_dik(key) return key end
actor_status_thirst = {get_water_deprivation = function() return 0 end}
dialogs = {}
function dialogs.relocate_money_from_actor(_, _, fee) actor.cash = actor.cash - fee end
function dialogs.is_actor_injured() return false end
function dialogs.is_actor_injured_irradiated() return false end
function dialogs.is_actor_not_healthy() return false end
function dialogs.heal_actor_injury() error("the native heal should not run") end
function dialogs.heal_actor_injury_radiation() error("the native heal should not run") end

local adapter = addon_script("zzz_field_medical_monolith")
adapter.on_game_start()
assert(callbacks.on_before_hit_after_calcs)
local function step(seconds)
    for _ = 1, math.floor(seconds * 5 + 0.5) do
        now = now + 200
        callbacks.actor_on_update()
    end
end
local function state()
    local output = {}
    callbacks.save_state(output)
    return assert(output.field_medical_blood_v1)
end
local function round(id, cartridge, conditions_before, bone, initial, final)
    local shot = {type = hit.fire_wound, power = initial or 0.25, bullet_id = id}
    if cartridge then
        callbacks.bullet_on_impact({target_id = actor:id(), bullet_id = id, section = cartridge, weapon_id = 11})
    end
    callbacks.actor_on_before_hit(shot, bone or 8, {ret_value = true})
    if conditions_before then conditions_before() end
    if final then shot.power = final end
    callbacks.on_before_hit_after_calcs(shot, actor, bone)
    return shot.power
end

-- Cartridge AP .3 x weapon AP 2 equals the pre-hit armor rating .6. The
-- native armor engine has already reduced condition by the time Lua gets the
-- resolved hit, and the post-armor .25 blunt residual must not create a wound.
near(round(1, "cartridge", function() gear.wear = 0.1 end), 0)
assert(#state().wounds == 0)
near(actor.health, 1)
near(round(2, "cartridge"), 0)
assert(#state().wounds == 1)
near(actor.health, 1)
step(3)
assert(actor.health < 1)

-- A second layer using the engine's alternate formula stops this round.
gear.wear, gear.name = 1, "helmet"
actor.gear[7], actor.gear[12] = nil, gear
near(round(3, "cartridge"), 0)
assert(#state().wounds == 1)
-- If no cartridge is received for a protected hit, retain its native damage.
near(round(4, nil), 0.25)
assert(#state().wounds == 1)
-- Knife or mutant wounds use the resolved hit power, and burns stay native.
for _, event in ipairs({{type = hit.wound, power = 0.09}, {type = hit.wound_2, power = 0.07}}) do
    callbacks.on_before_hit_after_calcs(event, actor)
    near(event.power, 0)
end
assert(#state().wounds == 3)
local burn = {type = hit.burn, power = 0.42}
callbacks.on_before_hit_after_calcs(burn, actor)
near(burn.power, 0.42)
actor.health = actor.health - burn.power
conditions.native_wounds = 0.02
step(0.2)
assert(conditions.native_wounds == 0)
local hp = actor.health
assert(hp < 0.58 and actor.speed < 1 and weapon.dispersion > 1 and shade > 0)
callbacks.actor_on_item_use({section = function() return "bandage" end})
callbacks.actor_on_item_use({section = function() return "medkit_scientic" end})
near(actor.health, hp)
step(18)
near(actor.health, hp)
local saved = {}
callbacks.save_state(saved)
callbacks.load_state(saved)
near(actor.speed, 1)
near(weapon.dispersion, 1)
near(shade, 0)
now = now + 200000
step(0.2)
near(actor.health, hp)
near(state().wounds[1].stable_seconds, settings.blood.stabilization_seconds - 18)
step(282.2)
assert(state().wounds[1].needs_dressing)
callbacks.actor_on_item_use({section = function() return "medkit" end})
assert(state().wounds[1].treatment == "open")
local after_expiry = actor.health
assert(dialogs.is_actor_injured() and dialogs.is_actor_injured_irradiated())
dialogs.heal_actor_injury_radiation(actor, {})
near(actor.health, after_expiry)
near(actor.radiation, 0)
near(actor.cash, 9000 - settings.monolith.doctor_injury_radiation_fee)
assert(#state().wounds == 0 and not dialogs.is_actor_injured())
callbacks.actor_on_sleep(2)
near(actor.health, after_expiry + 2 * settings.blood.rest_blood_per_hour)

actor.health = 0.11
step(0.2)
assert(released and shade == 1)
local flags = {ret_value = true}
callbacks.on_before_key_press(nil, key_bindings.kWPN_FIRE, false, flags)
assert(not flags.ret_value)
step(settings.blood.faint_seconds + 0.2)
flags.ret_value = true
callbacks.on_before_key_press(nil, key_bindings.kWPN_FIRE, false, flags)
assert(flags.ret_value)
XrrSessionActive = true
step(0.2)
near(actor.speed, 1)
near(weapon.dispersion, 1)
near(shade, 0)

-- Start an expanded medical game with the same callbacks and native objects.
XrrSessionActive = nil
settings.catalog.enabled, settings.fractures.enabled, settings.tourniquet.enabled = "true", "true", "true"
settings.tourniquet.duration_seconds = 2
settings.fracture_fall.chance, settings.fracture_penetrating.chance = 1, 1
settings.fracture_blocked.chance, settings.fracture_blunt.chance = 1, 1
math.random = function() return 0.1 end
native.weapon.hud = "weapon_hud"
native.weapon_hud = {anm_reload = "hand, object, 1.2"}
native.analgetic, native.unlisted_mod_drug = {}, {kind = "i_medical"}
native.quest_drug = {kind = "i_medical", quest_item = "true"}
native.water = {kind = "i_drink"}
native.stimpack = {kind = "i_medical"}
native.field_medical_splint, native.field_medical_tourniquet = {kind = "i_medical"}, {kind = "i_medical"}
local messages, gate_calls = {}, 0
actor_menu = {set_msg = function(_, text) messages[#messages + 1] = text end}
function CInventory__eat() gate_calls = gate_calls + 1; return true end
local selected_pool, released_items, added_recipes
zml_loot = {roll_item_tiered = function(pool) selected_pool = pool end}
demonized_crafter = {
    craft_recipes = {tool = {analgetic = {"x:1"}, water = {"y:1", "unlisted_mod_drug>0.2, z:1"}}},
    add_craft_recipe = function(recipes) added_recipes = recipes end,
    remove_craft_recipe = function(recipes)
        for tool, items in pairs(recipes) do
            for name, blocked in pairs(items) do
                local stored = demonized_crafter.craft_recipes[tool][name]
                local keep = {}
                for _, recipe in ipairs(stored) do
                    if recipe ~= blocked[1] then keep[#keep + 1] = recipe end
                end
                demonized_crafter.craft_recipes[tool][name] = #keep > 0 and keep or nil
            end
        end
    end,
}
trader_autoinject = {timed_update = function() end}
released_items = {}
function alife_release_id(id) released_items[id] = true end
function get_object_story_id(id) return id == 93 and "quest_object" or nil end
local function item(section, id)
    return {section = function() return section end, id = function() return id end}
end
local function snapshot()
    local data = {}
    callbacks.save_state(data)
    return data
end
local function fracture_state()
    return assert(snapshot().field_medical_fractures_v1).fractures
end
local function tq_state()
    return assert(snapshot().field_medical_tourniquet_v1).limbs
end

actor.health, actor.cash, actor.radiation = 1, 9000, 0
actor.gear = {}
conditions.power = 1
callbacks = {}
adapter = addon_script("zzz_field_medical_monolith")
adapter.on_game_start()
assert(callbacks.actor_on_land, last_log)
callbacks.actor_on_first_update()
assert(demonized_crafter.craft_recipes.tool.analgetic == nil and demonized_crafter.craft_recipes.tool.water)
assert(#demonized_crafter.craft_recipes.tool.water == 1)
demonized_crafter.add_craft_recipe({tool = {
    ["unlisted_mod_drug:2"] = {"x:1"}, water = {"y:1", "analgetic:1", "water:2"},
}})
assert(added_recipes.tool["unlisted_mod_drug:2"] == nil and added_recipes.tool.water)
assert(#added_recipes.tool.water == 2)
zml_loot.roll_item_tiered({"analgetic", "bandage", "water", "unlisted_mod_drug"})
assert(#selected_pool == 2 and selected_pool[1] == "bandage" and selected_pool[2] == "water")
callbacks.trader_on_restock({id = function() return 100 end, iterate_inventory = function(self, fn)
    fn(self, item("analgetic", 90))
    fn(self, item("water", 91))
end})
assert(released_items[90] and not released_items[91])
callbacks.npc_on_death_callback({id = function() return 101 end, iterate_inventory = function(self, fn)
    fn(self, item("analgetic", 92))
    fn(self, item("analgetic", 93))
    fn(self, item("quest_drug", 94))
end})
assert(released_items[92] and not released_items[93] and not released_items[94])
callbacks.npc_on_net_spawn({id = function() return 102 end, iterate_inventory = function(self, fn)
    fn(self, item("analgetic", 95))
end})
assert(released_items[95])
assert(not CInventory__eat(item("unlisted_mod_drug")) and not CInventory__eat(item("analgetic")))
assert(gate_calls == 0 and CInventory__eat(item("water")) and gate_calls == 1)

local splint = item("field_medical_splint")
assert(not CInventory__eat(splint))
callbacks.actor_on_land(6)
assert(not next(fracture_state()))
callbacks.actor_on_land(25)
callbacks.actor_on_land(25)
assert(fracture_state().left_leg and not fracture_state().right_leg)
assert(#state().wounds == 0 and actor.sprint == 1)
step(0.2)
assert(actor.speed < 0.7)
callbacks.actor_on_footstep(nil, nil, true)
assert(camera == "camera_effects\\field_medical_limp_left.anm")
callbacks.ActorMenu_on_mode_changed(1)
assert(messages[#messages]:find("Left leg"))
local status = {SetText = function(self, value) self.text = value end,
    Show = function(self, value) self.visible = value end}
local menu = {DetachChild = function(_, child) assert(child == status); status.detached = true end}
ActorMenu = {get_actor_menu = function() return menu end}
function getFS() return {exist = function(_, root, path)
    return root == "$game_config$" and path == "ui\\field_medical_fractures.xml"
end} end
function CScriptXmlInit() return {
    ParseFile = function(_, name) assert(name == "field_medical_fractures.xml") end,
    InitTextWnd = function(_, name, parent) assert(name == "summary" and parent == menu); return status end,
} end
callbacks.ActorMenu_on_mode_changed(1)
assert(status.visible and status.text:find("Left leg"))
assert(CInventory__eat(splint))
callbacks.actor_on_item_use(splint)
assert(fracture_state().left_leg.splinted and actor.sprint == 0 and not CInventory__eat(splint))
assert(status.visible and status.text:find("splinted"))
callbacks.ActorMenu_on_mode_changed(0)
assert(not status.visible)

actor.gear[7] = gear
gear.name, gear.wear = "armor", 1
near(round(100, "cartridge", nil, 9, 1, 0), 0)
assert(fracture_state().left_arm and #state().wounds == 0)
local motion = {anm_name = "anm_reload", anm_speed = 1, anm_state = 7}
callbacks.actor_on_hud_animation_play(motion, weapon)
near(motion.anm_speed, 1.2 * (1 - settings.fractures.arm_reload_penalty))
local idle = {anm_name = "anm_idle", anm_speed = 1, anm_state = 0}
callbacks.actor_on_hud_animation_play(idle, weapon)
near(idle.anm_speed, 1)
step(0.2)
assert(actor.sway > 1 and actor.speed < 1)
near(round(101, nil, nil, 11, 1, 0.45), 0.45)
assert(not fracture_state().ribs and #state().wounds == 0)

local body = {type = hit.strike, power = 0.9}
callbacks.on_before_hit_after_calcs(body, actor, 11)
near(body.power, 0.9)
assert(fracture_state().ribs and #state().wounds == 0)
conditions.power = 1
step(0.2)
near(conditions.power, 1 - settings.fractures.ribs_stamina_penalty)
conditions.power = 0.20
step(0.2)
conditions.power = 0.30
step(0.2)
near(conditions.power, 0.20 + 0.10 * (1 - settings.fractures.ribs_regen_penalty))
callbacks.actor_on_sleep(1)
assert(fracture_state().ribs and dialogs.is_actor_injured())
local cash_before = actor.cash
assert(adapter.set_doctor_fees(0, 0))
dialogs.heal_actor_injury(actor, {})
near(actor.cash, cash_before)
assert(adapter.set_doctor_fees(settings.monolith.doctor_injury_fee, settings.monolith.doctor_injury_radiation_fee))
step(0.2)
assert(not next(fracture_state()) and actor.sprint == 0 and actor.sway == 1 and actor.speed == 1)

actor.gear = {}
local projectile = {type = hit.fire_wound, power = 0.14, bullet_id = 102}
callbacks.on_before_hit_after_calcs(projectile, actor, 10)
assert(state().wounds[1].part == "right_arm" and projectile.power == 0)
local tq = item("field_medical_tourniquet")
assert(CInventory__eat(tq))
callbacks.actor_on_item_use(tq)
near(actor.health, 1 - settings.tourniquet.arm_blood_fraction)
assert(tq_state().right_arm.active and not CInventory__eat(tq))
step(0.4)
near(actor.health, 1 - settings.tourniquet.arm_blood_fraction)
local active_snapshot = snapshot()
callbacks.load_state(active_snapshot)
step(0.2)
near(tq_state().right_arm.remaining, 1.6)
local remove_flags, modifier = {ret_value = true}, 0
function key_state() return modifier end
callbacks.on_before_key_press(20, nil, false, remove_flags)
assert(remove_flags.ret_value and tq_state().right_arm.active)
modifier = 1
callbacks.on_before_key_press(20, nil, false, remove_flags)
assert(not remove_flags.ret_value and not tq_state().right_arm.active and not CInventory__eat(tq))
step(0.2)
assert(actor.health < 0.92 and actor.sway > 1)

local another = {type = hit.wound, power = 0.12}
callbacks.on_before_hit_after_calcs(another, actor, 12)
assert(CInventory__eat(tq))
callbacks.actor_on_item_use(tq)
assert(tq_state().right_leg.active)
step(2.2)
assert(not tq_state().right_leg.active and not CInventory__eat(tq))
local epi = item("stimpack")
assert(CInventory__eat(epi))
actor.health = 0.36
step(0.2)
local pre_epi = actor.health
callbacks.actor_on_item_use(epi)
near(actor.health, pre_epi)
assert(state().epinephrine_seconds > 0)
step(0.2)
assert(actor.health < pre_epi and actor.sway > 1 and actor.sprint == 1)
assert(weapon.dispersion == 1 and shade == 0)
dialogs.heal_actor_injury(actor, {})
step(0.2)
assert(not next(tq_state()) and not next(fracture_state()))
assert(actor.sprint == 0 and actor.sway == 1)
callbacks.actor_on_net_destroy()
assert(status.detached)
