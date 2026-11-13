# Testing and release verification

## Automated tests

```bash
swift test
bash ./scripts/build-and-test.sh
```

The release script verifies the app's `CFBundleVersion` and `x86_64` architecture. It requires macOS with Xcode; it cannot be fully executed on Linux.

## Manual smoke tests

- Open the native menu; verify only one menu-bar icon appears.
- Connect to a configured VNC server, confirm Viewer access, Disconnect, then reconnect.
- Check connection status icons for Disconnected, Connecting, Connected, Disconnecting and Error; verify 1-second animations during transitions.
- Check server-menu mouse and keyboard navigation, Settings and the intentionally non-quitting Command-Q behavior.
- Verify explicit Quit closes app-owned Viewer/tunnel only, leaving unrelated viewers untouched.
- With SSH-agent removal OFF, confirm no identity is removed on Quit.
- With removal ON, confirm Disconnect retains registered identities; explicit Quit removes only registered identities used by the app.
- Confirm missing `.pub` files do not prevent Quit if agent membership can be determined; private and public key files must remain unchanged.

## Deferred tests

- Actual SSH-agent failure injection and repeated `Retry Cleanup` with a still-unresolved failure (T10).
- R01–R08 reliability tests: sleep/resume, unexpected tunnel/viewer termination, in-flight cancellation and long-running stability.

Do not run SSH-agent destructive tests against production identities. Use isolated test agents and disposable keys.
