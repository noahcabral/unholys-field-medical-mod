"""Build the Field Medical MO2 archive and its stock-item DLTX overlay."""
import argparse
from configparser import ConfigParser
from math import isfinite
from pathlib import Path
import re
from struct import pack
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parent
ITEM_PATCH = "gamedata/configs/mod_system_zzz_field_medical_items.ltx"
SETTINGS = "gamedata/configs/field_medical/settings.ltx"
CATALOG_HOOKS = "gamedata/configs/xrr_rewrites/field_medical_catalog.ltx"
OPTIONAL_HOOKS = {"fetch_item_icon"}
FIELDS = (
    "eat_health", "wounds_heal_perc", "boost_health_restore", "boost_bleeding_restore",
    "eat_power", "eat_satiety", "eat_radiation", "eat_alcohol", "eat_sleepiness", "eat_thirst",
    "eat_psy_health", "boost_power_restore", "boost_max_weight", "boost_radiation_restore",
    "boost_telepat_protection", "boost_chemburn_protection", "boost_radiation_protection",
    "boost_burn_immunity", "boost_shock_immunity", "boost_radiation_immunity",
    "boost_telepat_immunity", "boost_chemical_burn_immunity", "boost_explosion_immunity",
    "boost_strike_immunity", "boost_fire_wound_immunity", "boost_wound_immunity",
)


def item_patch(config, full):
    roles = ("bandages", "medkits", "epinephrine", "fracture_splints", "tourniquets") if full else (
        "bandages", "medkits",
    )
    items = []
    for role in roles:
        for name in config[role]:
            value = config.getfloat(role, name) if role == "medkits" else config.getboolean(role, name)
            if not isfinite(value) or value < 0:
                raise ValueError(f"Invalid {role} capacity for {name}.")
            if value:
                items.append((name, role))
    if not items or len({name for name, _ in items}) != len(items):
        raise SystemExit("Configure at least one item and assign each item a single role.")
    # Inherit inventory assets and animations. Only the two supplied field items
    # create sections. Mod-specific medicines listed in settings apply if present.
    blocks = ["; Generated from field_medical/settings.ltx. Effects belong to Field Medical."]
    for name, role in items:
        if not name.replace("_", "").isalnum():
            raise SystemExit(f"Unsupported game section name {name!r}.")
        if name in {"field_medical_splint", "field_medical_tourniquet"}:
            definition = (
                f'@[{name}]:bandage\r\n'
                f'inv_name = st_{name}\r\n'
                f'inv_name_short = st_{name}\r\n'
                f'description = st_{name}_desc\r\n'
                f'cost = {540 if role == "fracture_splints" else 460}\r\n'
                'kind = i_medical\r\nmax_uses = 1\r\n'
            )
        else:
            definition = f"![{name}]\r\n"
        if role == "epinephrine":
            definition += ("inv_name = st_field_medical_epinephrine\r\n"
                           "inv_name_short = st_field_medical_epinephrine\r\n"
                           "description = st_field_medical_epinephrine_desc\r\n")
        elif role == "tourniquets" and name != "field_medical_tourniquet":
            definition += "description = st_field_medical_tourniquet_desc\r\n"
        blocks.append(definition + "\r\n".join(f"{field} = 0" for field in FIELDS))
    return ("\r\n\r\n".join(blocks) + "\r\n").encode("ascii")


def limp_animation(side):
    # COMotion version 5. Gentle dip and lean followed by a neutral camera.
    frames = (0, 3, 7, 11, 15)
    channel_keys = (
        (0, 0, 0, 0, 0),
        (0, -0.006, -0.018, -0.005, 0),
        (0, 0, 0, 0, 0),
        (0, 0, 0, 0, 0),
        (0, 0.008, 0.012, -0.003, 0),
        tuple(side * value for value in (0, 0.009, 0.026, 0.012, 0)),
    )
    contents = b"field_medical_limp\x00" + pack("<IIfH", 0, frames[-1], 30.0, 5)
    for channel in channel_keys:
        contents += pack("<BBH", 1, 1, len(frames))
        for frame, value in zip(frames, channel):
            contents += pack("<ffB7H", value, frame / 30, 0, *([32768] * 7))
    return pack("<II", 0x1100, len(contents)) + contents


def enable(settings, section):
    pattern = rf"(?m)(^\[{section}\][ \t]*\r?\n[ \t]*enabled[ \t]*=[ \t]*)(?:true|false)\b"
    settings, count = re.subn(pattern, r"\g<1>true", settings)
    if count != 1:
        raise ValueError(f"{section} must start with an enabled field")
    return settings


def donor_roots(base, gamedata, mo2, profile):
    roots = [base, *gamedata]
    if mo2:
        listing = (mo2 / "profiles" / profile / "modlist.txt").read_text(encoding="utf-8-sig")
        enabled = [line[1:] for line in listing.splitlines() if line.startswith("+")]
        roots.extend(mo2 / "mods" / name / "gamedata" for name in reversed(enabled))
        roots.append(mo2 / "overwrite" / "gamedata")
    return roots


def apply_catalog_hooks(entries, roots):
    """Apply the shared source hooks locally on engines without xrRazom rewrites."""
    rules = ConfigParser(interpolation=None)
    rules.read_string(entries.pop(CATALOG_HOOKS).decode("utf-8-sig"))
    for module in rules:
        if module == rules.default_section:
            continue
        relative = Path("scripts", module + ".script")
        source = next((root / relative for root in reversed(roots) if (root / relative).is_file()), None)
        if source is None:
            if module in OPTIONAL_HOOKS:
                continue
            raise ValueError(f"Missing required donor script {relative.as_posix()}")
        content = source.read_bytes()
        for key, anchor in rules[module].items():
            if not key.startswith("from_"):
                continue
            original = anchor[1:-1].encode("ascii")
            replacement = rules[module]["to_" + key[5:]][1:-1].encode("ascii")
            if content.count(original) != 1:
                raise ValueError(f"{relative.as_posix()} has a changed or ambiguous hook {key}. "
                                 "Check that the source profile is supported and the old Field Medical is disabled.")
            content = content.replace(original, replacement, 1)
        entries["gamedata/" + relative.as_posix()] = content


def build(output, full, roots=None):
    config = ConfigParser(inline_comment_prefixes=(";",))
    config.read(ROOT / SETTINGS, encoding="utf-8")
    sources = sorted(path for path in (ROOT / "gamedata").rglob("*") if path.is_file())
    entries = {path.relative_to(ROOT).as_posix(): path.read_bytes() for path in sources}
    if ITEM_PATCH in entries:
        raise SystemExit("The medical-item overlay is generated at build time.")
    entries[ITEM_PATCH] = item_patch(config, full)
    if full:
        settings = entries[SETTINGS].decode()
        for section in ("fractures", "tourniquet", "catalog"):
            settings = enable(settings, section)
        entries[SETTINGS] = settings.encode()
        optional = ROOT / "fracture_assets"
        for path in sorted(optional.rglob("*")):
            if path.is_file():
                name = path.relative_to(optional).as_posix()
                if name in entries:
                    raise ValueError(f"Duplicate asset {name}.")
                entries[name] = path.read_bytes()
        for side, sign in (("left", -1), ("right", 1)):
            entries[f"gamedata/anims/camera_effects/field_medical_limp_{side}.anm"] = limp_animation(sign)
        if roots is not None:
            apply_catalog_hooks(entries, roots)
    entries["README.md"] = (ROOT / "README.md").read_bytes()
    with ZipFile(output, "x", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(entries.items()):
            item = ZipInfo(name)
            archive.writestr(item, data, compress_type=ZIP_DEFLATED, compresslevel=9)
    with ZipFile(output) as archive:
        if archive.testzip() or {name: archive.read(name) for name in archive.namelist()} != entries:
            raise RuntimeError("Archive verification failed.")
    print(f"{output} ({len(entries)} files)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--blood-only", action="store_true", help="Build without the expanded medical catalog.")
    parser.add_argument("--base-gamedata", type=Path, help="Use local Monolith source hooks with unpacked Anomaly data.")
    parser.add_argument("--gamedata", action="append", type=Path, default=[],
                        help="Additional loose gamedata root. Last root has highest priority before MO2.")
    parser.add_argument("--mo2", type=Path, help="MO2 instance data directory containing profiles, mods and overwrite.")
    parser.add_argument("--profile", help="MO2 profile name as displayed in Mod Organizer 2.")
    args = parser.parse_args()
    if bool(args.mo2) != bool(args.profile):
        parser.error("--mo2 and --profile must be given together.")
    if (args.gamedata or args.mo2) and not args.base_gamedata:
        parser.error("Local source hooks need --base-gamedata.")
    if args.base_gamedata and (args.blood_only or not args.base_gamedata.is_dir()):
        parser.error("--base-gamedata requires an unpacked directory and full medical catalog.")
    roots = (donor_roots(args.base_gamedata, args.gamedata, args.mo2, args.profile)
             if args.base_gamedata else None)
    build(args.output, not args.blood_only, roots)
