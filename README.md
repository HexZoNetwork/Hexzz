# Hekz — free Roblox chatbot (100% hosted in-game, no VPS)

Free chat, no prefix, no allowlist (pretest). Talk in the GUI panel — ask or command.
GUI chat (`HekzChat`) is PRIMARY. Roblox bubble chat is secondary fallback.
NO VPS, NO Go sidecar. The game server calls the AI completions API directly
and runs all tools itself in Luau.

> `exec` runs raw **Luau ONLY** on the game server via `loadstring`.
> NEVER Go inside Roblox — "you cannot run Go code directly inside a Roblox
> script". Anyone chatting can run anything. Intentional for pretesting.
> Add your own allowlist before public release.

## How it works (all in-game)

```
GUI panel input → HekzChat:FireServer(text) → HekzServer (ServerScriptService)
  → no allowlist, cooldown only
  → per-player history (rolling N)
  → HttpService POST AIBase/chat/completions DIRECTLY (agent loop, bots-style)
        game holds AIKey, sends OpenAI tools = ToolRegistry:openAIDefs(),
        MODEL decides: answers directly or call tools → game executes them
        HERE → results fed back → repeat (max Brain.MaxRounds)
  → reply = the model's own text, verbatim, via HekzReply + HekzLastReply
Bubble chat → Player.Chatted → same handleMessage (fallback)
No key → short notice. No keyword routing, no canned replies, anywhere.
```

Talk in the panel: `what time is it`, `calc (2+3)*4`, `scan the map`,
`parts near me`, `find Spawn`, `spawn a part`, `teleport me to SpawnLocation`,
`who is here`, `read MyScript`, `run print("hi")`.

## The Book (AI powers, no restriction)

`HekzBook.lua` is the power book: every tool, exec Luau-only, no folder
restriction, chain up to `Brain.MaxRounds` steps. Server sends
`SystemPrompt + HekzBook.TEXT` as the system prompt. Ask `help`/`powers`/`book`.

## Tools (map bunch + code, all Luau in-game)

| Tool | What |
|---|---|
| `get_time` | UTC clock |
| `calc` | math |
| `server_info` | players, uptime, place |
| `players` | who is online + positions (+leaderstats) |
| `map_scan` | quick vision: census + near you + named |
| `parts_near` | parts around you, nearest first (`radius/limit/class`) |
| `find_objects` | search map by name (`query/class/limit`) |
| `object_info` | props of one object (`path`) |
| `workspace_tree` | hierarchy list (`path/depth/limit`) |
| `lighting_info` | clock/fog/brightness |
| `spawn_part` | build an anchored part (no coords = near you) |
| `teleport_me` | move yourself (`x,y,z` or `target`) |
| `delete_object` | destroy one object (`path`) |
| `http_fetch` | GET a URL from the game (HTTP Requests ON) |
| `read_script` | read ANY Script by name or dotted path (no restriction) |
| `write_script` | code a real Script/ModuleScript at a path, then `exec`/require it |
| `exec` | UNIVERSAL: run any Luau, print + return (`code`, aliases `run`/`execute`/`loadstring`) |

## Files → Studio (5 Luau files, no Go needed)

| File | Type | Location |
|---|---|---|
| `Config.lua` | ModuleScript `HekzConfig` | `ReplicatedStorage` |
| `HekzBook.lua` | ModuleScript `HekzBook` | `ReplicatedStorage` |
| `ToolRegistry.lua` | ModuleScript `ToolRegistry` | `ServerScriptService` (next to HekzServer) |
| `HekzServer.lua` | Script | `ServerScriptService` — auto-creates `HekzToggle`, `HekzChat`, `HekzReply` |
| `HekzGui.client.lua` | LocalScript `HekzGui` | `StarterPlayer > StarterPlayerScripts` |
| `go-bridge/` | LEGACY, unused | ignore — kept only for reference, game no longer calls it |

## How to run in executor (no Studio, no plugin)

`HekzExecutor.lua` is all-in-one — one file, everything inside
(tools + AI brain + dark H panel). Works on Synapse / Script-Ware /
Delta / Fluxus / Solara style executors.

**Step by step:**
1. Join any game on the Roblox client where your executor works.
2. Attach/open your executor.
3. Run it — pick ONE:
   - **A. Paste:** copy the whole `HekzExecutor.lua` → paste into the
     executor editor → **Execute**.
   - **B. Loadstring:** host the file raw (e.g. GitHub), then run:
     ```lua
     loadstring(game:HttpGet("https://raw.githubusercontent.com/HexZoNetwork/Hexzz/refs/heads/main/HekzExecutor.lua"))()
     ```
   - ⚠️ Run `HekzExecutor.lua` — NOT `HekzServer.lua` (that one is the
     Studio build and can never run in an executor).
4. The black **H** button appears (bottom-right). The panel opens by itself
   on first run — drag it by the header, close with **X**, reopen with **H**.
5. Talk in the panel input (NOT bubble chat): `scan the map`,
   `parts near me`, `find Spawn`, `spawn a part`, `run print("hi")`.
6. AI setup (all in the panel, no pre-editing): paste the key into
   **AI KEY**, set **API GATEWAY** (any OpenAI-completions base URL, e.g.
   `https://api.openai.com/v1` — a full `.../chat/completions` URL works
   too), then tap **SCAN** to list the gateway's `/models` and tap one
   (or type the id into **MODEL** by hand) → **SAVE**, tap the **AI/LOCAL**
   pill to green AI. Without a key you get a short notice instead of a
   brain (the model does ALL thinking — no keyword fallback). Key stays
   on your client only.
   (`getgenv().HEKZ_AIKEY` before running still works too.)

**If nothing happens:**
- Make sure you executed `HekzExecutor.lua`, not `HekzServer.lua`.
- Raw GitHub caches a few minutes after you re-upload — wait ~5 min
  and re-execute if the UI looks outdated.
- Run it wrapped to see the real error in your executor console:
  ```lua
  local ok, err = pcall(function()
      loadstring(game:HttpGet("https://raw.githubusercontent.com/HexZoNetwork/Hexzz/refs/heads/main/HekzExecutor.lua"))()
  end)
  if not ok then warn("[Hekz] failed: " .. tostring(err)) end
  ```

Notes:
- HTTP uses `syn.request` / `http_request` / `request` when present, else
  `HttpService` — no game HTTP toggle needed on most executors.
- `read_script` tries `.Source`, then executor `decompile()` (LocalScripts /
  ModuleScripts work; server-only Scripts report honestly when unreadable).
- `spawn_part` / `delete_object` / `teleport_me` act client-side (visuals may
  not replicate — normal executor behavior).
- Toggles are local (`getgenv().HEKZ.Tools`), GUI `H` button included.

Enable: Game Settings → Security → HTTP Requests ON (only for `ai` mode + `http_fetch`).

## Quick start (local mode, no key)

1. Paste the 5 Luau files as above. Play Solo.
2. Click `H` → talk in the panel input (NOT bubble chat).
3. Toggles: green `#2ECC71` = ON, red `#E74C3C` = OFF.

## AI mode (direct, in-game)

1. HTTP Requests ON.
2. Set `Brain.Mode = "ai"`, `Brain.AIBase` → your OpenAI-compatible base
   (default `https://9router.kliksosmed.id/v1`), `Brain.AIModel`, `Brain.AIKey` → your key.
3. Key stays server-side (never replicates). Talk in the panel — the AI chains
   map tools + `exec` Luau itself.

## GUI

- Palette: `#121214` bg, `#1E1E22` surface, `#46464C` border,
  `#F0F0F2`/`#96969C` text — black/white/gray, dominant dark.
- Motion: `TweenService` everywhere (~0.28s).
- Config booleans auto-render green-ON / red-OFF pills. String keys (AIBase/AIKey)
  are set by editing `HekzConfig` directly.

## Pretest warning

No allowlist + `exec`/`spawn`/`delete` = anyone can run/build/destroy.
Fine for solo pretest. Before sharing, gate `handleMessage` and those tools
by `player.UserId` yourself.

## Tests without Roblox (`test.sh`)

```bash
./test.sh   # needs network ONCE to fetch the Luau runtime (cached in .testbin/)
```

Runs on real Luau (zero Roblox): syntax-checks every file with the actual
parser, then executes `ToolRegistry` + the full agent loop against a mocked
game with a scripted fake model — `calc`, `exec` (+print capture, aliases,
Go guard), `write_script` round-trip, `bring`/`teleport`, verbatim model
text, native tool_calls, ```tool text calls, no-key notice. Exit `0` = all
green. The executor panel itself still needs eyeballing in a real executor.
