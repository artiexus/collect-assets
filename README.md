# Collect Assets

A script for 3ds Max 2026 (it uses nothing newer than Max 2022). It copies the files a scene uses into one
folder, repoints them in Asset Tracking, and turns every path into a UNC path.

## Running it

Scripting > Run Script... > `CollectAssets.ms`, or drag the file into a viewport.

Running it once also adds the action **Collect Assets** in the category **Asset Tools** (Customize > Customize
User Interface), so it can go on a toolbar, a menu or a hotkey. The action points at the file where it was
when you ran it: run the file again if you move this folder.

## The dialog

| | |
|---|---|
| **Collect into** | The folder everything is copied to. "Sort into subfolders" puts files in `maps`, `proxies`, `xrefs` and `other` inside it. |
| **Images** | Textures and HDRI of every map type that shows up in Asset Tracking (Bitmap, VRayBitmap, CoronaBitmap, OSL, ...), including every tile of a `<UDIM>` texture and the frames of an `.ifl`. On by default. |
| **Proxies** | `.vrmesh`, `.abc`, `.vrscene`, `.cgeo`, `.cproxy`, `.rs`, `.ass`, `.usd`. On by default. |
| **XRefs** | XRef scenes and XRef objects (`.max`). Off every time the dialog opens. |
| **Other** | Everything else in Asset Tracking: IES, caches, volumes, ... Off by default. |
| **Overwrite...** | What to do when the folder already holds a *different* file with the same name. Off: both are kept, the second one in `_dup2` (then `_dup3`, ...), and each map points at its own file. On: the file in the folder is replaced. |
| **Make all paths UNC** | After collecting, every path in Asset Tracking that is not UNC yet is converted, also for the kinds you did not collect. A mapped drive becomes its server path, a shared folder on this PC becomes `\\PC\Share\...`. |
| **Local drive that is not shared** | With this on, a plain local drive becomes the hidden share `\\PC\D$\...`. Other computers can open that only with an administrator account on this PC; turn it off and such paths stay as they are (the log lists the drive). |
| **Missing files** | Folders to look in for files Max cannot find, by file name. "Find Missing" searches now and repoints what it finds. "Look for missing files before collecting" does the same as the first step of Collect and Relink. |
| **Scan Scene** | Only counts: how many files of each kind, how many missing, how many not UNC. Changes nothing. |
| **Paths to UNC Only** | Converts the paths, copies nothing. |
| **Collect and Relink** | Find missing (if asked), copy, repoint, UNC. |

Esc stops a long search or copy; what was done so far stays.

The log is also written to `collect_assets_log.txt` in the folder, and to the MAXScript Listener.

## Good to know

- **Nothing is saved.** The scene's paths change in memory; look at Asset Tracking (Shift+T), then save. To
  go back, reopen the file without saving.
- Files are copied, never moved or deleted. A file that is already in the folder and identical (compared by
  content) is not copied again.
- **XRef scenes keep their own paths.** A texture used inside an XRef'd `.max` belongs to that file: the log
  marks it "INSIDE AN XREF". Open the XRef file and run the script there.
- Lines in capitals in the log are the ones to read: `MISSING`, `STILL MISSING`, `COPY FAILED`,
  `COULD NOT REPOINT`, `NO UNC`.
- Settings and the list of search folders are remembered in `plugcfg\CollectAssets.ini`.

## From MAXScript

```maxscript
CollectAssets_noUI = true          -- load the functions without the dialog
fileIn @"C:\scripts\CollectAssets.ms"
CollectAssets.findMissing #(@"\\server\library") recursive:true
CollectAssets.collectTo @"\\server\project\assets" #(#image, #proxy) subfolders:false overwrite:false unc:true
CollectAssets.makeUNC()
```

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).

Autodesk and 3ds Max are registered trademarks of Autodesk, Inc. V-Ray and Corona are trademarks of Chaos
Software. This project is not affiliated with or endorsed by either company.
