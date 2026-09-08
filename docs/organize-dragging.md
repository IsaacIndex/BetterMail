# Organize drag interaction

Updated 2026-09-08. The active renderer is `ObsidianGraphScene`.

## Behavior

- Every visible mark is draggable: emails, replies, confirmed Groups, suggestions, You, and paging hubs. Paging hubs still expand on click.
- Email multi-drag preserves relative offsets. Other mark kinds move independently and cannot turn a stale email selection into a merge payload.
- Nearby non-folder nodes make room with 64 screen points of clearance beyond the displayed node radii. Confirmed and suggested folder hubs stay stationary unless grabbed. Only confirmed Groups accept the existing conversation drop operation.
- Open/closed hand cursors, an elevated focus ring, and a visible source label identify the grabbed mark.
- Release preserves the placement and settles the affected neighbors locally. Escape restores the grabbed nodes and the neighbors to their pre-drag positions. Data or force-setting changes can still recompute the layout.
- Reduce Motion applies local corrections directly. This interaction changes BetterMail layout and existing Group membership behavior; it adds no Apple Mail operation.

## Performance design

The scene requests 60 FPS during interaction. Pointer input is coalesced into display updates. A grid of obstacle origins is built once per gesture; each frame checks only nearby source/candidate pairs and redraws changed nodes and incident edges. Stable projection targets avoid the old nine-point displacement cap and push/return jitter. The full force solver and accessibility geometry refresh stay outside the drag frame loop.

The optional display benchmark uses a visible native `SKView` with 500 synthetic email marks plus You. After renderer warmup and five initial drag frames, it measures actual SpriteKit update intervals, without manually driving `scene.update`. It asserts mean FPS above 30 and p95 and maximum measured frame intervals below 33.33 ms. It is separate from deterministic unit tests because display scheduling depends on the host.

## Verification on this Mac

Final focused run: **90 tests passed, zero skipped, zero failures**. Coverage includes all mark eligibility, folder drop acceptance, selection, zoom/size-aware clearance, coincident nodes, reduced motion, cancellation, root restoration, paging activation, spatial integration, and the onscreen benchmark.

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
