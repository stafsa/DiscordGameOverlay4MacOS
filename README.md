# DiscordGameOverlay4MacOS
It's a...game overlay for discord on Mac.Thought, I don't know how to like...make this without embedding my client secret into the code as a string, 
so I won't compile it.
# Compiling
First, you need to create an application from "https://discord.com/developers/applications" and get it's client and 
client secret and insert those in "<insert yours here ig>".

Next, you'll need to build it using the following command:
```bash
clang -dynamiclib -fobjc-arc -framework Cocoa -framework ApplicationServices -framework Carbon main.m
  -o a.dylib
```
Once it's built, you need to install insert_dylib from **[[insert_dylib] (https://github.com/stafsa/DiscordGameOverlay4MacOS/releases/download/helper_tools/insert_dylib)** and 
go to where it is in your terminal, and run
```bash
./insert_dylib a.dylib <the game you want the game overlay on, the binary tho>
```
then you should resign it, as the signature has been deprecated since you changed it's hash.
```bash
codesign -s - -f a.dylib
codesign -s - -f <the game binary>
```
andd you should be fine.Be careful as anti-cheats may detect and ban you.

# Tags
Discord Overlay MacOS, Discord Game Overlay MacOS, Overlay, Discord Overlay Mac, Discord Voice List MacOS, Discord IPC Game Overlay
