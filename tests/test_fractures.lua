dofile("tests/helpers.lua")
local model = addon_script("field_medical_fractures")
local settings = read_settings()
local config = settings.fractures
config.causes = {
    fall = settings.fracture_fall,
    penetrating = settings.fracture_penetrating,
    blocked = settings.fracture_blocked,
    blunt = settings.fracture_blunt,
    mutant = settings.fracture_mutant,
}

local injury = model.new(config)
assert(not injury:injure("left_leg", "fall", 5, 0))
assert(not injury:injure("left_leg", "fall", 16, 0.9))
assert(not injury:injure("head", "fall", 50, 0))
assert(injury:injure("left_leg", "fall", 25, 0.1))
local first = injury:effects()
near(first.movement, 1 - config.leg_movement_penalty)
assert(first.sprint_block and first.limp_side == "left")
assert(injury:injure("right_leg", "fall", 15, 0))
assert(injury:injure("left_arm", "blocked", 0.58, 0.1))
assert(injury:injure("right_arm", "mutant", 0.55, 0.1))
assert(injury:injure("ribs", "blunt", 0.62, 0.1))
assert(not injury:injure("left_leg", "fall", 40, 0))
assert(#injury:status() == 5)
local effective = injury:effects()
near(effective.movement, first.movement)
near(effective.reload, 1 - config.arm_reload_penalty)
near(effective.sway, 1 + config.arm_sway_penalty)
near(effective.stamina, 1 - config.ribs_stamina_penalty)
near(effective.regeneration, 1 - config.ribs_regen_penalty)

assert(injury:splint() == "left_leg")
assert(injury:effects().sprint_block)
near(injury:effects().limp, injury.fractures.right_leg.severity * config.leg_limp_power)
assert(injury:splint() == "left_arm")
assert(injury:splint() == "right_arm")
assert(injury:splint() == "right_leg")
assert(not injury:effects().sprint_block)
assert(injury:splint() == nil and injury:needs_doctor())

local data = injury:snapshot()
data.fractures.ribs.splinted = true
data.fractures.head = {severity = 1}
local restored = model.new(config, data)
assert(restored.fractures.left_leg.splinted and not restored.fractures.ribs.splinted)
assert(not restored.fractures.head)
data.fractures.left_leg.splinted = false
assert(restored.fractures.left_leg.splinted)
restored:doctor()
assert(not restored:needs_doctor())
near(restored:effects().movement, 1)
near(restored:effects().reload, 1)
near(restored:effects().sway, 1)
