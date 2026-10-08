# Phone

Phone is a client-only CC: App app that hides a noisy pocket computer's GUI, continuously sends microphone segments to its attached speaker, and — on worlds with the CC: App server component — lets you dial other players for a two-way voice call.

## Requirements

- CC: App with the bundled Phone backend
- FFmpeg on the client `PATH`
- A microphone available to the Java/Minecraft process
- A powered CC:Tweaked computer with an attached speaker
- For background mode, a noisy pocket computer kept in the same hand used to open it

## Background mode

Put the noisy pocket computer in your offhand first and use it. CC:Tweaked shows its terminal over the world with “Pocket computer open.” While that overlay is active, press **F8**, select **Phone**, and enable voice chat. After the receiver installs, the terminal overlay closes, normal world/chat controls return, microphone capture continues, and the newest converted segment replaces any older segment waiting to upload. Open Phone again or use its pinned radial action to stop.

The hidden screen still relies on the pocket computer's active server menu. You may walk, interact with the world, and chat, but opening another container, moving the pocket out of its original hand, disconnecting, or dying ends the session. This remains entirely client-side and does not add a server mod or a general voice network.

Phone also provides optional local sound feedback and push-to-talk. The registered defaults are **V** for Push to Talk and hold **R** for the radial menu; both can be rebound under Minecraft Controls → CC: App. Right-click a Phone toggle to pin or unpin it from the radial menu, then hold R, point at an action, and release.

**Noise reduction** (Phone screen, "Noise reduction" slider) gates background noise in the microphone path before DFPWM encoding. It is **on by default at Low**; choose Off, Low, Medium, or High depending on how noisy the room is. The choice persists in `phone-controls.json` in the profile's `cc-apps` directory.

## Player number

If the server you join has the CC: App server component installed, you are assigned a unique 4-digit number (1000–9999) the first time you connect. It is **stable per world (per save)**: you keep the same number across rejoins, but a different world gives a different number, and the number is forgotten when that world is deleted. It is shown on the Phone screen ("My number") and on the CC: App home status line so you can share it with others. Until a modded server assigns one the screen shows "—"; the last number you saw is remembered locally in `phone-number.json` in the profile's `cc-apps` directory and keeps displaying, even on servers without the mod.

## Calls

When both you and the person you want to talk to are on a world running the CC: App server component, you can call them directly: press **N** (or the **Dial** button on the Phone screen) to open the keypad, enter their 4-digit number, and confirm. The server starts ringing their client; they press **Y** (or **Accept** on the incoming-call screen) to answer, **Esc** to decline, or simply let it ring out (60 seconds). Once connected, a small call screen shows the peer's name and the running time; **X** (or **Esc**, or the **Hang up** button) ends the call for both sides. A player's death or disconnect ends their calls. Call state is persisted per world, but the moment either player rejoins after a server restart the saved pair is checked against who is actually online and pruned, so a restart never strands a ringing line or a stuck call — both players simply start fresh.

The call audio is DFPWM (the same codec as background voice and CC:Tweaked speakers): your microphone is encoded on the fly and relayed, and the peer's stream is decoded and played straight through your own output device — no computer or speaker involved. The server is a dumb pipe: it relays voice bytes without inspecting or storing them. There is at most one active call per player (a ringing player is busy in both directions), voice segments are capped at 8192 bytes (oversized segments are dropped, never queued — on a slow connection the audio degrades to choppiness rather than lag), and calls never touch gameplay.

Calls and background voice chat are mutually exclusive: starting a call or taking one silently stops background transmission, and enabling background voice chat while a call is live is rejected. The dialer keys (**N** dial, **Y** accept, **X** hang up) can be rebound under Minecraft Controls → CC: App, and the radial menu (hold **R**) always carries **New call**, **Accept**, and **Hang up** so a call can be answered or ended without opening the Phone screen.

## App store

The quick view's **App store** button opens the CC: App store screen over the Phone: approved apps from https://cc-app-store.web.app with their icon, version, and author. Selecting one shows its description and size, and **Install** downloads the package, verifies it, and installs it into the profile's `cc-apps/apps/` folder — after which it appears in the F8 launcher like any synced app. **Uninstall** removes the app but keeps its `data/` folder (its user state), so reinstalling restores it to exactly where it was. Store connection settings live in `cc-apps/store.json` (see the mod's README).

## Install or hot reload the manifest

```bash
./sync-to-minecraft.sh --profile "/path/to/minecraft/profile"
```

Keep the Phone screen open while syncing to hot reload JSON layout changes. Java backend changes require rebuilding and reinstalling the CC: App JAR, followed by a Minecraft restart.

Recordings and converted temporary files stay under `cc-apps/apps/voice-chat/data/` in the selected Minecraft profile.
