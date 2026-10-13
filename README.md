# F-Stop stable rebuild
## F-Stop built from Portal 2 2009 content and the F-Stop source code leak on Enhanced Source (Alien Swarm branch) with fixes

A source port of the leaked F-STOP build onto
[Enhanced Source](https://github.com/sears2424/Enhanced-Source), the unofficial
Alien Swarm branch of the Source engine.

**This repository ships the base engine, the F-STOP source and the project's own
asset overrides.** Valve assets and the Portal 2 2009 content are not provided —
you supply those yourself (see *Requirements*).

---

## Scope

The port covers the **Aperture Camera** — capture, photo inventory, placement, object scale and DOF
— on Enhanced Source's Portal-2-era base. It is not a build of F-STOP as a whole: two sets of leaked
content are excluded outright, never compiled and never sourced.

| excluded | why it cannot be built |
|---|---|
| gel / blob test content: `server/hl2/blob_particle.{cpp,h}`, `server/hl2/npc_surface.{cpp,h}` | they include the **Blobulator** physics library (`common/blobulator/physics/physparticle.h`, `physparticlecache_inl.h`, `phystiler.h`, `common/blobulator/smartarray.h`), which is in neither the leak nor the engine |
| the 2B1W robots: `server/portal2/npc_companionbot.{cpp,h}`, `npc_medicbot.{cpp,h}`, `npc_obot.{cpp,h}`, `npc_hover_turret.cpp`, `client/portal2/c_npc_hover_turret.cpp` | they include `npc_companionbot_upgrades.h` and `weapon_targetgun.h`, which exist in neither tree |

Those are the only external dependencies the port is missing. Intersecting the includes of the 75
ported files against the leak and the engine yields 7 include lines collapsing to those 3 gaps, all
of them inside the excluded sets — so nothing is stubbed or reverse-engineered to compensate; the
code is simply never compiled. The Aperture Camera itself has **zero** missing external
dependencies: every non-engine file it needs comes from the leak.

---

## Fixes

The port is not a pure source code leak implementation: it carries patches for the crashes, bugs and
asset errors that blocked the build and gameplay, and the engine-side additions the mechanic needs.

### Crashes

- **Placing a photo whose captured entity had been deleted.** Capturing an existing entity worked
  fine, but nothing invalidated the capture when that entity was destroyed: the photo kept an
  `EHANDLE` that then resolved to NULL while `Photo_Count()` stayed non-zero, and the next placement
  tick dereferenced it in `UTIL_FindPlacementHelper` (`info_placement_helper.cpp:208`,
  `captureInfo.hCapturedEnt->GetClassname()`), faulting at NULL + classname offset.
  **Solution:** invalidate the capture on the deletion event, and stop the deletion happening behind
  the capture's back. Two hooks do the invalidation — `CAI_BaseNPC::Event_Killed` (NPCs, at death,
  before the ragdoll) and `CBaseAnimating::UpdateOnRemove` (everything capturable, at removal) — both
  raising `UTIL_NotifyCapturedEntityDying` / `UTIL_NotifyCapturedEntityRemoved`, which clear the
  watch armed at capture time in `CWeaponCamera::CaptureObject`. That invalidation is the fix, and it
  is what keeps the dead handle unreachable: the dereference sites themselves are unchanged from the
  leak — `UTIL_FindPlacementHelper` (`info_placement_helper.cpp:208`) and
  `CustomDataGetScaleForStep` (`photo.cpp:428`) are byte-identical to it.
- **A pickable `item_photo` whose target was removed.** The same failure through a different entry
  point: the photo item stored its target in `m_captureInfo` but never armed the watch, so removing
  the target left a null handle while the photo count stayed non-zero — placing it crashed the same
  way. **Solution:** the item refuses a capture whose entity is already gone, arms the watch when the
  photo is taken (matching the camera path), and `CWeaponPlacement::GetPlacementPosition`
  re-validates `m_CaptureInfo.hCapturedEnt` before running the placement query.
- **Null `pCollide` in the zombie's physics-object search.** `CNPC_BaseZombie::FindNearestPhysicsObject`
  dereferenced `GetVCollide()` at `npc_BaseZombie.cpp:365` (fault address `0x00000004`), which returns
  NULL for an entity with no collision data. This was a merge regression: the leak guards it with
  `if (pCollide == NULL) continue;` and those two lines were dropped when F-STOP's scale-aware scan
  was merged in. **Solution:** restored verbatim — a full diff of the file confirmed they were the
  only lost lines.
- **`CPortalLaser`'s unguarded pointers and entity leak.** Four sites dereferenced `m_pChildBeams[]`
  and `m_pPlacementHelper` with no null check, and `UpdateOnRemove` handed the placement helper to
  `UTIL_Remove` without clearing the slot. It also freed only the helper: the 16 child beams, the
  ambient sound patch and the sound-proxy entity leaked — 17 entities per destroyed laser, which is
  what overflows `CUtlRBTree` in a long session. **Solution:** guard all four sites and null each slot
  after removal; `UpdateOnRemove` now releases the beams, the sound and the proxy, and
  `StrikeThink`'s `UTIL_SetOrigin` on the proxy is guarded because a laser think can run after
  teardown. `CPropMousetrap::OnRestore` had the same shape and now calls `DestroyTriggers()` instead
  of hand-removing two of its three entities.
- **Vtable and registration crashes in the ported classes.** `CPortalGameRules` was based on
  `CSingleplayRules` and `CPortal_Player` on `CHL2_Player`; both are wrong for this tree, and the
  mismatched vtables crashed the flame-burn path in `BecomeRagdoll` (a NULL slot). `CTriggerCallback`
  was also never registered. **Solution:** rebased `CPortalGameRules` on `CHalfLife2` and
  `CPortal_Player` on `CAI_ExpresserHost<CHL2_Player>`, registered `CTriggerCallback` with
  `LINK_ENTITY_TO_CLASS` + a datadesc, and fixed `CBaseTrigger::ShouldCollide` so the camera-only
  collision groups resolve.

### Bugs

- **The camera could get stuck in picture mode, leaving it unusable.** After a capture the camera
  switches with `SwitchToNextBestWeapon(this)`, whose only valid target is `weapon_placement` — but
  the leaked code granted that weapon only in `CWeaponCamera::OnPickedUp()`, which never runs when
  the camera is obtained any other way (a console `give`, for instance), so the switch silently
  failed and the player sat on the camera with no slot or scroll working. Two more things hid it: our
  crafted `weapon_camera.txt` / `weapon_placement.txt` had copied the portalgun's
  `"autoswitchto" "0"`, so nothing was even eligible to auto-switch to, and `CWeaponPlacement` had no
  server class (the leak's `DECLARE_SERVERCLASS` / `IMPLEMENT_SERVERCLASS_ST` were commented out), so
  the client received it as a bare `CBaseCombatWeapon` and failed
  `ReadWeaponDataFromFileForSlot`. **Solution:** grant `weapon_placement` in `Deploy()` and re-assert
  it each frame from `ItemPostFrame()`; set `autoswitchto` to 1 on both weapons, raise the placement
  tool's weight to 8, and gate its `CanDeploy()` on `Photo_Count() > 0`; enable the server class plus
  the client `STUB_WEAPON_CLASS`.
- **The camera never appeared in the weapon wheel.** `weapon_camera` occupied bucket 0 / position 0 —
  the crowbar's slot — and `weapon_placement` bucket 0 / 1, the physcannon's, so neither could be
  picked up unless the slot happened to be free. **Solution:** moved both to bucket 5 (positions 1
  and 2).
- **The captured object rendered wrong in its preview.** `ViewDrawPhoto` passed
  `RENDERABLE_MODEL_ENTITY` to `clientleafsystem.cpp:786`, which needs `RENDERABLE_MODEL_STUDIOMDL`
  for a studio model. **Solution:** pass the studio-model flag.
- **A zombie could rise out of a non-dirt surface.** `SpawnThink()` checked only that the tombstone had
  no live child; the ground was tested when that think was *armed* (`Spawn`, `SetupNextSpawn`) but
  never when it *fired*. The timer outlives a capture — stasis disables the think function and rebases
  its time entries — so one armed on dirt resumed and spawned after the tombstone had been placed on
  concrete. **Solution:** re-test the ground at the top of `SpawnThink` and bail when it fails, so it
  only spawns where the tombstone is still standing on dirt.
- **Build/engine-era breakage on the current toolset.** MSVC no longer ships `<typeinfo.h>` (which
  broke `shaderlib_cvar.cpp`, `BaseShader.cpp`, `ShaderDLL.cpp`, …) — `src/public/typeinfo.h` now
  maps it onto `<typeinfo>`; the pre-2013 code is not clean at `/W4 /WX` (C4005 emitted from MSVC's
  own `stdint.h`, C5205 for the abstract class in `public/icvar.h`) —
  `$TreatWarningsAsErrors "No (/WX-)"` in `vpc_scripts/source_*win32*.vpc`, plus
  `<TreatWarningAsError>false</TreatWarningAsError>` in the generated projects;
  `public/tier0/memoverride.cpp` lacked `_CRT_NOEXCEPT` on `_msize_base` (C2382) — added; and editing
  a `.vpc` or a generated project desyncs VPC's stored CRC, failing the pre-build with MSB3073 —
  re-running VPC regenerates the projects and the CRCs together.

### Engine additions

- **The capture/photo mechanic itself.** The Aperture Camera, `item_photo`, the placement tool,
  `trigger_photo_eraser`, `_after_image`, the placement helper, and the F-STOP props and NPCs the
  camera interacts with (the tombstone, geyser, levitator, monopole, mousetrap, air vent,
  `env_portal_laser`, `npc_android*`, `npc_chicken`) are ported from the leak's `server/portal2` and
  `client/portal2` — 75 files, with the scope and its exclusions set out above. The port leans on the
  Portal-2-era facilities ASW already provides, none of which needed a remap: the Portal
  physics/render set (`game/{server,client,shared}/portal/*`); the **depth-of-field controller**
  (`CEnvDOFController` / `DOFControlSettings_t` / `env_dof_controller` / `SetControllerState`, which
  the camera drives by spawning its own `env_dof_controller` at runtime); the vphysics scaling
  primitives (`VPhysics031`, `CreateQueryModel`, `ConvexFromVerts`, `ConvertConvexToCollide`); the
  data-object and `MODELSCALE` system; `SetModelScale` / `GetModelScale`; and the portal tracing
  helpers (`UTIL_Portal_TraceRay`, `UTIL_DidTraceTouchPortals`).
- **Hooks added into ASW's base classes**, none of which existed there: capture state
  (`CBaseEntity::SetStasis` / `IsInStasis` / `m_bIsInStasis`); the `CPhotoPlacementQuery` nested type
  and its accessor; object-scale accessors on `CBaseAnimating`; `m_bCanBeCaptured` with
  `MayBeCaptured` / `TestPreCapture` / `OnCaptured` / `OnReleased`; the `m_OnCameraCapture` /
  `m_OnCameraRelease` outputs; `ShouldSavePhysics`; the camera-only collision groups
  (`COLLISION_GROUP_CAMERA_SOLID`, `COLLISION_GROUP_PLACEMENT_SOLID`); the
  `g_bAllOnCapturedChainedToBase` / `g_bAllOnReleasedChainedToBase` chain convars; and
  `CPortal_Player`'s photo inventory and UI surface (`m_PhotoInventory`, `SetPlacingPhoto`,
  `OnPhotoAdded` / `OnPhotoRemoved`, `SetSelectedPhoto` / `GetSelectedPhoto`, `ClearPhotos`,
  `StripPhotos`, `FlashDenyIndicator`, `FlashInventory`, `Flash`, `ControlHelperAnimate`,
  `UpdateLocatorEntityIndices`).
- **The freeze/ice mechanic** (`EntityFreezing`). `Freeze` / `Thaw` in `baseanimating.cpp` sat
  entirely inside `#if defined( INFESTED_DLL )`, which nothing defines, so `m_flFrozen` could never
  leave zero and `IsFrozen()` was constant-false. The include and both functions are un-gated, with
  the supporting code in place: the manhack's `IsFrozen` / `Freeze` / `Unfreeze` overrides plus its
  five guards; the antlion guard's `m_flFrozenMax` / `m_flFrozenMoveBlock`, including the frozen
  mid-charge crash and its `ice_sphere` shatter; and the dropship's `m_flFrozenMax`. Nothing calls
  `Freeze()` yet — there is no ice weapon — so the port is inert until something does.
- **Mouse-wheel zoom and resize, and the weapon data behind them.** `OnMouseWheel` has no caller
  anywhere in this tree: the plumbing lives in the leak's `hl2_player.cpp` as the `mwheel_up` /
  `mwheel_down` commands, and ASW does not compile that file — so they were ported into
  `portal_player.cpp` and bound to `MWHEELUP` / `MWHEELDOWN` in `cfg/autoexec.cfg`. `CWeaponCamera`'s
  constructor also hard-coded `m_bCanZoom = false` / `m_bCanScaleCapturedObjects = false` against
  the FGD's defaults of 1, so a spawned camera could never zoom or resize; both now match the FGD.
  The camera's and placement tool's weapon scripts (`scripts/weapon_camera.txt`,
  `scripts/weapon_placement.txt`) were crafted here too — the leak had them commented out or
  missing — including the `autoswitchto` key dealt with under *Bugs*.
- **The zombie's rise out of the ground.** `npc_zombie.cpp` declared `InputRiseFromGround` and nothing
  else — no input-table entry, no handler — so the `RiseFromGround` the tombstone (and the android
  dispenser) sends to the NPC it drops did nothing on a zombie, which popped into place where it stood
  instead of climbing out of the floor. The animation was already in the shipped set
  (`graveyard_riseup`, in `zombie_animations.mdl` which `classic.mdl` includes) but carried **no
  activity tag** — and the rig lives in that included model, where `CStudioHdr::GetNumSeq()`
  (local sequences only) means `LookupSequence` can never find it by name. Activities are the route
  that crosses into an included model, which is how the zombie's own `ACT_IDLE`/`ACT_WALK` reach
  theirs, so the sequence was tagged `ACT_ZOMBIE_RISE_FROM_GROUND` (QC + recompile; the animation data
  came back byte-identical — only the tag was added) and the input now sets a condition that runs
  `SCHED_ZOMBIE_RISE_FROM_GROUND` → `TASK_PLAY_SEQUENCE ACTIVITY:ACT_ZOMBIE_RISE_FROM_GROUND`, the
  same shape as the android's `InputRiseFromGround` → `SCHED_ANDROID_RISE` chain.

### Assets

- **`models/zombie/classic.mdl` and its animation set — the rig F-STOP's zombie was rebuilt on.**
  Four things were wrong. Its walk SMDs had been tampered with: `a_walk1`, `a_walk2`, `a_walk3` and
  `a_Walk4` carried a shifted root height — 45.65 / 26.41 / 45.97 / 60.23 against a bind `bip_pelvis`
  of 37.65 — and because the QC's `walk` sequence blends nine SMDs across `move_yaw` with
  `a_walk1` sitting mid-blend, the root height slid between 26 and 60 as the zombie turned and the
  lift accumulated, which is the walking float. It had **no `ACT_DIERAGDOLL` sequence**, so
  `CanBecomeRagdoll()` never resolved and the zombie could never ragdoll. Its `.phy` would not bind:
  `$concave` is not a valid `$collisionjoints` option (it is excluded explicitly), so studiomdl
  silently fell back to a single hull (`Error with convex elements of Zombie_model.smd, building
  single convex!!!!`), and with no `$jointconstrain` directives it emitted 20 constraints whose axes
  are all `0..0` with friction 0 — no degrees of freedom, so the corpse moved as one rigid mass. Its
  `$ikchain` knee axis was `0 0 0` on both feet, which gives the IK solver no bend plane, so the legs
  swept in circles. **Fixed by:** moving each tampered root Z onto the family band (min → 32.30,
  verified in the compiled model's sequence bounding boxes); appending a 1-frame, skeleton-only
  `ACT_DIERAGDOLL` sequence built from the model's own reference pose — not from
  `Zombie_model.smd`, a mesh SMD in a different coordinate convention that collapses when used as an
  animation frame; rebuilding the collision set as retail's 16-solid topology via `$jointmerge` and
  `$rootbone "bip_pelvis"`, with per-bone hulls generated into `zombie_phys.smd`; mapping retail's 15
  `$jointconstrain` joints onto this rig; and matching retail's knee vectors
  (`0.707 -0.707 0` on the feet, `0.707 0.707 0` on the hands).
- **`zombieflesh` — the zombie's impact surface property.** Both QCs shipped `$surfaceprop "default"`,
  so the ragdoll landed with generic plastic sounds; and even after correcting that, `zombieflesh` is
  defined only in `scripts/surfaceproperties_hl2.txt`, whose entry in the mod's
  `scripts/surfaceproperties_manifest.txt` was commented out — so the property never resolved.
  **Fixed by** setting `zombieflesh` on both QCs and uncommenting the manifest entry.
- **Particle materials that were simply missing.** `particles/airvents.pcf` referenced
  `effects/wispy_smoke.vmt`, which did not exist — and the engine reports a missing sprite material
  as `C_OP_RenderSprites::RenderUnsorted: Attempting to use an unimplemented sprite renderer`, which
  sends you looking at the renderer instead of the asset. Two texture paths were wrong as well: five
  VMTs used `vistasmokev1_emods`, a texture only CS:GO ships (and CS:GO cannot be mounted here), and
  `smokesprites_0015.vmt` pointed at `smokesprites0925`, which no game has. **Fixed by** computing
  what the `.pcf`s reference against what is present and extracting only the absent entries,
  era-correct games first (P2 → P1 → HL2 → TF2 → L4D2 → CS:GO) — 83 of 84 filled, sprite-renderer
  spam 4404 → 0 — then re-pointing the five VMTs at `vistasmokev1` and extracting
  `particle/smokesprites0001.vtf` from L4D2 for the sixth.
- **Sound scripts missing from the manifest.** `scripts/game_sounds_manifest.txt` listed
  `npc_sounds_zombie.txt` but neither `npc_sounds_manhack.txt` nor `npc_sounds_headcrab.txt`, and the
  engine only precaches sounds named in that manifest — so every script sound on the manhack and
  headcrab failed with `PrecacheScriptSound … failed`, while the `.wav`s were present all along.
  **Fixed by** copying both scripts in from the leak's `hl2/scripts/` and adding both entries.
- **Missing registrations and locale/CVar defaults.** The engine asks for a locale file named after
  the mod folder, which did not exist — added `resource/portal_template_english.txt` as a copy of
  `portal_english.txt`. The Portal 2 particle set had to be registered in `particles_manifest.txt`
  (`airvents`, `chicken`, `clouds`, `zombie`, `geyser`, `fizzler`, `electriccharge`, `electriczap`,
  `water_leaks`, `portal2_coop_ping_effect`, `laser_relay_effects`), and `cfg/autoexec.cfg` now sets
  `hud_show_control_helper 1` — the leak defaults it to 0, which leaves the capture/place UI
  invisible.
- **The android missile's explosion effect was never in the mount set.** `Explode()` dispatches
  `hunter_projectile_explosion_1`, and the entity precaches `hunter_flechette_trail` and
  `hunter_flechette_trail_striderbuster` — the Hunter's EP2 particle systems. Retail ships them
  (`ep2_pak_dir.vpk` in the HL2 install carries `hunter_projectile.pcf`), but EP2 is not one of the
  full games here and its picks are explicit, so the file never reached `game\retail` and the missile
  burst invisibly. **Fixed by** picking `ep2:particles/hunter_projectile.pcf`; the extracted file
  carries all three systems. The two sprites it precaches (`sprites/bluelaser1`,
  `sprites/light_glow02_noz`) and their textures already come from the leak's hl2 tree. The five
  `NPC_Android.Missile*` script sounds it emits were defined in no mounted script — the leak's
  `npc_sounds_android.txt` has no `Missile` entries — so the missile was silent as well; **fixed by**
  `scripts/npc_sounds_android_missile.txt`, named in the sound manifest, which maps them onto Portal
  1's rocket sounds (`weapons/rocket/*`) and the wave behind `BaseExplosionEffect.Sound`.

---

### Asserts

Most of the asserts that fire in normal play are patched, but the goal is a **clear console**, not a muted
one — and every one of these is a deviation from the leak, so each is either a real fix or a documented
relaxation.

Two things make the picture simpler than the raw firing counts suggest:

- **`Assert` is a debug macro.** It exists only under `DBGFLAG_ASSERT` (`public/tier0/dbg.h:179`), so a
  release build emits none of this at all. What a release build *does* still print is `Warning` / `Msg` /
  `DevMsg` — and the loudest of those is gone because its cause was fixed, not silenced: the
  `Bad sequence (-1 out of 32 max) ... 'player.mdl'` flood came from `C_BaseAnimating::SetSequence`
  deriving ground speed and sequence flags from a `GetSequence()` of `-1` while the local player was still
  initialising.
- **The remaining asserts are largely `_DEBUG`-gated**, and the ones that are not are genuine conditions
  the port did not introduce — `baseentity.h:2679/2680` (collision-bounds queries where the callee requires
  world-aligned, entity-space-independent bounds) and `photo.cpp:428/433` (the camera's scale-step table,
  byte-identical to the leak). Those are deliberately left visible: with them in the log, a debug build is
  still worth reading rather than something to filter out.

Where an assert was firing on a **legal** state, it was split or gated rather than deleted, so it keeps its
signal:

| assert | what it was reporting | what it does now |
|---|---|---|
| `C_BaseAnimating::SetSequence` | `pSeqdesc` asserted on a `-1` sequence before the local player had one | the sequence-derived block is skipped when the sequence is invalid; the accessor clamped the index anyway |
| `ragdoll_shared.cpp:301/321` | a `Warning` about "solid count exceeds maximum" that also covered a **null** `pCollide` | split — a null `pCollide` (a model with no `.phy`; Chell's player model ships without one) is its own `_DEBUG`-gated assert, so a missing `.phy` no longer reads as an asset error |
| `c_baseanimating.h:785` | `AssertOnce` on the modeldata cache not being frame-locked | checked only once a hdr is held, which is when the invariant can hold |
| `usermessages.cpp:133` | `ASSERT_LOCAL_PLAYER_RESOLVABLE()` on a hook registered before the player exists | dropped — the engine's own `SPLIT_SCREEN_STUBS` configuration compiles this assert out for the same reason |

The supporting engine changes are small and local — scale invalidation in `c_baseanimating.cpp`, angle
invalidation in `c_baseentity.cpp`, linkage-group idempotency in `prop_portal.cpp`, and a zero-force
early-out in `baseentity.cpp`'s damage path. The F-STOP source itself is left as the leak wrote it, so the
tree stays something to develop on rather than a rewritten base.

---

## Requirements

| requirement | why |
|---|---|
| **Half-Life 2**, **Portal 1**, **Portal 2** installed via Steam | mounted retail content; the engine cannot read these games' v2 VPKs directly, so they are unpacked locally by the build script |
| optionally **EP2**, **TF2**, **L4D2**, **CS:GO** | a handful of individual files the mod references, listed in `tools/retail_picks.txt` |
| a copy of the **Portal 2 2009 depot** | the 2009-era content the mod was authored against; mounted directly. See below |
| Windows, PowerShell 5.1+ | the tools are PowerShell driven from `.bat` wrappers |
| nothing to install for the engine | `GameInfo.txt` declares `SteamAppId 243730`, but `swarm.exe` and the engine binaries (`game/bin/`, `game/core/`, `game/platform/`, including the `matchmaking*.dll` the engine loads) ship with the repository, as upstream ships them — so an Alien Swarm or Source SDK Base 2013 install is not required to run it. Retail game content and the 2009 depot do **not** ship |

> [!NOTE]
> Games are found automatically through Steam, wherever they are installed —
> including across multiple Steam libraries on different drives. This means
> that you **must** own the game on Steam, and have them installed.

> [!WARNING]
> **CS:GO must come from its beta branch, not CS2.** Valve still offers CS:GO through CS2, whose content
> does not include the files the picks ask for. In Steam, open **CS2**'s *Properties → Betas* and
> select the **`csgo`** branch — **not `csgo_legacy`**, which is typically the first entry in
> the list and easy to pick by mistake. The handful of CS:GO files in `tools/retail_picks.txt` may
> not resolve otherwise.

---

## Setup

1. **Clone this repository.**
2. **Place the Portal 2 2009 assets** so the game folders sit under
   `game/p2-2009/`:

   ```
   game/p2-2009/
     portal2/             (required)
     portal2_tempcontent/ (required)
     portal/              (required)
     hl2/                 (optional)
   ```

   (The folder ships empty on purpose — see *What ships* below.)

   The required build is **depot `852_0`** — `ValveTestApp852`, depot 0,
   dated **30 July 2011**, manifest **`90b0fe8e`**. Unpack it and arrange the
   game folders as above.

   **Community repacks of the depot are supported.** As long as a repack
   contains the game folders GameInfo.txt expects: `portal2`, `portal2_tempcontent`
   and `portal`, it works as-is; drop it straight into `game/p2-2009/`. No
   specific source or packaging is required. If `hl2/` is absent the mount for it
   is simply empty, so the three required folders above are enough.
3. **Nothing to fetch for the engine.** `swarm.exe` and the engine binaries (`game/bin/`,
   `game/core/`, `game/platform/`) ship with the repository, as upstream does — they are already in
   your clone. `swarm.exe` sits in `game/`, beside `game/bin/`, which is what the convenience
   scripts' `..\swarm.exe` resolves to.
4. **Run the setup script:**

   ```
   tools\setup.bat
   ```

   That restores the project's asset overrides into `game/portal_template/`
   (`generate_assets`), then unpacks the retail content you need into
   `game/retail/` (`build_mounts`).
5. **Build the engine.** The solution ships — `src\Game_Portal_Template-2019.sln`, VS2019 format,
   which modern Visual Studio opens directly — but the `.vcxproj` files it references do **not**:
   they are VPC-generated, so run `src\creategameprojects2019.bat` once first. It works from any
   directory. On a machine with only a newer Visual Studio it finishes with `ERROR: Unable to find RegKey for .vcproj or .vcxproj files
   in solutions.` and a non-zero exit: VPC is a VS2013-era tool and needs that registration to write a
   solution. It still writes every `.vcxproj`; the solution itself is the shipped one, so nothing is
   missing. Then build **Client (Portal)**, **Server (Portal)** and **ShaderLib** with Visual Studio
   2019 (v142; VS2022+ works if the v142 build tools component is installed). Each
   project publishes its output
   into `game/portal_template/bin/`, beside the mod's GameInfo.txt, which is where the engine loads
   it from.
6. **Run the game.** The mod is `game/portal_template`; the convenience scripts
   `run_mod.bat` / `run_map.bat` start it with the right options.

> [!NOTE]
> **A long loading screen is not a hang, and can take up to five minutes to pass.** The first launch
> after the mount set changes — a fresh `setup`, or anything that alters what
> `game/portal_template/GameInfo.txt` mounts — works through the mounts before it gets to the game,
> reporting `progress N/M` to the console log while the window shows as *not responding*. That is
> normal; let it finish.

---

## Layout

```
game/portal_template/   the mod. Mounted first, so it always wins.
game/p2-2009/           Portal 2 2009 assets, mounted directly
game/retail/            retail content unpacked from your Steam installs
game/core, platform/    engine base content
game/bin/               engine binaries
diffs/                  the project's asset overrides
src/                    engine source
tools/                  the build pipeline
```

Only `game/portal_template/`, `diffs/`, `src/` and `tools/` come from the repository. You supply
`game/p2-2009/` (see *Setup*) and `game/core/`, `game/platform/` plus `game/bin/` from your own
install, and `game/retail/` is generated by `build_mounts`.

Mount order (`game/portal_template/GameInfo.txt`):

```
portal_template  >  core  >  platform  >  p2-2009/*  >  retail
```

Because `portal_template` is first, anything in it overrides everything below —
which is why it is the only place the project's changes live.

---

## Tools

| script | purpose |
|---|---|
| `tools/setup.bat` | full build: `generate_assets` then `build_mounts` |
| `tools/build_mounts.bat` | unpacks the retail content you need into `game/retail` |
| `tools/generate_assets.bat` | restores the overrides from `diffs/` into `portal_template` |
| `tools/generate_diffs.bat` | refreshes `diffs/` from `portal_template` (for the maintainer) |
| `tools/clean_mod.bat` | drops files from `portal_template` that duplicate a mounted copy |

`build_mounts`, `clean_mod` and `generate_diffs` take `-DryRun` to report without
writing; `generate_assets` does not, so `setup.bat` cannot be dry-run as a whole.

How the asset side fits together: `portal_template` mounts first, so it only needs
to carry what differs from the mounts below it. Those differences are what `diffs/`
holds — `generate_diffs` writes them, `generate_assets` replays them — while
anything a mounted game already provides is left out of git and supplied locally by
`build_mounts`. That is what keeps the repository free of Valve content.

**Hammer.** `game/portal_template/hammer.bat` launches Hammer against this mod, and it also repairs the
three paths Hammer keeps outside git — all of which go stale if the tree moves:

- `..\bin\GameConfig.txt` is written from the script's own location (game dir, FGD, VBSP/VVIS/VRAD,
  map dirs, GameExe), keeping the old file as `GameConfig.txt.bak`;
- F-STOP's own `..\bin\portal2.fgd` — copy it from the leak's `assets\bin\portal2.fgd`; it is what
  declares the Aperture entities. `tools\fix_hammer.ps1` patches the entries that name assets which
  were never shipped or classes nothing registers: `prop_tombstone`'s model, the
  `prop_linked_portal_door` → `prop_portal_linked_door` rename, a missing `npc_android_missile`, and
  the tunnel's help text;
- the autosave folder, which Hammer keeps in the registry (`HKCU\Software\Valve\Hammer\General`), is
  repointed at `..\bin\HammerAutosave\` whenever the folder it names is gone.

`hammer.bat -writeconfig` refreshes all of that without launching Hammer.

---

## What ships, and what does not

* **Shipped:** `src/`, `tools/`, `diffs/` (the project's asset overrides — the ~6 MB of binary
  assets `portal_template` carries, copied verbatim), maps and text definitions, configuration, and
  upstream's `LICENSE` and `thirdpartylegalnotices.txt`. `diffs/` carries assets only: `*.dll`,
  `*.exe`, `*.pdb` and everything under a `bin/` folder are excluded, because building `src/`
  reproduces them.
* **Text-based overrides ship through git, not `diffs/`.** Maps and text definitions — `*.txt`,
  `*.vmt`, `*.res`, `*.vmf`, `*.ain`, `cfg/`, `maps/` — only describe where assets are and what their
  properties are, so they are tracked as source rather than carried as assets. `generate_diffs.ps1`'s
  `-KeepTracked` list draws that line, and `scripts/game_sounds_player.txt` is the live example: it is
  the leak's HL2 player-sound block, shipped so it mounts above the leak's Portal 2 copy, whose own
  `game_sounds_player.txt` carries only two of the ten `HL2Player.*` entries. Console output
  (`console*`, including the `console.log.prev` a rotated run leaves) is excluded from both sides.
* **Not shipped:** `game/p2-2009/` and `game/retail/` are gitignored. The
  `p2-2009` folder ships present but empty, so each build supplies its own copy
  of depot `852_0`. `game/portal_template/`'s binary assets are also gitignored —
  they are carried by `diffs/` and restored by `generate_assets`.

A full push is roughly 264 MB, dominated by the engine source.

---

## Credits

Engine: [Enhanced Source](https://github.com/sears2424/Enhanced-Source) by sears2424 and contributors.
Assets and code: Portal Series Beta Research Discord Community
F-STOP is Valve's cancelled Portal 2-era project. This repository is an unofficial fan project.
