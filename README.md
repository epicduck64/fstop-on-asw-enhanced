# F-Stop Stable Rebuild

A port of the leaked F-STOP source code to [Enhanced Source](https://github.com/sears2424/Enhanced-Source), the Alien Swarm branch of the Source engine, using Portal 2 (2009-era) content from the Steam2 Teraleak.

> **Requirements:** This repository includes engine source, project asset overrides, and build tools. It does not include Valve game assets or the Portal 2 (2009) depot. You must supply the required content yourself.

## Scope

This port focuses on the **Aperture Camera** mechanics: object capture, photo inventory, placement, scaling, and depth of field. It ports 75 files from the leak and reuses systems already present in Enhanced Source.

This is not a complete F-STOP build. Two content groups are excluded because their dependencies are unavailable:

- **Gel/blob tests:** require the missing Blobulator physics library.
- **2B1W robots:** require missing companion-bot upgrade and target-gun headers.

## Fixes and Engine Changes

The port is not a pure implementation of the source leak. It includes targeted fixes for crashes, gameplay bugs, build compatibility, and asset errors, along with engine changes required from implementing the source code.

### Crash Fixes

- **Stale photo captures:** Invalidate captures when their entities die or are removed, arm capture watches for `item_photo`, and validate placement targets before use.
- **Portal laser cleanup:** Guard invalid entity pointers and release child beams, sound patches, and proxy entities during removal. Fix similar trigger cleanup in `CPropMousetrap::OnRestore`.
- **Zombie physics:** Restore the missing null-collision-data check in `CNPC_BaseZombie::FindNearestPhysicsObject`.
- **Class compatibility:** Correct `CPortalGameRules` and `CPortal_Player` inheritance, register `CTriggerCallback`, and fix trigger collision handling.

### Gameplay and Build Fixes

- **Weapon switching:** Fix placement-tool ownership, server/client registration, auto-switch settings, deployment checks, and weapon-wheel slots.
- **Camera HUD indicators:** The camera's state indicators (viewfinder / holding-a-photo), driven by `weapon_camera`, position themselves by offsetting the HUD panel's bounds. Enhanced Source re-seats HUD panels at the screen origin while painting, so that offset is discarded and the row renders at the top of the screen. The panel is now full-screen and the row position is computed in screen space, reproducing the leak's placement.
- **Photo previews:** Use the correct studio-model renderable type.
- **Zombie spawning:** Recheck ground material when the tombstone's spawn timer fires.
- **MSVC compatibility:** Fix obsolete `<typeinfo.h>` includes, legacy warning-as-error failures, `_msize_base` exception specifications, and stale VPC project CRCs.
- **Debug assertions:** Correct assertions triggered by valid initialization states while retaining useful diagnostics.

### Console Errors

- **Zero-force damage:** `CPortal_Player::Event_Killed` stamps `m_vecTotalBulletForce` only when it is non-zero, so `AddMultiDamage` no longer warns on every player death.
- **Truncated materials:** Repair two Valve materials that were missing their closing brace (`particle/particle_ring_wave_12`, `signage/warehouse_sign_01`), which the material system reported as parse errors.
- **Missing precaches:** Add the sound precaches the ported NPCs and props emit at load, so they resolve rather than being reported missing on first use.

### Engine Additions

- **F-STOP entity ports:** Port 75 files covering the Aperture Camera, photo inventory items, placement tools, placement helpers, photo erasers, triggers, props, NPCs, and related entities from the leaked Portal 2 code.
- **Capture and stasis hooks:** Add `CBaseEntity` stasis state, capture eligibility and lifecycle hooks, capture/release outputs, physics-save support, and chain-control convars.
- **Photo placement and scaling:** Add `CPhotoPlacementQuery`, object-scale accessors on `CBaseAnimating`, and camera-specific collision groups.
- **Player inventory and UI:** Extend `CPortal_Player` with photo inventory management, selection and placement state, inventory notifications, HUD effects, and locator updates.
- **Freeze/ice support:** Enable the previously disabled `EntityFreezing` implementation and add supporting frozen-state behavior for manhacks, antlion guards, and dropships. This is EP3 code, but remains to mirror a build of F-STOP.
- **Camera controls:** Add mouse-wheel command handling and bindings for zoom and captured-object resizing. Align camera defaults with FGD settings and supply the missing weapon scripts.
- **Depth of field:** The camera's DoF is gated on float HDR — `IsDepthOfFieldEnabled` requires `HDR_TYPE_FLOAT`, and level `2` stays on integer HDR. The supplied run scripts pass `+mat_hdr_level 3`; a custom launch script needs the same flag or the effect will not appear.

### Assets and Animation

- Restore the zombie's rise-from-ground input, schedule, and activity mapping so included-model animations can be found and played.
- Repair zombie walk roots, ragdoll sequences, physics constraints, and surface properties.
- **Zombie model and IK:** `npc_zombie` uses `models/zombie/new_zombie.mdl`, whose foot IK chains carry the knee-direction vectors (`mstudioiklink_t::kneeDir`, `0.7070, -0.7070, 0`). The leak's copy of that model has them zeroed, which leaves the IK solver without a bend plane. The engine's `npc_height_adjust` IK test mode is off by default: it feeds a recursive filter into the rendered origin, which on a rig whose root bone translates makes the model climb on every ground-contact window.
- **Tombstone prop:** The substitute model is Half-Life 2's `gravestone_cross001a` with its origin rebased to the foot of the cross, so the prop stands on the ground. `SOLID_BBOX` is used because the substitute ships no collision hull of its own.
- **First-launch stall:** Ship the engine's sound caches (`maps/soundcache/_master.cache`, `modelsounds.cache`) so a fresh clone does not pay the one-off multi-minute scan of every sound in the mount. They contain relative paths only.
- Resolved missing particle materials, sound manifests, localization resources, and Android missile effects.

### Existing Engine Systems Reused

The port also relies on functionality already present in Enhanced Source, including Portal physics and rendering, depth-of-field controllers, VPhysics scaling and collision conversion, model scaling, data objects, and portal-aware tracing. These systems were reused rather than reimplemented.

Changes remain focused on compatibility, required engine integration, and verified crashes, bugs, or asset failures.

## Requirements

- Windows and PowerShell 5.1+
- Visual Studio 2019 with the v142 toolset, or Visual Studio 2022+ with v142 build tools installed
- Steam-installed copies of **Half-Life 2**, **Portal**, and **Portal 2**
- The **Portal 2 (2009) depot**, described in [Setup](#setup)
- Optional: Episode Two, Team Fortress 2, Left 4 Dead 2, and CS:GO for additional assets listed in `tools/retail_picks.txt`

The repository includes `swarm.exe` and the engine binaries. Alien Swarm and Source SDK Base 2013 do not need to be installed separately. Steam must be able to locate the required games.

**CS:GO assets:** Use the `csgo` beta branch in CS2's Steam properties, not `csgo_legacy`, if you need the optional CS:GO assets.

## Setup

1. **Clone the repository.**

2. **Add the Portal 2 (2009) content** under `game/p2-2009/`:

   ```text
   game/p2-2009/
   ├── portal2/
   ├── portal2_tempcontent/
   ├── portal/
   └── hl2/
   ```

   Use depot `852_0` (`ValveTestApp852`, depot 0), dated July 30, 2011, with manifest `90b0fe8e`. Community repacks are supported if they contain the required content. Some folders, such as `hl2/`, may be supplied by retail mounts instead.

   The repository's `game/p2-2009/` directory is intentionally empty.

3. **Prepare assets and mounts.**

   ```bat
   tools\setup.bat
   ```

   This restores project overrides to `game/portal_template/` and extracts selected retail assets into `game/retail/`.

4. **Generate Visual Studio project files.**

   ```bat
   src\creategameprojects2019.bat
   ```

   Open `src/Game_Portal_Template-2019.sln`. VPC may warn that it cannot find Visual Studio registry entries for project files on systems without older Visual Studio registrations. It can still generate the `.vcxproj` files.

5. **Build** `Client (Portal)`, `Server (Portal)`, and `ShaderLib` in Visual Studio. Outputs go to `game/portal_template/bin/`.

6. **Launch the mod** with `run_mod.bat`, or launch a map with `run_map.bat`.

> **First launch:** Initial content processing may take up to five minutes. The engine window may show "Not Responding." Check the console log for `progress N/M` and wait for processing to finish.

## Repository Layout

```text
game/portal_template/  Mod files and project overrides
game/p2-2009/          User-supplied Portal 2 (2009) content
game/retail/           Extracted retail assets (generated)
game/core/             Engine base content
game/platform/         Engine platform content
game/bin/              Engine binaries
diffs/                 Project asset overrides
src/                   Engine source
tools/                 Build and asset scripts
```

The repository supplies `game/portal_template/`, `diffs/`, `src/`, and `tools/`. You supply the required game content and engine folders; `game/retail/` is generated locally.

Mount priority, as declared in `game/portal_template/GameInfo.txt`:

```text
portal_template > core > platform > p2-2009/portal2_tempcontent >
                  p2-2009/portal2 > p2-2009/portal > p2-2009/hl2 > retail
```

Higher-priority content overrides lower-priority content. Note that `portal2_tempcontent` is mounted *before* `portal2`, so it wins where the two provide the same path.

## Tools

| Script | Purpose |
| --- | --- |
| `tools/setup.bat` | Runs asset generation and retail mount setup |
| `tools/build_mounts.bat` | Extracts selected retail content into `game/retail/` |
| `tools/generate_assets.bat` | Restores overrides from `diffs/` to `portal_template/` |
| `tools/generate_diffs.bat` | Rebuilds `diffs/` from `portal_template/` (maintainers) |
| `tools/clean_mod.bat` | Removes mod files duplicated by mounted content |

`build_mounts.bat`, `clean_mod.bat`, and `generate_diffs.bat` support `-DryRun`. `generate_assets.bat` does not.

### How `generate_diffs` decides what ships

`generate_diffs` reads the mount order from `game/portal_template/GameInfo.txt` and, for each file in `portal_template/`, compares it against the **first mount that provides that path** — the copy the engine would actually serve. A file identical to that copy is not an override and is left out. A file that differs, or that no mount provides at all, is copied into `diffs/`.

Resolving against the first mount, rather than a fixed tree, matters when two mounts ship different files under the same path: the base is then whatever the game really serves, so the override is recorded correctly.

The mod's own mount and the engine mounts (`core`, `platform`) are never used as comparison bases — the diff describes `portal_template` against the game content it is layered over.

**Each entry in `diffs/` is a complete copy of the project's version of that asset, not a binary patch.** The tool computes which files differ; the files themselves are stored whole. `generate_assets.bat` copies them back into `portal_template/`, so the repository stays usable without carrying Valve's game content. `-ApplyIgnore` writes the matching `.gitignore` block for the paths `diffs/` carries; `-GameInfo` and `-SkipMounts` override where the mount order is read from and which mounts are treated as bases.

## Hammer

Run `game/portal_template/hammer.bat` to launch Hammer with the mod configuration. It refreshes external configuration paths and repairs stale paths if the repository moves.

Copy F-STOP's `portal2.fgd` from the leak's `assets/bin/portal2.fgd` into `game/bin/`. The script patches entries for renamed or unregistered entities.

Use `hammer.bat -writeconfig` to refresh the configuration without launching Hammer.

## Contents

**Included:** Engine source, build tools, project asset overrides, maps, text definitions, configuration, and upstream legal notices.

**Not included:** Portal 2 (2009) content, extracted retail assets, or Valve game content generally. The `game/p2-2009/` directory is empty; `game/retail/` is generated locally.

## Credits and Disclaimer

- **Engine:** [Enhanced Source](https://github.com/sears2424/Enhanced-Source), by sears2424 and contributors.
- **Assets and code:** Portal Series Beta Research Discord community.

F-STOP was a cancelled Portal 2-era project by Valve. This is an unofficial fan project and is not affiliated with or endorsed by Valve.
