# IWantTranslucent Lean

Translucent context menus without separators on iOS 16, for RootHide.

This is a rebuild of **IWantTranslucent 0.9.4 by [Luki120](https://github.com/Luki120)**
([source](https://github.com/Luki120/SmallTweaks/tree/main/SpringBoard/IWantTranslucent), MPL-2.0). The menus
look the same, pixel for pixel. What changed is what the tweak costs while no menu is open. It was made
because the original, converted for a RootHide phone with RootHide Patcher, was reported to warm that
phone up.

The original source is kept unchanged in [`upstream/`](upstream) (commit `9b5e4d09`); the rebuild is
[`Tweak.m`](Tweak.m). Both stay under the Mozilla Public License 2.0 ([`LICENSE`](LICENSE)).

## What the original costs

Read off the package's binary first (both slices disassembled), then confirmed against the source, the
iOS 16.5 firmware and a simulator:

1. **A method on every collection view cell.** The tweak is loaded into every process that has UIKit, and
   there it adds `-didMoveToWindow` to `UICollectionReusableView`, the base class of every collection view
   cell. Each time a cell enters or leaves a window it asks `UIDevice` for the iOS version, turns the string
   into a number, fetches the reuse identifier and compares strings: 1.7 µs a call, against 1.7 ns for the
   call without it. The only views it is looking for are the thick bars inside context menus. (Cells are
   hidden for reuse, not taken out of the window, so this runs when cells first appear and when a screen
   comes or goes, not on every step of a scroll.)
2. **A patch library at every app start.** The package is the rootless build run through RootHide Patcher,
   so it carries a link `IWantTranslucent.dylib.roothidepatch` to `AutoPatches.dylib` (package
   `rootless-compat`). RootHide's [PatchLoader](https://github.com/roothide/PatchLoader) answers such a link
   in every process the tweak is loaded into by loading AutoPatches, a 300 KB C++ library with the Dobby
   hooking engine, which searches the tweak for `/var/jb` paths to patch. There are none. (AutoPatches
   2.0.1, as installed on the phone, does nothing more than that search for this tweak; it does not sit in
   the path of later calls.)
3. **A hooking library in every app.** It links CydiaSubstrate, so ElleKit's library is loaded wherever the
   tweak is, whether or not another tweak needs it there.
4. **Small change.** The iOS version is looked up twice more when the library loads; hooks are set up for
   iOS 14 and 15 classes that iOS 16 does not have; in Control Centre's AirPlay list the separator getter
   it replaces makes a new `UIView` on every call (on iOS 16.5 one function calls it, once for each row
   shown).

What it does **not** do: nothing in it loops, polls or keeps running. With a menu open and nothing
happening, the menu is laid out 0 times in three seconds and the main thread uses about 0.1 ms of CPU, the
same as without any tweak.

## What the rebuild does instead

| | original 0.9.4 (RootHide-patched) | this rebuild |
|---|---|---|
| code running in every collection view cell of every app | 1.7 µs per window change | none |
| iOS version lookups | two at load, one per cell event | none |
| thick bar between groups in a menu | found by hooking every reusable view | the menu's own list view is told (`willDisplaySupplementaryView`): menus only |
| hairlines in a menu | taken out of their collection view | hidden and emptied where they are |
| hooking library loaded into every app | ElleKit (CydiaSubstrate) | none: plain Objective-C runtime calls |
| RootHide's AutoPatches loaded and run at every app start | yes | no: native RootHide build, no `/var/jb` anywhere |
| AirPlay list separator | a new view per call | one hidden view per row |
| iOS 14 / 15 code | carried along | left out (iOS 16 only) |
| libraries the tweak links | 7, among them libc++ and CydiaSubstrate | 4, all part of iOS |

## Measurements

### Simulator (iOS 16.4, iPhone 14 Pro Max, `tools/sim_bench.sh`)

A small app is started with no hooks, with the original (`upstream/Tweak.m` built unchanged, its hooking
library replaced by three runtime calls) and with the rebuild; each twice, best time taken.

| | no tweak | original | rebuild |
|---|---|---|---|
| one `-didMoveToWindow` of a collection view cell | 1.7 ns | 1660 ns | 1.7 ns |
| `addSubview` + `removeFromSuperview` of a cell | 8.9 µs | 13.6 µs | 8.5 µs |
| scrolling 5940 cells past (cells change window 0 times) | 156 ms | 166 ms | 157 ms |
| AirPlay row stand-in, one layout pass | 3.1 µs | 12.0 µs | 3.5 µs |
| menu open, idle for 3 s: layout passes / main-thread CPU | 0 / 0.1 ms | 0 / 0.1 ms | 0 / 0.1 ms |
| separators that draw in a menu with 3 groups and a title | 6 | 0 | 0 |
| menu background opacity | 1.0 | 0.5 | 0.5 |
| screenshot of the open menu against the original's | 24.4 % of pixels differ | | 0.00 % differ |

The scroll row is within the noise of the machine. The original's whole cost is the 1.7 µs per window
change of the first row (two of them in an `addSubview` + `removeFromSuperview`).

### The firmware itself (iOS 16.5, 20F66, `.github/workflows/probe.yml`)

The classes and the machine code of the phone's iOS were read from its dyld shared cache: the menu's list
view is its collection view's delegate and registers `kContextMenuSectionSeparator` as a supplementary
kind; that bar's whole look is a background colour set in the list view's supplementary provider;
applying layout attributes to a reusable view sets its centre, bounds, alpha and transform but never
`hidden`; `MRURoutingTableViewCell`, `MRURoutingHeaderView` and `MRUNowPlayingContainerView` reach their
separator through the instance variable.

### On the phone (iPhone 14 Pro Max, iOS 16.5, RootHide, about 70 other tweaks)

`diag/iwtdiag.c` (run with `tools/phone.sh diag`) reads, for 30 seconds at a time, the CPU used by every
process, the libraries mapped into it, and the battery's temperature and power. 27 readings on
17 Nov 2026, with no IWantTranslucent, with the original 0.9.4 (twice) and with this rebuild (twice), a
respring before each state:

| phone left alone after a respring | all processes, share of one core | SpringBoard | system power |
|---|---|---|---|
| no IWantTranslucent | 15 to 26 % | 2.1 to 3.1 % | 1.5 to 1.9 W |
| original 0.9.4 | 8 to 15 % | 1.6 to 2.0 % | 1.1 to 1.4 W |
| this rebuild | 13 % | 2.7 % | 1.7 W |

**The original does not show up.** It was mapped into 20 to 30 processes; apart from SpringBoard and an
app in use, none of them used any CPU, and SpringBoard used no more with it than without. Whatever
was hot in a reading was a system service that does not load the tweak: `ptpd` and `mediaserverd` (78 %
of a core for a minute or two after the phone is plugged into a PC, which then reads its photos),
`healthd` (42 to 75 % for over four minutes, once), `mediaanalysisd` (58 to 84 % for two and a half
minutes), all while the battery charged at up to 9 W and stood at 37 to 41.5 °C. The `healthd` burn fell
exactly into the first stretch with the original installed and looked like its doing; with the original
installed a second time it did not come back.

So on this phone the rebuild is the same menus for less overhead, measured in the simulator, not a cure
for a warm phone: nothing was found, in the code or on the device, that makes the original heat one.

## Building

Pushing the branch builds the package on GitHub Actions (`.github/workflows/build.yml`): a compile check
on Linux, the RootHide Theos build on macOS, a gate (`tools/verify_dylib.py`: arm64 + versioned arm64e,
system libraries only, no `/var/jb`), and the simulator benchmark.

## Using it

- `tools/phone.sh install <deb>` removes Luki's package if it is installed and installs this one;
  `tools/phone.sh original <deb>` is the way back; `tools/phone.sh status` shows which is there.
- The package conflicts with `me.luki.iwanttranslucent`: only one of the two can be installed.

## Credits

IWantTranslucent is Luki120's tweak; the idea, the look and the list of views to touch are his.
