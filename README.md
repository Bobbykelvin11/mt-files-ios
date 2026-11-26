# MT Files (iOS)

An original two-pane file manager, archive tool and code editor for iPhone and iPad, with a built-in AI assistant. Inspired by Android power-user file managers, rebuilt from scratch in SwiftUI. By Bobby Media Co.

## Features
- **Dual-pane file manager** – side by side on iPad / landscape, swipe between panes on iPhone. Copy / move between panes, rename, batch rename (`photo_#`), delete, new file / folder, multi-select, sort, filter, deep search (name + content), info with SHA-256 / SHA-1 / MD5, favorites.
- **Folders from Files** – add iCloud Drive or other apps' folders; access is kept with bookmarks.
- **Archives** – zip / unzip, archive browser, `.ipa` editor (name, icon, bundle ID, version, Info.plist, files) with unsigned repack.
- **Editors & viewers** – code editor with syntax colors (25+ languages), line numbers, find / replace (regex), go to line, undo / redo, auto-indent; JSON pretty-print / minify; plist (binary/XML) key editor and source view; hex viewer with jump-to-offset; zoomable image viewer; Quick Look for audio, video, PDF and Office files.
- **AI assistant** – everywhere (✨ button, AI tab, editor). Plan → confirm → execute: the AI proposes a numbered plan, you tap **Confirm** (or type "go on"), and it runs every step with live progress, then continues on its own using the results. Explains files, refactors selections (diff), generates files, suggests names, file ops ("zip this folder", "find all .json files", "rename all jpgs to photo_#"). Direct, no-lecture system prompt. Any provider / any model: Groq, OpenRouter (incl. uncensored models), OpenAI, or your own OpenAI-compatible server (LM Studio, Ollama) with no key; "Browse models" lists what the server offers. Offline command parser when no provider is set.
- **GitHub IPA search** – IPA tab → "find …" searches GitHub releases for open-source IPAs.
- Dark theme, file sharing (Files app → On My iPhone → MT Files), "Open in MT Files" for any file type.

## Rules
MT Files never cracks apps, unlocks subscriptions or in-app purchases, bypasses licenses or DRM, or decrypts App Store apps. The AI assistant refuses those requests.

## Build
GitHub Actions (`.github/workflows/build-ipa.yml`) builds an unsigned `MTFiles.ipa` with XcodeGen + Xcode on macOS. Sign it with Sideloadly, SideStore or AltStore. iOS 16+.

Code from [IPA Studio](https://github.com/Bobbykelvin11/ipa-studio-ios) is reused for the IPA editor. Uses [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT).
