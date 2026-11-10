#!/usr/bin/env python3
"""Build `core.d.luau`, the Roblox type definitions the analyzer loads.

The Luau analyzer needs *some* declaration of `CFrame`, `Vector3`, `Enum`,
`Instance`... or every annotation in this repo (`local part: BasePart`) reports
"Unknown type". The authoritative source is luau-lsp's `globalTypes.d.luau`,
generated from Roblox's API dump:

    https://github.com/JohnnyMorganz/luau-lsp/blob/main/scripts/globalTypes.d.luau
    https://api.github.com/repos/JohnnyMorganz/luau-lsp/contents/scripts/globalTypes.d.luau

That file is 880 KB and 2 400 declarations, and feeding it whole makes the wasm
analyzer give up:

    definition "globalTypes.d.luau":
    Internal error: Code is too complex to typecheck!

So this script keeps a subset and then *closes over* it: it feeds the result to
the real analyzer, reads back every "Unknown type" it reports, adds those
declarations, and repeats until the definitions load clean. That loop is what
makes the output correct instead of guessed.

Usage:
    python3 tools/luau/definitions/build_definitions.py globalTypes.d.luau
    python3 tools/luau/definitions/build_definitions.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUTPUT = HERE / "core.d.luau"
PIN = HERE / "source.sha256"

# Value types: expanded with every other value type they mention.
VALUE_ROOTS = (
    "Object Instance CFrame Vector3 Vector2 UDim2 UDim Color3 Enum EnumItem Rect "
    "Region3 TweenInfo NumberRange NumberSequence ColorSequence ColorSequenceKeypoint "
    "NumberSequenceKeypoint Ray Random DateTime PhysicalProperties OverlapParams "
    "RaycastParams Font BrickColor PathWaypoint RBXScriptSignal RBXScriptConnection "
    "RaycastResult Axes Faces Vector2int16 Vector3int16 Region3int16 Content Secret "
    "UniqueId SecurityCapabilities"
).split()

# Engine classes whose members are kept. The runtime reads members off these on
# every frame; a name-only class would turn each read into a false error.
FULL_CLASSES = (
    "Instance BasePart Part Model Humanoid HumanoidDescription Player Players "
    "Workspace DataModel GuiObject GuiButton ImageLabel TextLabel TextButton TextBox "
    "Frame ScreenGui ScrollingFrame Camera RunService UserInputService InputObject "
    "Animation AnimationTrack Animator Tool Team Tween TweenService Sound Attachment "
    "RemoteEvent RemoteFunction ReplicatedStorage Lighting CollectionService "
    "HttpService TeleportService ProximityPrompt ClickDetector Highlight UIStroke "
    "UICorner UIGradient UIListLayout UIScale SurfaceGui BillboardGui CanvasGroup Trail "
    "MeshPart SpecialMesh NumberValue IntValue BoolValue ObjectValue StringValue "
    "LinearVelocity AlignOrientation WeldConstraint NoCollisionConstraint TextChannel "
    "Accessory BoxHandleAdornment Stats PlayerGui LocalizationService "
    "TextChatService ContentProvider Debris VirtualUser VirtualInputManager "
    "UserGameSettings UserSettings PathfindingService Teams StarterGui CoreGui "
    "StarterPack StarterPlayer ContextActionService GuiService HapticService "
    "MarketplaceService PhysicsService Players ServiceProvider DataModel "
    "Weld RigidConstraint WeldConstraint Animator Humanoid"
).split()

# Engine classes declared by name + superclass only: referencing their members
# drags the whole API dump back in.
CLASS_ROOTS = (
    "BasePart Part MeshPart Model Humanoid HumanoidDescription Player Players "
    "Workspace DataModel GuiObject GuiButton ImageLabel TextLabel TextButton TextBox "
    "Frame ScreenGui ScrollingFrame Camera Highlight Tool Team Tween TweenService "
    "RunService UserInputService InputObject Animation AnimationTrack Animator "
    "Attachment Sound ProximityPrompt ClickDetector Folder RemoteEvent RemoteFunction "
    "ReplicatedStorage Lighting CollectionService HttpService TeleportService "
    "TextChatService Stats NumberValue IntValue BoolValue ObjectValue StringValue "
    "LinearVelocity AlignOrientation WeldConstraint NoCollisionConstraint SpecialMesh "
    "Mouse PlayerGui CanvasGroup Trail VirtualUser VirtualInputManager UserSettings "
    "UserGameSettings PathfindingService Debris LocalizationService TextChannel "
    "Accessory BoxHandleAdornment ContentProvider Teams StarterGui CoreGui StarterPack "
    "StarterPlayer ContextActionService GuiService HapticService MarketplaceService "
    "PhysicsService DataStoreService MemoryStoreService MessagingService "
    "SocialService BadgeService GamePassService InsertService Selection ServiceProvider "
    "ReplicatedFirst ServerStorage ServerScriptService StarterCharacterScripts "
    "Model PVInstance BaseScript Script LocalScript ModuleScript "
    "LuaSourceContainer UIGridLayout UIPadding UIAspectRatioConstraint "
    "UITextSizeConstraint UISizeConstraint UICorner UIStroke UIListLayout UIGradient "
    "UIScale SurfaceGui BillboardGui ScreenGui TextBox ImageButton Frame"
).split()

# Global value declarations: `declare CFrame: {...}`, `declare task: {...}`.
LIBRARY_GLOBALS = (
    "BrickColor CFrame Color3 ColorSequence ColorSequenceKeypoint DateTime Font "
    "Instance NumberSequence NumberSequenceKeypoint OverlapParams PhysicalProperties "
    "Random Ray RaycastParams Rect Region3 TweenInfo UDim UDim2 Vector2 Vector3 Axes "
    "Faces NumberRange PathWaypoint task Enum"
).split()

# Plain aliases the dump declares at the top.
ALIASES = ("ContentId", "ProtectedString", "BinaryString", "QDir", "QFont")

HEADER = """\
-- Roblox API type definitions for the Wurst static analyzer.
-- Generated by tools/luau/definitions/build_definitions.py from
-- luau-lsp scripts/globalTypes.d.luau (Roblox API dump, main).
-- Source sha256: {digest}
-- Do not edit by hand: rerun the generator.
--
-- The generator closes over this file: it loads the definitions with the real
-- Luau analyzer, adds whatever "Unknown type" it reports, and repeats until the
-- file loads clean. Order is load-bearing (Enum/EnumItem first, enum member types
-- next, then value types, then engine classes, then the global tables).
"""

DECL = re.compile(r"(?m)^(declare extern type|export type|type) (\w+)([^\n]*)$")
SUPER = re.compile(r"(?m)^declare extern type \w+ extends (\w+)")
GLOBAL = re.compile(r"(?m)^declare ([A-Za-z_]\w*): ([^\n]*)$")
UNKNOWN = re.compile(r"Unknown type '(\w+)'")
SPECIAL_TYPES = re.compile(r"^(declare extern type|export type|type) \w+")


def parse(source: str) -> dict[str, str]:
    """{name: declaration text}, first definition wins."""
    text = re.sub(r"(?m)^--#METADATA#.*$\n?", "", source)
    decls: dict[str, str] = {}
    for match in DECL.finditer(text):
        name, rest = match.group(2), match.group(3).strip()
        line_end = text.index("\n", match.end()) + 1
        if rest.endswith("with end") or ("=" in rest and not rest.endswith("{")):
            end = line_end
        elif rest.endswith("{"):
            close = re.compile(r"(?m)^\}[ \t]*$").search(text, match.end())
            end = _next(close, text, line_end)
        else:
            close = re.compile(r"(?m)^end[ \t]*$").search(text, match.end())
            end = _next(close, text, line_end)
        body = text[match.start() : end]
        if body.count("{") != body.count("}"):
            raise SystemExit(f"unbalanced braces in declaration of {name!r}")
        decls.setdefault(name, body)
    return decls


def parse_globals(source: str) -> dict[str, str]:
    text = re.sub(r"(?m)^--#METADATA#.*$\n?", "", source)
    globals_: dict[str, str] = {}
    for match in GLOBAL.finditer(text):
        name, rest = match.group(1), match.group(2).strip()
        line_end = text.index("\n", match.end()) + 1
        if rest.endswith("{"):
            close = re.compile(r"(?m)^\}[ \t]*$").search(text, match.end())
            end = _next(close, text, line_end)
        else:
            end = line_end
        globals_.setdefault(name, text[match.start() : end])
    return globals_


def _next(match: re.Match[str] | None, text: str, fallback: int) -> int:
    if match is None:
        return fallback
    end = match.end()
    return end + 1 if text[end : end + 1] == "\n" else end


def is_class(body: str) -> bool:
    return bool(SUPER.match(body)) and not body.startswith("export type")


def trim_members(name: str, body: str) -> str:
    head = SUPER.match(body)
    if not head or name in FULL_CLASSES:
        return body
    return f"declare extern type {name} extends {head.group(1)} with\nend\n"


def topo(names: list[str], decls: dict[str, str], placed: set[str]) -> list[str]:
    unique = list(dict.fromkeys(names))
    out: list[str] = []
    placed = set(placed)
    waiting = list(unique)
    while waiting:
        progressed = False
        for name in list(waiting):
            match = SUPER.match(decls[name])
            sup = match.group(1) if match else None
            if sup is None or sup in placed or sup not in decls:
                out.append(name)
                placed.add(name)
                waiting.remove(name)
                progressed = True
        if not progressed:
            out.extend(waiting)
            break
    return out


def render(dump: str, extra_values: list[str]) -> str:
    decls = parse(dump)
    globals_ = parse_globals(dump)
    missing = [n for n in VALUE_ROOTS + CLASS_ROOTS if n not in decls]
    if missing:
        raise SystemExit(f"dump is missing expected declarations: {missing}")

    value_roots = set(VALUE_ROOTS)
    values: list[str] = []
    enums: list[str] = []
    engines: list[str] = []
    queue = [n for n in VALUE_ROOTS + CLASS_ROOTS + list(ALIASES) + extra_values if n in decls]
    seen: set[str] = set()
    while queue:
        name = queue.pop()
        if name in seen or name not in decls:
            continue
        seen.add(name)
        body = decls[name]
        head = body[:300]
        if name.endswith("_INTERNAL") or (
            "extends EnumItem" in head and "extends Enum " not in head
        ):
            enums.append(name)
            continue
        if name in CLASS_ROOTS or (is_class(body) and name not in value_roots):
            engines.append(name)
            # Only the superclass chain: a member type would be an "unknown type".
            sup = SUPER.search(body)
            if sup and sup.group(1) not in seen:
                queue.append(sup.group(1))
            continue
        values.append(name)
        for ident in set(re.findall(r"\b([A-Z]\w+)\b", body)):
            if ident != name and ident in decls and ident not in seen:
                queue.append(ident)

    prelude = ["Enum", "EnumItem"]
    rest = [n for n in values if n not in prelude]
    enum_order = topo(enums, decls, set(prelude))
    value_order = topo(rest, decls, set(prelude) | set(enum_order))
    engine_order = topo(engines, decls, set(prelude) | set(enum_order) | set(value_order))
    ordered = prelude + enum_order + value_order + engine_order
    emit = [trim_members(name, decls[name]) for name in ordered]

    emitted = set(ordered)
    declared_enums = set(enums)
    tail: list[str] = [""]
    # Every value/class type the emitted declarations mention has to exist too.
    # `User` (from MarketplaceService), `Content` and friends live in the dump as
    # `declare extern type X with ...`; a missing one is a hard analyzer error.
    for text in emit:
        for ident in set(re.findall(r"(?<![.\w])([A-Z]\w+)(?![\w.])", text)):
            if ident in emitted or ident in declared_enums or ident not in decls:
                continue
            if ident.endswith("_INTERNAL") or not SPECIAL_TYPES.match(decls[ident]):
                continue
            body = decls[ident]
            if ident in VALUE_ROOTS:
                # Already emitted as a value type (Axes, Faces...): nothing to add,
                # and a second declaration is a redefinition.
                continue
            if is_class(body):
                # A mentioned class (`Pages extends Instance`) is declared by name
                # and superclass only: its members would drag the dump back in.
                # The superclass has to be emitted BEFORE the subclass or the
                # analyzer calls it a non-class type.
                sup = SUPER.match(body)
                chain = []
                while sup:
                    parent = sup.group(1)
                    if parent in emitted or parent not in decls:
                        break
                    chain.append(parent)
                    sup = SUPER.match(decls[parent])
                for parent in reversed(chain):
                    if parent not in emitted:
                        tail.append(trim_members(parent, decls[parent]).rstrip("\n"))
                        emitted.add(parent)
                tail.append(trim_members(ident, body).rstrip("\n"))
                emitted.add(ident)
            else:
                tail.append(body.rstrip("\n"))
                emitted.add(ident)
                # A mentioned class (`Pages extends Instance`) is declared by name
                # and superclass only: its members would drag the dump back in.
                # The superclass has to be emitted BEFORE the subclass or the
                # analyzer calls it a non-class type.
                sup = SUPER.match(body)
                chain = []
                while sup:
                    parent = sup.group(1)
                    if parent in emitted or parent not in decls:
                        break
                    chain.append(parent)
                    sup = SUPER.match(decls[parent])
                for parent in reversed(chain):
                    if parent not in emitted:
                        tail.append(trim_members(parent, decls[parent]).rstrip("\n"))
                        emitted.add(parent)
    # Every enum member type the emitted declarations mention has to exist:
    # full class members (MarketplaceService:PerformPurchase takes an EnumInfoType)
    # are the usual source of stragglers.
    mentioned = set()
    for text in emit + list(globals_.values()) + tail:
        mentioned.update(re.findall(r"\b(Enum[A-Z]\w*)\b", text))
    for ident in sorted(mentioned):
        if ident in emitted or ident in declared_enums or ident not in decls:
            continue
        tail.append(trim_members(ident, decls[ident]).rstrip("\n"))
        emitted.add(ident)
    for name in LIBRARY_GLOBALS:
        if name == "Enum":
            # The dump types `Enum` as the 656-entry ENUM_LIST; typed permissively
            # so the analyzer does not pull every enum member type back in.
            tail.append("declare Enum: { [string]: any }")
            continue
        text = globals_.get(name)
        tail.append((text or f"declare {name}: any").rstrip("\n"))
    tail.append("declare game: DataModel")
    tail.append("declare workspace: Workspace")
    tail.append("declare shared: { [string]: any }")

    digest = hashlib.sha256(dump.encode("utf-8")).hexdigest()
    return HEADER.format(digest=digest) + "\n" + "\n".join(emit + tail) + "\n"


def probe(path: Path) -> set[str]:
    """Load the definitions with the real analyzer; return the missing type names."""
    script = HERE / "probe.mjs"
    result = subprocess.run(
        ["node", str(script), str(path), str(HERE / "runtime.d.luau")],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    output = result.stdout + result.stderr
    if '"ok":true' in output:
        return set()
    return set(UNKNOWN.findall(output))


def build(dump: str) -> str:
    extra: list[str] = []
    for _ in range(40):
        out = render(dump, extra)
        OUTPUT.write_text(out, encoding="utf-8")
        missing = probe(OUTPUT)
        if not missing:
            return out
        new = sorted(missing - set(extra))
        if not new:
            raise SystemExit(f"definitions still fail to load, missing: {sorted(missing)}")
        extra.extend(new)
        print(f"  + {len(new)} type(s): {', '.join(new)}")
    raise SystemExit("definitions did not converge")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dump", nargs="?", type=Path, help="globalTypes.d.luau from luau-lsp")
    parser.add_argument("--check", action="store_true", help="verify core.d.luau is current")
    args = parser.parse_args()

    if args.check:
        if not OUTPUT.exists() or not PIN.exists():
            print("core.d.luau or source.sha256 missing", file=sys.stderr)
            return 1
        current = OUTPUT.read_text(encoding="utf-8")
        pinned = PIN.read_text(encoding="utf-8").strip()
        if pinned not in current:
            print("core.d.luau was not generated from the pinned dump", file=sys.stderr)
            return 1
        print(f"definitions OK: {len(current.splitlines())} lines, dump sha256 {pinned[:12]}…")
        return 0

    if args.dump is None:
        parser.error("pass the globalTypes.d.luau path (or --check)")
    dump = args.dump.read_text(encoding="utf-8")
    out = build(dump)
    PIN.write_text(hashlib.sha256(dump.encode("utf-8")).hexdigest() + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(out.splitlines())} lines")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
