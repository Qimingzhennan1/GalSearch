# Gal Search MVP Handoff

## Project Goal

A **portable Windows desktop tool** for searching `gal` resource pages:
- Search keywords against local cache and public Baidu search results
- Display title, source URL, snippet, tags, and metadata
- Open the sharing page in browser or copy the URL
- Editable tags per result, persisted to local cache
- **No downloading, no login automation, no bypass of access restrictions.**

---

## Current State (Completed MVP)

### What Is Implemented

#### Core search
- Keyword search (Enter trigger, Ctrl+F/L focus search box)
- Local cache in `%LOCALAPPDATA%\GalSearchMVP\index.json` (JSON, auto-merge on URL)
- Online search via public Baidu result pages (HTML regex parsing)
- Source filter (All / Baidu) and sort (Relevance / Time / Title)
- Empty state: shows guidance text when no results

#### UI
- MenuStrip: File (Reload, Exit), Edit (Search, Copy URL), View (Sort by), Help (About)
- Result list (DataGridView) + detail panel (SplitContainer layout)
- Detail panel: title, source, share URL (clickable link), cache time/seen count
- Editable tags: TextBox + Save button, persists back to index.json
- Open source link (double-click row or button)
- Copy URL to clipboard
- About dialog with version info and disclaimer

#### Keyboard shortcuts
| Shortcut | Action |
|----------|--------|
| `Enter` | Search |
| `Ctrl+F` / `Ctrl+L` | Focus search box + select all |
| `Ctrl+R` | Reload all cached items |
| `Ctrl+C` | Copy selected URL (menu item) |
| `Esc` | Clear query or deselect row |

#### Bug fixes applied
- Reload Cache button now loads full cache (was incorrectly re-running search)
- SplitContainer Panel2MinSize/SplitterDistance moved to Shown event to avoid layout crash
- All RowStyles.Add() calls suppressed with `| Out-Null` to avoid console output
- `KeyPreview = $true` added for global keyboard shortcuts

### Portable Launchers

| File | Type | UX |
|------|------|----|
| `GalSearch.vbs` | VBScript | ✅ No console window, double-click to launch (recommended) |
| `Run-GalSearch.bat` | Batch | Shows console window (debug mode) |
| `install.bat` | Batch | Double-click to install Desktop shortcut |
| `install.ps1` | PowerShell | Shortcut installer script |

The app is **fully portable**: copy the whole folder to any Windows machine (USB drive, network share, etc.) and run `GalSearch.vbs`. No dependencies beyond Windows + PowerShell 5.1 (both pre-installed on Windows 7+).

---

## Important Files

| File | Purpose |
|------|---------|
| `GalSearch.ps1` | Main application |
| `GalSearch.vbs` | Silent launcher (VBScript, no console window) |
| `Run-GalSearch.bat` | Batch launcher (debug mode, shows console) |
| `install.bat` | One-click shortcut installer |
| `install.ps1` | Shortcut creation script |
| `README.md` | Documentation |

---

## How To Run

**Recommended:** Double-click `GalSearch.vbs`
**Debug:** Double-click `Run-GalSearch.bat`
**First-time setup:** Double-click `install.bat` to create desktop shortcut

---

## Behavior Summary

1. User types keyword, presses Enter (or clicks Search).
2. If "Online search and cache" is checked → fetches Baidu results, caches them, then shows merged results.
3. If unchecked → searches local cache only.
4. Selection in list populates detail panel (right side).
5. Tags can be edited in the detail panel and saved to cache.
6. User can open the sharing page (browser) or copy the URL.

---

## Technical Details

- **Stack:** PowerShell 5.1 WinForms (.NET Framework, no external runtimes)
- **Storage:** JSON file, auto-created with empty array seed
- **Search scoring:** Title (100), Snippet (25), URL (15), Source (5) — AND-match for terms
- **Merge strategy:** URL-deduplicated; updates Title/Snippet on re-fetch, increments SeenCount
- **SplitContainer:** Panel1MinSize/Panel2MinSize/SplitterDistance set in Shown event (avoids layout exception)

---

## Constraints and Risks

- **Baidu parser fragility:** Uses regex over public HTML → breaks if Baidu changes page structure
- **Execution Policy:** `Run-GalSearch.bat` passes `-ExecutionPolicy Bypass` to handle restricted policies on user machines
- **STA requirement:** WinForms requires Single-Threaded Apartment (`-Sta` flag), enforced in both launchers
- **Legal boundary:** Search and navigation only. No download automation, login handling, or access limit bypass.

---

## Recommended Next Steps (if continuing)

1. **Baidu parsing robustness** — Add fallback patterns or switch to a more structured approach
2. **Multiple data sources** — Support other search engines or custom source definitions
3. **Tauri / Qt port** — If toolchains become available, port the UX to native app for better startup time and no console dependency
4. **App icon** — Generate a proper `.ico` file and associate it with the VBS or compiled EXE
5. **Auto-update** — Check for new versions of the search cache or app itself

---

## Notes For The Next Model

- The source of truth is `GalSearch.ps1` in the output directory.
- Preserve the local JSON cache format (`Version`, `Items` array with per-URL merge) unless migrating.
- Keep the legal boundary intact: search and navigation only.
- The entire app is one PowerShell file + launcher scripts. No build step needed.
