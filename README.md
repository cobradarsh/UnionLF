# IWantTranslucent Lean

Translucent context menus without separators on iOS 16, for RootHide.

This is a rebuild of **IWantTranslucent 0.9.4 by [Luki120](https://github.com/Luki120)**
([source](https://github.com/Luki120/SmallTweaks/tree/main/SpringBoard/IWantTranslucent), MPL-2.0). The menus
look the same. What changed is everything the tweak does while no menu is open, because the
original, installed on a RootHide phone through RootHide Patcher, was reported to warm the phone up.

The original source is kept unchanged in [`upstream/`](upstream) (commit `9b5e4d09`); the rebuild is
[`Tweak.m`](Tweak.m). Both stay under the Mozilla Public License 2.0 ([`LICENSE`](LICENSE)).

## What the original does all day

Read off the package's binary first (both slices disassembled), then confirmed against the source:

1. **It is loaded into every process that has UIKit**, and there it adds a `-didMoveToWindow` method to
   `UICollectionReusableView`. That is the base class of every collection view cell, so from then on every
   cell of every list, grid and keyboard in every app runs the tweak's code each time it enters or leaves
   a window: ask `UIDevice` for the iOS version, turn the string into a number, fetch the reuse
   identifier, compare strings. The only views it is looking for are the thick bars inside context menus.
2. **The RootHide conversion brings a patch loader along.** The package is the rootless build run through
   RootHide Patcher: it ships a link `IWantTranslucent.dylib.roothidepatch` to `AutoPatches.dylib`.
   RootHide's [PatchLoader](https://github.com/roothide/PatchLoader/blob/main/PatchLoader.c) reacts to such
   a link in every process the tweak is loaded into: it calls `PLRequiredJIT()` (the jailbreak's request
   to let the process change code, which marks it as debugged), loads
   [AutoPatches](https://github.com/roothide/DynamicPatches/tree/AutoPatches) with the Dobby hooking
   engine, and scans the tweak for `/var/jb` paths to patch. The tweak contains no such path, so in every
   app all of this is done for nothing.
3. It links CydiaSubstrate, so ElleKit's library is loaded into every one of those processes too.
4. In Control Centre's AirPlay list, the separator getter it replaces makes a new `UIView` on every call.
5. It takes each menu separator out of its collection view from inside `-didMoveToWindow`, which costs
   the menu an extra layout pass, and it carries hooks for iOS 14 and 15 classes that iOS 16 does not have.

## What the rebuild does instead

| | original 0.9.4 (RootHide-patched) | this rebuild |
|---|---|---|
| code running in every collection view cell of every app | yes | none |
| iOS version lookups | two at load, one per cell event | none |
| thick separator in menus | found by hooking every reusable view | the menu's own list view is told (`willDisplaySupplementaryView`), menus only |
| thin separators in menus | removed from their collection view | hidden and emptied in place |
| hooking library loaded into every app | ElleKit (CydiaSubstrate) | none: plain Objective-C runtime calls |
| RootHide patch loader work, JIT flag, AutoPatches in every app | yes | none: native RootHide build, no `/var/jb` anywhere |
| AirPlay list separator | new view per call | one hidden view per row |
| iOS 14 / 15 code | carried along | left out (iOS 16 only) |

Measurements are in the section below once CI has run; the numbers come from `tools/sim_bench.sh`
(simulator) and `diag/iwtdiag.c` (the phone).

## Building

Pushing the branch builds the package on GitHub Actions (`.github/workflows/build.yml`): a compile check
on Linux, the RootHide Theos build on macOS, a gate (`tools/verify_dylib.py`: arm64 + versioned arm64e,
system libraries only, no `/var/jb`), and the simulator benchmark. `.github/workflows/probe.yml` reads the
classes and the machine code of the iOS 16.5 firmware itself.

## Checking it

- `tools/sim_bench.sh` runs a small app three times in a simulator (no hooks, the original, the rebuild),
  times the hooks, opens a context menu, reports what is on screen and compares screenshots.
- `tools/phone.sh diag <iwtdiag>` runs `diag/iwtdiag.c` on the phone: CPU by process, into how many
  processes the tweak, RootHide's patch and a hooking library are loaded, which processes carry the JIT
  flag, battery temperature and power draw. Run it with the original installed and again with the rebuild.
- `tools/phone.sh install <deb>` removes Luki's package if it is installed and installs this one;
  `tools/phone.sh original <deb>` is the way back.

## Credits

IWantTranslucent is Luki120's tweak; the idea, the look and the list of views to touch are his.
