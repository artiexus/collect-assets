/*
Collect Assets 1.0  -  3ds Max 2026 (any Max from 2022 up)

Copies the scene's images (textures, HDRI), proxies and, if asked, XRefs into one folder, repoints every
one of them in Asset Tracking, and turns all paths into UNC paths. Can first look for missing files in
folders you list.

Run it: Scripting > Run Script..., or drag this file into a viewport. Running it once also registers
the action "Collect Assets" in the category "Asset Tools" (Customize User Interface), for a toolbar or menu.

Nothing is saved for you: check the result in Asset Tracking (Shift+T), then save the scene.

GPL-3.0-or-later.
*/

global CollectAssets
global CollectAssetsDlg
global CollectAssets_noUI   -- set to true before fileIn to load the functions without the dialog

struct CollectAssetsItem (ats, resolved, kind, exists, isPattern)

struct CollectAssetsStruct
(
    imageExt = #(".jpg", ".jpeg", ".jpe", ".png", ".tif", ".tiff", ".tga", ".vda", ".icb", ".vst", ".bmp", ".exr",
                 ".fxr", ".hdr", ".hdri", ".pic", ".psd", ".dds", ".gif", ".tx", ".tex", ".rgb", ".rgba", ".sgi",
                 ".rla", ".rpf", ".cin", ".dpx", ".vrimg", ".cxr", ".webp", ".ifl", ".avi", ".mov", ".mp4",
                 ".mpg", ".mpeg", ".wmv"),
    proxyExt = #(".vrmesh", ".abc", ".vrscene", ".cgeo", ".cproxy", ".rs", ".ass", ".usd", ".usda", ".usdc", ".usdz"),
    xrefExt = #(".max"),

    logFn = undefined,        -- fn <string>: where messages go (the dialog sets it)
    progressFn = undefined,   -- fn <0..100>
    cancelled = false,
    useAdminShare = true,     -- a local drive with no share becomes \\PC\D$
    logLines = #(),
    nCopied = 0, nSame = 0, nFailed = 0, nDup = 0,
    shares = undefined,       -- #(#(name, lowercase path), ...) of this PC's own shares
    adminOK = #(),            -- drive letters whose \\PC\X$ answers, and those that don't
    adminBad = #(),

    ------------------------------------------------------------------ messages
    fn say msg =
    (
        append logLines msg
        if logFn != undefined then logFn msg else format "%\n" msg
    ),
    fn progress pct = (if progressFn != undefined do progressFn pct),
    fn checkCancel =
    (
        if keyboard.escPressed do cancelled = true
        cancelled
    ),

    ------------------------------------------------------------------ paths
    fn fixSlashes p = (substituteString (p as string) "/" "\\"),
    fn trimSlash p =
    (
        p = fixSlashes p
        while p.count > 3 and p[p.count] == "\\" do p = substring p 1 (p.count - 1)
        p
    ),
    fn isUNC p = (p.count > 2 and (substring p 1 2) == "\\\\"),
    fn isAbsolute p = (isUNC p or (p.count > 2 and p[2] == ":")),
    fn dirOf p = (trimSlash (getFilenamePath (fixSlashes p))),
    fn samePath a b = ((toLower (trimSlash a)) == (toLower (trimSlash b))),

    -- this PC's shares, from the registry (the hidden X$ shares are not listed there)
    fn readShares =
    (
        shares = #()
        try
        (
            local key
            if registry.openKey HKEY_LOCAL_MACHINE "SYSTEM\\CurrentControlSet\\Services\\LanmanServer\\Shares" accessRights:#readOnly key:&key do
            (
                local names = #()
                registry.getValueNames key &names
                for n in names do
                (
                    local t, v
                    if registry.queryValue key n type:&t value:&v do
                    (
                        local parts = if classOf v == Array then v else (filterString (v as string) "\n\r")
                        for s in parts where matchPattern s pattern:"Path=*" do
                        (
                            local sp = trimSlash (substring s 6 -1)
                            if sp.count > 1 do append shares #(n, toLower sp)
                        )
                    )
                )
                registry.closeKey key
            )
        )
        catch ()
        shares
    ),

    fn adminShareWorks letter =
    (
        letter = toUpper letter
        if findItem adminOK letter > 0 then true
        else if findItem adminBad letter > 0 then false
        else
        (
            local ok = doesDirectoryExist ("\\\\" + sysInfo.computername + "\\" + letter + "$\\")
            append (if ok then adminOK else adminBad) letter
            ok
        )
    ),

    -- the UNC form of a folder or file path; the path itself when there is none
    fn toUNC p =
    (
        p = fixSlashes p
        if isUNC p or p.count < 2 or p[2] != ":" then p
        else
        (
            local u = p
            try (u = fixSlashes (pathConfig.convertPathToUnc p)) catch ()   -- mapped network drive
            if isUNC u then u
            else
            (
                if shares == undefined do readShares()
                local best = undefined, lp = toLower p
                for s in shares do
                (
                    local sp = s[2]
                    local hit = (lp == sp) or (sp.count == 3 and matchPattern lp pattern:(sp + "*")) or (matchPattern lp pattern:(sp + "\\*"))
                    if hit and (best == undefined or sp.count > best[2].count) do best = s
                )
                if best != undefined then
                (
                    local rest = substring p (best[2].count + 1) -1
                    if rest.count > 0 and rest[1] != "\\" do rest = "\\" + rest
                    "\\\\" + sysInfo.computername + "\\" + best[1] + rest
                )
                else if useAdminShare and adminShareWorks p[1] then
                    "\\\\" + sysInfo.computername + "\\" + (toUpper p[1]) + "$" + (substring p 3 -1)
                else p
            )
        )
    ),

    ------------------------------------------------------------------ what the scene uses
    fn kindOf f =
    (
        local e = toLower (getFilenameType f)
        if findItem imageExt e > 0 then #image
        else if findItem proxyExt e > 0 then #proxy
        else if findItem xrefExt e > 0 then #xref
        else #other
    ),
    fn kindLabel k = (if k == #image then "images" else if k == #proxy then "proxies" else if k == #xref then "xrefs" else "other"),
    fn kindFolder k = (if k == #image then "maps" else if k == #proxy then "proxies" else if k == #xref then "xrefs" else "other"),

    -- "tile.<UDIM>.exr" -> "tile.*.exr"; undefined for an ordinary file name
    fn tilePattern f =
    (
        local name = filenameFromPath f
        local a = findString name "<", b = findString name ">"
        if a != undefined and b != undefined and b > a then
            (getFilenamePath f) + (substring name 1 (a - 1)) + "*" + (substring name (b + 1) -1)
        else undefined
    ),

    -- every input file in Asset Tracking, except the scene itself
    fn gather =
    (
        local files = #(), res = #(), out = #()
        ATSOps.Refresh()
        ATSOps.GetFiles &files
        if files.count > 0 do ATSOps.GetResolvedPaths files &res
        local sceneFile = toLower (maxFilePath + maxFileName)
        local seen = #()
        for i = 1 to files.count do
        (
            local f = files[i] as string
            local lf = toLower f
            if f != "" and lf != sceneFile and findItem seen lf == 0 and (ATSOps.IsInputFile f) do
            (
                append seen lf
                local r = if res[i] != undefined and (res[i] as string) != "" then fixSlashes (res[i] as string) else fixSlashes f
                if toLower r != sceneFile do
                (
                    local pat = tilePattern r
                    local ok = if pat != undefined then (getFiles pat).count > 0 else doesFileExist r
                    append out (CollectAssetsItem ats:f resolved:r kind:(kindOf f) exists:ok isPattern:(pat != undefined))
                )
            )
        )
        out
    ),

    -- the files on disk behind one asset: every tile of a tiled name, every frame of an .ifl
    fn filesOf a =
    (
        local out = #()
        if a.isPattern then out = getFiles (tilePattern a.resolved)
        else
        (
            append out a.resolved
            if (toLower (getFilenameType a.resolved)) == ".ifl" do
            (
                try
                (
                    local dir = getFilenamePath a.resolved
                    local fs = openFile a.resolved mode:"r"
                    while not eof fs do
                    (
                        local ln = trimRight (trimLeft (readLine fs))
                        if ln != "" and ln[1] != ";" do
                        (
                            -- "frame.jpg" or "frame.jpg 3" (repeat count)
                            local sp = ln.count
                            while sp > 1 and ln[sp] != " " do sp -= 1
                            if sp > 1 and (substring ln (sp + 1) -1) as integer != undefined do ln = trimRight (substring ln 1 (sp - 1))
                            local ff = if isAbsolute (fixSlashes ln) then ln else dir + ln
                            if doesFileExist ff do appendIfUnique out ff
                        )
                    )
                    close fs
                )
                catch ()
            )
        )
        out
    ),

    ------------------------------------------------------------------ copying
    fn md5 f =
    (
        local h = undefined
        try
        (
            local m = (dotNetClass "System.Security.Cryptography.MD5").Create()
            local s = (dotNetClass "System.IO.File").OpenRead f
            h = (dotNetClass "System.BitConverter").ToString (m.ComputeHash s)
            s.Close()
        )
        catch ()
        h
    ),
    fn sameFile a b =
    (
        -- same size is not enough (uncompressed images of one resolution all match), so the contents decide
        if (getFileSize a) != (getFileSize b) then false
        else
        (
            local ha = md5 a
            ha != undefined and ha == md5 b
        )
    ),
    fn copyOver src dst =
    (
        local ok = false
        try ((dotNetClass "System.IO.File").Copy src dst true; ok = true) catch ()
        if not ok do
        (
            if doesFileExist dst do deleteFile dst
            ok = copyFile src dst
        )
        ok
    ),

    -- puts one file in dir (or, when another file of that name is there, in dir\_dup2, _dup3 ...);
    -- returns the folder it ended up in, undefined when the copy failed
    fn placeFile src dir overwrite =
    (
        local name = filenameFromPath src
        local result = undefined, n = 1, d = dir, done = false
        while not done do
        (
            local dst = d + "\\" + name
            if samePath src dst or samePath (toUNC src) (toUNC dst) then (result = d; nSame += 1; done = true)
            else if not doesFileExist dst then
            (
                makeDir d all:true
                if copyOver src dst then (result = d; nCopied += 1) else (nFailed += 1; say ("  COPY FAILED  " + src))
                done = true
            )
            else if sameFile src dst then (result = d; nSame += 1; done = true)
            else if overwrite then
            (
                if copyOver src dst then (result = d; nCopied += 1) else (nFailed += 1; say ("  COPY FAILED  " + src))
                done = true
            )
            else
            (
                n += 1
                d = dir + "\\_dup" + (n as string)
                if n == 2 do nDup += 1
                if n > 50 do (nFailed += 1; say ("  TOO MANY FILES NAMED  " + name); done = true)
            )
        )
        result
    ),

    ------------------------------------------------------------------ relinking
    -- Tiled textures ("name.<UDIM>.exr"): Asset Tracking lists the tiles, the map holds the tagged name, and
    -- Asset Tracking cannot repoint it. So the map's own file name is set. Returns true when a map was changed.
    tagProps = #(#("VRayBitmap", "HDRIMapName"), #("CoronaBitmap", "filename"), #("ai_image", "filename"),
                 #("rsTexture", "tex0_filename"), #("RS_Texture", "tex0_filename"), #("BitmapTexture", "filename")),
    fn relinkTagged tileFile newDir =
    (
        local hit = false, lf = toLower (fixSlashes tileFile)
        for tp in tagProps do
        (
            local cls = undefined
            try (cls = execute tp[1]) catch ()
            if cls != undefined do
            (
                for o in (try (getClassInstances cls) catch (#())) do
                (
                    local v = undefined
                    try (v = getProperty o tp[2]) catch ()
                    if v != undefined and classOf v == String do
                    (
                        local pat = tilePattern (fixSlashes v)
                        if pat != undefined do
                        (
                            if matchPattern lf pattern:(toLower pat) then
                                try (setProperty o tp[2] (newDir + "\\" + filenameFromPath (fixSlashes v)); hit = true) catch ()
                            -- an earlier tile of the same map already moved it
                            else if samePath (dirOf v) newDir and matchPattern (filenameFromPath lf) pattern:(toLower (filenameFromPath pat)) do hit = true
                        )
                    )
                )
            )
        )
        hit
    ),

    -- the files that belong to XRef scenes, not to this one: they can only be repointed inside the XRef file
    fn nestedFiles =
    (
        local out = #(), files = #()
        ATSOps.GetFiles &files
        for f in files where (toLower (getFilenameType (f as string))) == ".max" and (toLower (f as string)) != (toLower (maxFilePath + maxFileName)) do
        (
            local deps = #()
            try (ATSOps.GetDependentFiles f true &deps) catch ()
            for d in deps do appendIfUnique out (toLower (d as string))
        )
        out
    ),

    -- groups: Dictionary  folder -> #(asset tracking names);  returns how many entries were repointed
    fn relink groups =
    (
        local count = 0
        local wasSilent = ATSOps.Silent
        ATSOps.Silent = true
        for dir in groups.keys do
        (
            local names = groups[dir]
            ATSOps.ClearSelection()
            ATSOps.SelectFiles names useResolvedFileNames:false
            if ATSOps.NumFilesSelected() < names.count do
            (
                ATSOps.ClearSelection()
                ATSOps.SelectFiles names
            )
            if ATSOps.NumFilesSelected() > 0 do
            (
                ATSOps.SetPathOnSelection dir
                count += names.count
            )
        )
        ATSOps.ClearSelection()
        ATSOps.Silent = wasSilent
        ATSOps.Refresh()
        -- what is still listed under its old name was not repointed
        local now = #(), nested = undefined
        ATSOps.GetFiles &now
        now = for f in now collect toLower (f as string)
        for dir in groups.keys do
            for n in groups[dir] where not samePath (dirOf n) dir and findItem now (toLower n) > 0 do
            (
                if not (relinkTagged n dir) do
                (
                    count -= 1
                    if nested == undefined do nested = nestedFiles()
                    if findItem nested (toLower n) > 0 then say ("  INSIDE AN XREF (run this in the XRef's own file)  " + n)
                    else say ("  COULD NOT REPOINT  " + n)
                )
            )
        ATSOps.Refresh()
        count
    ),
    fn addToGroup groups dir name =
    (
        if HasDictValue groups dir then append groups[dir] name else groups[dir] = #(name)
    ),

    ------------------------------------------------------------------ the four jobs
    fn scan =
    (
        local assets = gather()
        say ("Scene uses " + assets.count as string + " files:")
        for k in #(#image, #proxy, #xref, #other) do
        (
            local all = for a in assets where a.kind == k collect a
            local gone = for a in all where not a.exists collect a
            local local_ = for a in all where not isUNC a.ats collect a
            say ("  " + kindLabel k + ": " + all.count as string + ", missing " + gone.count as string + ", not UNC " + local_.count as string)
        )
        for a in assets where not a.exists do say ("  MISSING  " + a.ats)
        assets
    ),

    fn walk dir recursive want patterns found =
    (
        if not (checkCancel()) do
        (
            for f in getFiles (dir + "\\*") do
            (
                local n = toLower (filenameFromPath f)
                if HasDictValue want n and not HasDictValue found n do found[n] = dir
                for p in patterns where not HasDictValue found p do
                    if matchPattern n pattern:p do found[p] = dir
            )
            if recursive and found.count < want.count + patterns.count do
                for d in getDirectories (dir + "\\*") do walk (trimSlash d) recursive want patterns found
        )
    ),

    -- looks for the scene's missing files in the given folders and repoints the ones it finds
    fn findMissing folders recursive:true =
    (
        cancelled = false
        local assets = for a in gather() where not a.exists collect a
        if assets.count == 0 then (say "No missing files."; 0)
        else
        (
            say ("Looking for " + assets.count as string + " missing files...")
            local want = Dictionary #string, patterns = #(), found = Dictionary #string
            for a in assets do
            (
                local n = toLower (filenameFromPath (fixSlashes a.resolved))
                if a.isPattern then appendIfUnique patterns (toLower (filenameFromPath (tilePattern a.resolved)))
                else want[n] = true
            )
            for d in folders do
            (
                d = trimSlash d
                if doesDirectoryExist d then walk d recursive want patterns found
                else say ("  NO SUCH FOLDER  " + d)
            )
            local groups = Dictionary #string, hits = 0
            for a in assets do
            (
                local n = toLower (filenameFromPath (fixSlashes a.resolved))
                if a.isPattern do n = toLower (filenameFromPath (tilePattern a.resolved))
                if HasDictValue found n then
                (
                    addToGroup groups found[n] a.ats
                    hits += 1
                    say ("  found  " + filenameFromPath (fixSlashes a.ats) + "  in  " + found[n])
                )
                else say ("  STILL MISSING  " + a.ats)
            )
            relink groups
            say ("Found " + hits as string + " of " + assets.count as string + " missing files." + (if cancelled then "  (cancelled)" else ""))
            hits
        )
    ),

    -- repoints everything that has no UNC path yet to the UNC form of where it is now
    fn makeUNC =
    (
        local groups = Dictionary #string, noUNC = #(), n = 0
        for a in gather() where not isUNC (fixSlashes a.ats) do
        (
            local r = a.resolved
            if not isAbsolute r then say ("  NO UNC (file not found, relative path)  " + a.ats)
            else
            (
                local u = toUNC (dirOf r)
                if isUNC u then (addToGroup groups u a.ats; n += 1)
                else appendIfUnique noUNC (toUpper (substring r 1 2))
            )
        )
        relink groups
        for d in noUNC do say ("  NO UNC for drive " + d + "  (a local drive that is not shared)")
        local left = (for a in gather() where not isUNC (fixSlashes a.ats) collect a).count
        say ("UNC: " + n as string + " paths converted, " + left as string + " left without a UNC path.")
        left
    ),

    -- copies the chosen kinds into dest and repoints them there
    -- kinds: any of #image #proxy #xref #other
    fn collectTo dest kinds subfolders:false overwrite:false unc:true =
    (
        cancelled = false
        nCopied = 0; nSame = 0; nFailed = 0; nDup = 0
        dest = trimSlash dest
        makeDir dest all:true
        if not doesDirectoryExist dest then (say ("Cannot make the folder " + dest); false)
        else
        (
            local assets = for a in gather() where findItem kinds a.kind > 0 collect a
            local groups = Dictionary #string, gone = 0
            say ("Collecting " + assets.count as string + " files into " + dest)
            for i = 1 to assets.count while not (checkCancel()) do
            (
                local a = assets[i]
                progress (100.0 * i / assets.count)
                if not a.exists then (gone += 1; say ("  MISSING  " + a.ats))
                else
                (
                    local dir = if subfolders then dest + "\\" + kindFolder a.kind else dest
                    local final = undefined
                    if a.isPattern then
                    (
                        -- tiles stay together: all in one folder, an existing different tile is kept unless overwriting
                        final = dir
                        for f in filesOf a do
                        (
                            local dst = dir + "\\" + filenameFromPath f
                            if samePath f dst then nSame += 1
                            else if doesFileExist dst and not overwrite then
                            (
                                if sameFile f dst then nSame += 1 else say ("  KEPT THE EXISTING  " + dst)
                            )
                            else
                            (
                                makeDir dir all:true
                                if copyOver f dst then nCopied += 1 else (nFailed += 1; final = undefined; say ("  COPY FAILED  " + f))
                            )
                        )
                    )
                    else
                    (
                        local all = filesOf a
                        final = placeFile all[1] dir overwrite
                        if final != undefined do for j = 2 to all.count do placeFile all[j] final true   -- .ifl frames
                    )
                    if final != undefined do
                    (
                        local target = if unc then toUNC final else final
                        if not samePath (dirOf a.ats) target do addToGroup groups target a.ats
                    )
                )
            )
            local n = relink groups
            progress 100
            say ("Copied " + nCopied as string + ", already there " + nSame as string + ", failed " + nFailed as string + ", missing " + gone as string + ", repointed " + n as string + ".")
            if nDup > 0 do say (nDup as string + " files share a name with a different file: they are in _dup folders.")
            if unc and not isUNC (toUNC dest) do say ("  NO UNC for " + dest + "  (a local drive that is not shared)")
            if cancelled do say "Cancelled: the rest was left as it was."
            not cancelled
        )
    ),

    fn saveLog dest =
    (
        try
        (
            local f = createFile ((trimSlash dest) + "\\collect_assets_log.txt")
            format "% %\n%\n\n" localTime (maxFilePath + maxFileName) "" to:f
            for l in logLines do format "%\n" l to:f
            close f
        )
        catch ()
    )
)

CollectAssets = CollectAssetsStruct()

------------------------------------------------------------------------ dialog
try (destroyDialog CollectAssetsDlg) catch ()

rollout CollectAssetsDlg "Collect Assets 1.0" width:470
(
    local iniFile = (getDir #plugcfg) + "\\CollectAssets.ini"

    group "Collect into"
    (
        edittext edDest "" width:405 across:2 align:#left offset:[-4, 0]
        button btnDest "..." width:28 height:18 align:#right offset:[4, 0] tooltip:"Choose the folder"
        checkbox cbSub "Sort into subfolders: maps, proxies, xrefs, other"
    )
    group "What"
    (
        checkbox cbImage "Images (textures, HDRI)" checked:true across:2
        checkbox cbProxy "Proxies" checked:true
        checkbox cbXref "XRefs (.max)" checked:false across:2
        checkbox cbOther "Other (IES, caches, ...)" checked:false
        checkbox cbOverwrite "Overwrite a different file of the same name (off: keep both, in _dup folders)"
    )
    group "Paths"
    (
        checkbox cbUNC "Make all paths UNC" checked:true
        checkbox cbAdmin "Local drive that is not shared: use the hidden share, \\\\PC\\D$" checked:true
    )
    group "Missing files: look in these folders"
    (
        listbox lbDirs "" height:5
        button btnAdd "Add Folder..." width:100 across:4 align:#left
        button btnRemove "Remove" width:70 align:#left offset:[-8, 0]
        checkbox cbRecursive "With subfolders" checked:true offset:[-20, 3]
        button btnFind "Find Missing" width:100 align:#right
        checkbox cbSearchFirst "Look for missing files before collecting" checked:true
    )
    button btnScan "Scan Scene" width:140 height:26 across:3
    button btnUNC "Paths to UNC Only" width:140 height:26
    button btnGo "Collect and Relink" width:140 height:26
    progressBar pbar height:8 color:(color 119 168 227)
    listbox lbLog "" height:11

    fn logLine msg =
    (
        lbLog.items = append lbLog.items msg
        lbLog.selection = lbLog.items.count
        format "%\n" msg
        windows.processPostedMessages()
    )
    fn setProgress pct = (pbar.value = pct)

    fn saveSettings =
    (
        setINISetting iniFile "settings" "dest" edDest.text
        local dirs = ""
        for d in lbDirs.items do dirs += d + "|"
        setINISetting iniFile "settings" "searchFolders" dirs
        for c in #(cbSub, cbImage, cbProxy, cbXref, cbOther, cbOverwrite, cbUNC, cbAdmin, cbRecursive, cbSearchFirst) do
            setINISetting iniFile "settings" c.name (c.checked as string)
    )
    fn loadSettings =
    (
        edDest.text = getINISetting iniFile "settings" "dest"
        lbDirs.items = filterString (getINISetting iniFile "settings" "searchFolders") "|"
        -- XRefs always start off: copying them is a decision for each scene
        for c in #(cbSub, cbImage, cbProxy, cbOther, cbOverwrite, cbUNC, cbAdmin, cbRecursive, cbSearchFirst) do
        (
            local v = getINISetting iniFile "settings" c.name
            if v != "" do c.checked = (v == "true")
        )
    )
    fn begin =
    (
        lbLog.items = #()
        pbar.value = 0
        CollectAssets.logLines = #()
        CollectAssets.cancelled = false
        CollectAssets.useAdminShare = cbAdmin.checked
        CollectAssets.logFn = logLine
        CollectAssets.progressFn = setProgress
        saveSettings()
    )
    fn doFind =
    (
        if lbDirs.items.count == 0 then logLine "Add a folder to look in first."
        else CollectAssets.findMissing lbDirs.items recursive:cbRecursive.checked
    )

    on CollectAssetsDlg open do loadSettings()
    on CollectAssetsDlg close do saveSettings()

    on btnDest pressed do
    (
        local d = getSavePath caption:"Collect the scene's files into" initialDir:(if edDest.text != "" then edDest.text else maxFilePath)
        if d != undefined do edDest.text = d
    )
    on btnAdd pressed do
    (
        local d = getSavePath caption:"Look for missing files in" initialDir:(if lbDirs.items.count > 0 then lbDirs.items[lbDirs.items.count] else maxFilePath)
        if d != undefined and findItem lbDirs.items d == 0 do lbDirs.items = append lbDirs.items d
    )
    on btnRemove pressed do
    (
        if lbDirs.selection > 0 do lbDirs.items = deleteItem lbDirs.items lbDirs.selection
    )
    on btnScan pressed do (begin(); CollectAssets.scan())
    on btnFind pressed do (begin(); doFind())
    on btnUNC pressed do
    (
        begin()
        CollectAssets.makeUNC()
        logLine "Done. Save the scene to keep the new paths."
    )
    on btnGo pressed do
    (
        begin()
        local kinds = #()
        if cbImage.checked do append kinds #image
        if cbProxy.checked do append kinds #proxy
        if cbXref.checked do append kinds #xref
        if cbOther.checked do append kinds #other
        if edDest.text == "" then logLine "Choose the folder to collect into first."
        else
        (
            if cbSearchFirst.checked and lbDirs.items.count > 0 do doFind()
            local ok = CollectAssets.collectTo edDest.text kinds subfolders:cbSub.checked overwrite:cbOverwrite.checked unc:cbUNC.checked
            if ok and cbUNC.checked do CollectAssets.makeUNC()
            if ok do logLine "Done. Save the scene to keep the new paths."
            CollectAssets.saveLog edDest.text
        )
    )
)

if CollectAssets_noUI != true do
(
    createDialog CollectAssetsDlg
    -- an action for toolbars and menus, pointing at this file where it is now
    try
    (
        execute ("macroScript CollectAssets category:\"Asset Tools\" buttonText:\"Collect Assets\" tooltip:\"Collect Assets: copy images and proxies to one folder, relink, UNC paths\" (on execute do fileIn @\"" + getThisScriptFilename() + "\")")
    )
    catch ()
)
