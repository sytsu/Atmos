# Atmos

Atmos is a fork of [Madeira](https://github.com/willfaust/Madeira). It keeps
Madeira's runtime (Wine, FEX, DXMT, madeira-d3d12) and adds the following.

## Deck Mode

**Settings › Deck Mode** puts **Big Picture** beside **Desktop** in the library.
Big Picture is Valve's own Steam client in its controller interface, full screen.
The idea comes from [iDeck](https://github.com/kuscholar/iDeck), but Atmos builds
it on Madeira's own Big Picture launch (`LibraryEntry.bigPictureEntry`). In
Madeira that launch only shows up in builds made with `MADEIRA_BIG_PICTURE_UI`.

- **Ready to play** lists what Big Picture still needs: a Steam sign-in, Madeira
  Dock's Steam components, the Big Picture interface (downloaded from Valve on the
  first start), JIT and a controller.
- **When Atmos opens** can start Big Picture or the last game you played as soon
  as the app opens. JIT is requested first, as it is when you tap Play. A Home
  Screen shortcut or game link still starts its own game instead. If the previous
  automatic start was less than 20 seconds ago, this one is skipped, so a start
  that crashes can't trap the app in a loop.
- A controller can move the focus to Big Picture. In a session, the floating menu
  works the same as in any game: keyboard, touch controls, and Back+Start or Home.

## Offline play

**Settings › Offline play**

- If there is no network connection, or **Offline mode** is on, starting a game
  you've already installed skips the checks that would only time out:
  - the Steam Cloud check before a start (a known save conflict still stops the
    start)
  - Steam's launch-configuration lookup, which uses the stored copy instead
- Madeira Dock asks Valve's client for its offline logon straight away.
- **Prepare for offline** stores each installed Steam game's launch settings and
  syncs its saves while you're online. Start each Steam game online once so Steam
  can sign in offline later.

## Game files and mods

**Game details › Game files**

- Browse the game's folder, plus the prefix's *My Games*, *Saved Games* and
  *AppData* folders.
- Text files (ini, cfg, json, xml, lua and similar) open in an editor. Saving
  keeps the file's encoding, byte-order mark and line endings. The first save
  copies the original to `Atmos Backups`, and **Restore Original** puts it back.
- Deleting a file moves it to `Atmos Backups` instead of erasing it.
- **Mods** merges files and folders you pick in the Files app into the game's
  folder. Names are matched regardless of case. Every file a mod replaces is kept,
  and removing the mod puts those files back.

## Faster starts

When a game starts directly (not through Madeira Dock), the starting screen now
checks for the game's first frames ten times a second instead of twice. The game
can appear up to 0.4 s sooner.
