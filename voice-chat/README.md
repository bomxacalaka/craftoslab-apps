# Phone

Phone is a client-only CC: App app that hides a noisy pocket computer's GUI and continuously sends microphone segments to its attached speaker.

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

## Install or hot reload the manifest

```bash
./sync-to-minecraft.sh --profile "/path/to/minecraft/profile"
```

Keep the Phone screen open while syncing to hot reload JSON layout changes. Java backend changes require rebuilding and reinstalling the CC: App JAR, followed by a Minecraft restart.

Recordings and converted temporary files stay under `cc-apps/apps/voice-chat/data/` in the selected Minecraft profile.
