# DiscordGameOverlay4MacOS v3
This's the uhh...3rd release of DiscordGameOverlay4MacOS!This update's main aspect is to automate the injection, while it doesn't really
matter how did you inject the overlay.

# Preparation
You should resign every game you want the overlay on with ad-hoc, and with the task-get-allowed entitlement.
First, please take a copy of the main binary of the game you want to sign.Then, you get the current entitlements of the app with
```bash
codesign -d --entitlements - --xml the.game.you.want.the.overlay.on >> /tmp/entitlementsss.plist
```
and then, you should add the get-task-allow entitlement with
```bash
/usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" /tmp/entitlementsss.plist
```
and then, you can resign the binary using
```bash
codesign -s - -f --entitlements /tmp/entitlementsss.plist
```
If you couldn't find the main binary of the game you want to sign, please run helper.py and check missing_get_task_allow.txt near it.
It should contain the main binary of the game you should resign.If the file is empty, or if it doesn't exist, please recheck if the plugin
is installed and if the game you want the overlay on is detected.

# What helper.py+ exactly DiscordGameOverlayActivityBridge plugin do
helper.py creates a backend at localhost:7999, and starts listening /discord-games.This is where DiscordGameOverlayActivityBridge.plugin.js 
steps in, the betterdiscord plugin collects the detected game info and sends it as a json to localhost:7999/discord-games and helper.py
checks whether the game has the get-task-allow entitlement and if it has the entitlement, helper.py uses lldb to attach to the detected game
and tries injecting the overlay to that game.
This is how the json the betterdiscord plugin sends looks like:
```json
{
  "games": [
    {
      "id": "0",
      "name": "gameeee",
      "pid": 10324,
      "executable": "literalpath",
      "started_at": 1788174012000
    }
  ],
  "sent_at": 1788174023456
}
```
# What helper.py + wine_rpc_pipe_watcher do
As it's name suggests, wine_rpc_pipe_watcher.c creates the pipes between \\.\pipe\discord-ipc-0 and \\.\pipe\discord-ipc-9 and transfers
all the games that tried reaching that pipe to helper.py's backend.helper.py does pretty much the same thing.

# Bans 
I'm not responsible for any bans.Since this is literally considered client modification, some anti-cheats could mistake the overlay with cheats.
