# AGENTS.md

## Language

All documentation in this repository (README, AGENTS.md, code comments, commit messages) is written in **English**.

## Project

WoW addon `QuestProgressAlert` (shown as "Quest Progress Alert"): replaces the yellow quest progress text of `UIErrorsFrame` with animated popup cards (icon, objective, counter, progress bar, quest name), stacked when several objectives progress, plus a "Quest complete!" banner and sounds.

- `QuestProgressAlert.toc`: addon manifest, interface `16001` (WoW Forever only), SavedVariables `QuestProgressAlertDB` (account-wide options)
- `Locales.lua`: all user-facing strings, English base table plus overrides per locale (currently deDE), exposed as `ns.L`
- `Core.lua`: defaults, sound/font lists, parsing of the quest messages, quest log lookup, item icons, hiding the default text, test sequence, `/qpa`, events
- `Portraits.lua`: enemy portraits for kill objectives. Every attackable NPC seen (target, mouseover, `NAME_PLATE_UNIT_ADDED`, `UNIT_TARGET` of party/raid members) gets its own texture painted with `SetPortraitTexture` and kept for the session, keyed by NPC ID (from the GUID) and name, at most 100 (least recently seen dropped, textures reused, ones shown on a card never). A card borrows the texture (reparents it into its icon frame with its mask) and gives it back on release. Optional Questie lookup (`QuestieLoader:ImportModule("QuestieDB").GetQuest(questID).ObjectiveData[objectiveIndex]`, types `monster` and `killcredit`) maps an objective to NPC IDs; `## OptionalDeps: Questie`.
- `Cards.lua`: the popup cards (creation, look, stack layout, animations), the anchor and the mover
- `Options.lua`: options page with Blizzard's Settings API (vertical layout)
- `Media/*.tga`: textures, rendered by `tools/make_textures.py` (plain Python, run `python -I tools/make_textures.py`; set `QPA_PREVIEW_DIR` to also get PNG copies). All white shapes with alpha, tinted in game.

Key behavior:

- Quest progress arrives as `UI_INFO_MESSAGE` (`messageType`, `message`). `GetGameMessageInfo(messageType)` gives the name (`ERR_QUEST_ADD_ITEM_SII`, `ERR_QUEST_ADD_KILL_SII`, `ERR_QUEST_ADD_PLAYER_KILL_SII`, `ERR_QUEST_ADD_FOUND_SII`, `ERR_QUEST_OBJECTIVE_COMPLETE_S`, `ERR_QUEST_UNKNOWN_COMPLETE`, `ERR_QUEST_FAILED_S`), the same list Questie uses.
- The message text is parsed with a Lua pattern built from the global format string of that name (handles `%1$s` positions), so it works in every client language.
- The default yellow text is hidden per message type with `UIErrorsFrame:SetMessageTypeEnabled(type, false)` (Forever uses the mainline `UIErrorsMixin`). The type number comes from `LE_GAME_<name>` or a scan over `GetGameMessageInfo`.
- The quest log may update after the message, so the quest name and completion are looked up up to three times (`C_QuestLog.GetInfo` / `GetQuestObjectives` / `IsComplete`, fallback to the old `GetQuestLogTitle` API).
- Cards are keyed by kind + objective name: progress on the same objective updates the card and moves it to the front.
- Sounds are file data IDs that exist in Forever (same ones Questie uses). Several messages within 0.25 s play only the most important sound.

The Forever UI source is mirrored at https://github.com/Gethe/wow-ui-source (branch `forever`, game type "Camelot"). Check it before relying on Blizzard frame or function names.

When adding a user-facing string, add the key to the English base table and to every locale in `Locales.lua`.

## Installed copies

The addon is installed as a plain copy (not a clone) in:

- `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\QuestProgressAlert`

After changing the `.toc`, any `.lua` or `Media`, copy them to the Forever installation. The folder name must stay `QuestProgressAlert`. `tools/` is not needed in game.

## Testing

There is no automated test setup. Changes are verified in game with `/reload` and `/qpa test`; Lua errors show up with `/console scriptErrors 1` (or BugSack). A syntax check is possible with `luajit -bl <file>.lua`.

## Releasing

Published on CurseForge as project `1796362` (https://www.curseforge.com/wow/addons/quest-progress-alert) and as GitHub releases. Releases are built by `.github/workflows/release.yml` with the BigWigs packager (`.pkgmeta` sets the folder name and leaves out `AGENTS.md`, `CLAUDE.md` and `tools/`).

1. Commit and push the changes to `main`.
2. Tag and push: `git tag -a vX.Y.Z -m "X.Y.Z"` and `git push origin vX.Y.Z` (semantic versioning).
3. The workflow packages the addon, replaces `@project-version@` in the TOC with the tag, uploads the zip to CurseForge (project ID from `X-Curse-Project-ID` in the TOC, game version from the TOC interface) and creates the GitHub release.

The upload needs the repository secret `CF_API_TOKEN`. Never edit `## Version` in the TOC by hand; installed dev copies show `@project-version@`.
