# Organize drag interaction

Updated 2026-09-23. The active renderer is `ObsidianGraphScene`.

## Behavior

- Every visible mark is draggable: emails, replies, confirmed Groups, suggestions, You, and paging hubs. Paging hubs still expand on click.
- Email multi-drag preserves relative offsets. Other mark kinds move independently and cannot turn a stale email selection into a merge payload.
- Nearby movable nodes make room with at least 64 screen points of clearance beyond the displayed node radii. A 48-point approach band adds up to 12 points of gentle give. Eligible confirmed-Group conversation drop targets remain fixed; folder, suggestion, and You layout drags also move neighboring hubs. Linked neighbors respond with bounded elastic give (30% displacement, at most 48 screen points). Only confirmed Groups accept the existing conversation drop operation.
- Open/closed hand cursors, an elevated focus ring, and a visible source label identify the grabbed mark.
- Release preserves the placement and settles the affected neighbors locally. Escape restores the grabbed nodes and the neighbors to their pre-drag positions. Data or force-setting changes can still recompute the layout.
- Reduce Motion applies local corrections directly. This interaction changes BetterMail layout and existing Group membership behavior; it adds no Apple Mail operation.

- Hover cards appear after a 220 ms dwell, stay anchored to the mark, and do not repeat audio on pointer movement. Full titles remain in cards and accessibility; canvas labels truncate at a text-scaled 240-point width.
- Dragging retains surrounding context; focus fades respect Reduce Motion. Pan/zoom publications are coalesced to display frames. Pan rebases after camera motion, and a new gesture takes over an unfinished recenter or settle without a position jump.
- Recenter follows the current You position at 100% zoom, including a root moved outside the original canvas. The toolbar and keyboard command send a one-shot scene request and share the eased, interruptible camera movement used by empty-canvas double-click; Reset Layout keeps its separate spatial-reset behavior.

## Performance design

The scene requests the active display cadence during interaction, capped at 120 FPS, while retaining its lower idle cadence. The default grab threshold is three screen points. Grabbed marks take the latest pointer position immediately; bounded collision and linked-node reactions remain coalesced into display updates. A grid of obstacle origins is built once per gesture; each frame checks only nearby source/candidate pairs and redraws changed nodes and incident edges. Stable projection targets avoid the old nine-point displacement cap and push/return jitter. The full force solver and accessibility geometry refresh stay outside the drag frame loop. Cached per-node incident edges avoid a full edge scan during local movement. Movement does not recreate edge colors or invalidate unchanged styles, and hidden arrows do not regenerate paths. Unchanged SwiftUI configurations and camera-only updates no longer recompute graph geometry.

The optional display benchmark uses a visible native `SKView` with either 500 synthetic email marks or 500 linked folder hubs plus You. After renderer warmup and five initial drag frames, it measures actual SpriteKit update intervals, without manually driving `scene.update`. It asserts mean FPS above 30 and p95 and maximum measured frame intervals below 33.33 ms. It is separate from deterministic unit tests because display scheduling depends on the host.

## Previous verification (2026-09-08, before this change)

Historical focused run: **90 tests passed, zero skipped, zero failures**. Coverage includes all mark eligibility, folder drop acceptance, selection, zoom/size-aware clearance, coincident nodes, reduced motion, cancellation, root restoration, paging activation, spatial integration, and the onscreen benchmark.

| Measurement | Result |
| --- | ---: |
| Displayed graph marks | 501 |
| Measured drag frames | 183 |
| Mean FPS | 58.39 |
| p95 frame interval | 26.680 ms |
| Maximum frame interval | 28.105 ms |
| Global force steps during drag | 0 |
| Fixed 100-conversation pointer workload median | 21.987 ms total |

The display result describes this synthetic SpriteKit scene on this Mac. It does not establish FPS for every mailbox, hardware configuration, or the installed SwiftUI workspace. Initial layout, cold startup, and human usability acceptance are separate checks.

Full build/test output: `/tmp/bettermail-drag-final.HMgwfs`. Result bundle: `/tmp/BetterMailDragValidation/Logs/Test/Test-BetterMail-2026.09.08_08-35-00-+0800.xcresult`.

The normal build was attempted first. It is blocked by the project's unavailable `macosx26.2` SDK pin. Selecting the installed macOS 26.5 SDK exposed existing missing/invalid signing configuration. Compilation and the tests succeeded with a command-line SDK selection and `CODE_SIGNING_ALLOWED=NO` in `/tmp/BetterMailDragValidation`. No project SDK, deployment, signing, entitlement, or bundle identifier settings changed.

`./script/build_and_run.sh --install` was attempted and stopped in preflight: `Config/AppSigning.xcconfig` lacks the required `BETTERMAIL_SIGNING_IDENTITY_SHA1` value. The mandated identity `59D9099E689B4FCF247C0E2C021C3B62E80AE4B2` is also absent from this Mac's signing identities. The installed app was not replaced. Logs: `/tmp/bettermail-drag-build.ltzQf4`, `/tmp/bettermail-drag-build-sdk.8OUOrg`, `/tmp/bettermail-drag-install.ZF5rOf`.

## Current change verification

Xcode 27.0 was installed from the Mac App Store and its developer directory selected. The signed build passed with `-sdk macosx`; the guarded install script now selects the installed SDK too. Explicit `nonisolated` async service protocols preserve actor-based implementations/test doubles with the new compiler, without changing the app's UI actor default, signing configuration, or deployment target.

**104 deterministic focused tests passed**, covering scene interaction, physics, pan rebasing, recentering a moved root, readable labels, cancellation, accessibility, the 120-attempt drop matrix, and spatial persistence integration. **71 service compatibility tests passed**. Both opt-in display scenarios also passed when run separately from Computer Use activity. Final display results on this Mac:

| Scenario | Visible marks | Measured drag frames | Mean FPS | p95 frame | Maximum frame |
| --- | ---: | ---: | ---: | ---: | ---: |
| 500 linked folder hubs + You | 501 | 177 | 57.82 | 20.006 ms | 25.540 ms |
| 500 conversations + You | 501 | 174 | 58.73 | 19.613 ms | 24.075 ms |

Both final scenarios stayed within the measured 33.33 ms frame gate and performed zero global force steps during drag. These are synthetic native SpriteKit measurements, not a guarantee for all mailboxes or hardware. Earlier runs exposed unbounded one-line labels and repeated edge styling. A later run concurrent with Computer Use had one 33.968 ms folder frame; the isolated final display check passed without weakening the frame assertions.

Logs: `/tmp/bettermail-organize-review/focused-recenter.log`, `/tmp/bettermail-organize-review/compatibility.log`, and `/tmp/bettermail-organize-review/display-final.log`. Final display result bundle: `/tmp/BetterMailOrganizeValidation/Logs/Test/Test-BetterMail-2026.09.23_00-10-41-+0800.xcresult`. Source parsing, shell syntax, and whitespace checks passed. A standalone harness using the physics source also passed 221 assertions plus 600 frames with 500 linked folders; that result is physics-only evidence.

The final `./script/build_and_run.sh --install` clean build passed, and the app plus Mail extension passed deep-strict signature checks before and after installation. Installed executables and debug dylibs match the build products by SHA-256. Evidence: `/tmp/bettermail-organize-review/install-build.log`, `install.log`, and `installed-verification.json` in the same directory.

Computer Use verified the final installed `/Users/isaacibm/Applications/BetterMail.app` on 2026-09-23. Dragging a folder from approximately (866, 288) to (940, 304) pushed its neighbor from (966, 310) to (1023, 327), while You remained fixed. Dragging You by (-60, +34) made linked hubs follow by approximately (-14, +8), demonstrating the bounded elastic response. A blank-canvas drag of (+75, -56) moved You by that same screen displacement. Selection showed the complete folder title, blank click cleared selection, zoom changed to 120%, and Recenter returned to 100% with You at the visible canvas center. The legend, advanced controls, collapsible rail, and settings sheet were also opened and closed. The app was left centered with no selection or sheet. Native pointer control initially returned `noWindowsAvailable`; it recovered after the final relaunch and the actual drag checks then succeeded.

Live checks used layout and navigation only; no email move, archive, deletion, or Group-membership mutation was performed. Hover dwell and cancellation timing are covered by deterministic tests. The live check establishes interaction behavior; the separate synthetic display benchmark provides the measured frame timings.

## Reproduce the display check

On a Mac with an active display, run the following verification-only command. It does not install the test build or repair the release/signing configuration.

```sh
TEST_RUNNER_BETTERMAIL_DRAG_DISPLAY_BENCHMARK=1 xcodebuild \
  -project BetterMail.xcodeproj -scheme BetterMail -configuration Debug \
  -sdk macosx -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/BetterMailDragValidation CODE_SIGNING_ALLOWED=NO \
  -only-testing:BetterMailTests/ObsidianGraphMultiDragTests test \
  > /tmp/bettermail-drag-display-check.log 2>&1
```

Omit the environment flag for deterministic tests; the display test then reports a skip. The normal signed build and guarded installation remain required before checking the everyday Raycast/Spotlight bundle.

## API reference

Labels use Apple’s [SKLabelNode preferredMaxLayoutWidth](https://developer.apple.com/documentation/spritekit/sklabelnode/preferredmaxlayoutwidth) as their width target. Because macOS SpriteKit does not enforce that target for a single line, construction measures actual label bounds and shortens the displayed text at grapheme boundaries with an ellipsis. This work stays outside the drag loop; model titles, cards, and accessibility text remain complete.
