# EdgeControl

EdgeControl turns the edges of your Mac trackpad into controls for brightness, volume, and media playback.

## What it can do

- Swipe along a selected edge to adjust display brightness or audio volume. Choose any trackpad edge; the sides use up/down swipes, while the top and bottom use left/right swipes.
- Once a swipe qualifies at an assigned edge, it keeps that control and direction axis for the whole touch. You may move toward the centre or cross another edge without switching controls. Lift to end the gesture; a new touch must start at an assigned edge again. Palm-sized or multiple contacts still cancel the gesture.
- Enable EDR Headroom on supported displays to raise SDR brightness above 100%, up to the display's supported limit (capped at 200%). The settings overview shows the current EDR brightness.
- Above 100%, the HUD is labelled **Brightness Boost**. At 100%, when boost is enabled and supported, a hint asks for another swipe: right along a top/bottom edge, or up along a left/right edge.
- Tap a selected corner to mute or unmute audio, or to toggle media playback. Adjust **Corner Tap Size** from 4% to 20% of the trackpad width and height for both actions (default: 12%). If both actions use the same corner, Quick Mute takes priority. EdgeControl shows a HUD when either action is triggered.
- Enable **Hold to Lock** to lock your Mac by holding one finger still in a selected corner. Choose any corner and set **Lock Countdown Duration** from 0.5 to 10 seconds in 0.1-second steps (default: top left, 2 seconds). This is the total time from touching the corner until locking. The orange countdown HUD appears only after holding for 0.3 seconds, so quick taps do not flash a lock countdown. It counts down in tenths of a second (for example, `1.7s → 1.6s → 1.5s`), including a brief `0.0s`, before locking. It uses the same **Corner Tap Size** setting. Lift, move away, or add another finger to cancel. Short taps can still mute or control playback in the same corner. This feature is off by default and requires raw trackpad contact support.
- Swipe an unassigned top or bottom edge to skip to the previous or next track.
- Adjust edge width and sensitivity, enable fine control, require Fn or Control, freeze the pointer during gestures, and turn haptic feedback on or off.
- Palm filtering uses a fixed contact-size limit and rejects broad contacts until lift. For volume on the left/right edge, the first actual volume change must happen within one second of touching down; otherwise that touch is ignored until lift. Once volume has changed, the swipe continues normally, including toward the centre. Side-edge brightness swipes keep their 0.6-second activation window. Top/bottom swipes allow small vertical deviations and a pause before moving; their activation is more forgiving.
- Contacts starting on the top/bottom edge outside the side strips get more generous contact-size limits for broader fingers. That size policy stays fixed for the whole touch, including movement into the centre. Side and corner starts keep the stricter palm filter; multiple contacts and very large contacts are still rejected.
- Show or hide the menu bar item and launch EdgeControl at login.
- Enable **Trackpad Debug** to show an overlay, initially at the top-left of the screen. Drag its title to move it; its position is remembered. It displays raw received frames, single-contact frames passed by the filter, frame rate, sampled main-queue delay, time since the latest frame, touch coordinates, and gesture state. A scrollable list underneath shows the last 25 timestamped rejections with a **Copy All** button. X/Y are normalized from 0 to 1: X increases left to right and Y bottom to top. Coordinates show the first active contact, even if rejected by the filter, and clear on lift. The option is off by default and is remembered across launches; disabling it hides the overlay and stops diagnostic updates.

Play/pause controls the active system media session directly and shows Play or Pause only after the player confirms its new state. If it cannot confirm, the HUD shows No response instead. Play/pause no longer depends on simulated media keys or their Accessibility grant; previous/next media-key gestures may still require Accessibility permission.

With **Trackpad Debug** enabled, **Rejection History (last 25)** in settings opens a scrollable history for the current app session. Each entry contains local time, the exact reason, original touch coordinates, rejection coordinates, and available contact-size/edge-width data. Repeated frames for the same rejected touch are grouped. **Copy All** copies the report for sharing; **Clear** empties the list. The overlay also keeps the most recent rejection's start coordinates visible.

## Install the release

The downloadable app is ad-hoc signed for this project, but it is not signed with an Apple Developer ID or notarized. macOS may therefore report that `EdgeControl.app` is damaged after downloading it in a browser.

After unzipping the release into `~/Downloads`, remove the quarantine attribute and open the app:

```sh
xattr -dr com.apple.quarantine ~/Downloads/EdgeControl.app
open ~/Downloads/EdgeControl.app
```

Only run this command for a release you downloaded from the official EdgeControl repository and trust. It removes macOS's downloaded-file quarantine flag for this app; it does not modify the app's code.

## Build and run

Open `EdgeControl.xcodeproj` in Xcode and press **Run**. To build from Terminal:

```sh
xcodebuild -project EdgeControl.xcodeproj -scheme EdgeControl -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Palm rejection checks

Run `sh scripts/check-palm-rejection.sh` to replay contact frames and check palm filtering, swipe qualification, and multiple-device handling without changing system volume. Physical trackpad testing is still needed to tune contact-size thresholds.

Run `sh scripts/check-media-playback.sh` for media-result validation. Adding `--live` briefly toggles the active player's playback and restores its original playing/paused state.
