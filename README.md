# Astroberry VNC

A native macOS menu-bar application that opens [TigerVNC Viewer](https://tigervnc.org/) through an SSH tunnel to a remote VNC server (for example, a Raspberry Pi running TigerVNC). The VNC server can remain bound to the remote loopback interface rather than exposed to the network.

**Version:** 1.0.0 (`v1.0.0`) · **Initial public source release** · Based on the internally tested Build 31.9.5.2.

## Requirements

- Intel Mac (`x86_64`) with macOS 15 or later.
- Xcode and Swift (Swift Package Manager) to build from source.
- TigerVNC Viewer installed on the Mac.
- SSH access to the remote server and a running VNC server configured for loopback-only access.
- OpenSSH utilities available on macOS. The application uses the system's SSH tools.

This project builds an **unsigned application**. It is not an Apple-notarized binary release and has not been tested on Apple Silicon.

## Astroberry OS compatibility

[Astroberry OS](https://astroberry.io/) is a free and open-source astronomy operating system for Raspberry Pi, with tools including KStars, Ekos and INDI. **Astroberry VNC is designed to be useful with Astroberry OS installations**, allowing a Mac to reach a Raspberry Pi's graphical desktop over an SSH tunnel, provided that SSH access and a compatible TigerVNC server endpoint have been configured.

The connection method is based on SSH and VNC rather than an Astroberry-specific API. It may also be used with other Linux systems that meet the same requirements. Astroberry OS versions and VNC configurations differ; this application does not automatically configure Astroberry OS or guarantee compatibility with every release. In particular, configure the remote VNC endpoint and SSH port to match your installation; do not assume that a browser-based remote desktop and a standalone TigerVNC server use the same port or session.

For official installation and remote desktop information, see the [Astroberry website](https://astroberry.io/), its [features](https://astroberry.io/features/) and [VNC connection guide](https://astroberry.io/how-to-connect-with-vnc/).

**Independent project:** Astroberry VNC is an unofficial, independently developed macOS client. It is not developed, endorsed or supported by the Astroberry Project.

## Features

- Native menu-bar controls for Connect, Disconnect, server selection, Settings and explicit Quit.
- Five status icons (Disconnected, Connecting, Connected, Disconnecting, Error). Connecting and Disconnecting animate using Core Animation at 1 second per rotation.
- Multiple SSH/VNC server profiles; SSH key-pair generation and public-key registration workflow.
- SSH host key verification and local-loopback SSH tunneling to a remote loopback-only VNC listener.
- Detects and cleans up application-owned SSH tunnel and viewer processes.
- Optional removal of *used, currently registered* keys from `ssh-agent` on explicit app Quit; default OFF. The key files are never deleted by that feature. A missing `.pub` does not itself make Quit fail.
- Settings persistence, launch-at-login option and macOS keyboard navigation.

**Important:** TigerVNC is a separate application, not bundled into this repository. Follow your server's security guidelines; do not expose an unauthenticated VNC port to a network. The connection is intended to be protected by SSH.

## Build and test

From the repository root on an Intel Mac with Xcode installed:

```bash
swift test
bash ./scripts/build-and-test.sh
```

The second command runs the SwiftPM tests, then builds and checks an unsigned Intel Release app. Its output location is:

```text
.build/Build1DerivedData/Build/Products/Release/Astroberry VNC.app
```

Launch your built app using:

```bash
open ".build/Build1DerivedData/Build/Products/Release/Astroberry VNC.app"
```

For Xcode development, open `AstroberryVNC.xcodeproj` and choose the `AstroberryVNC` scheme. A separate **Visual Check** scheme provides UI development fixtures.

The build script does **not** install the application or replace an existing copy. Quit any older Astroberry VNC instance before launching the new one.

## Initial setup

1. Install TigerVNC Viewer on macOS and configure the remote server for loopback-only VNC access.
2. Open the Astroberry VNC menu-bar icon, choose **Settings**, and add a server with its SSH host, user, SSH port, and VNC endpoint.
3. Select an SSH private key or use the built-in key creation and public-key registration flow.
4. Verify the SSH host-key fingerprint by an independent trusted channel before approving it.
5. Select the server and choose **Connect**.
6. Choose **Disconnect** to close the application-owned tunnel and Viewer. Choose **Quit Astroberry VNC** for explicit application shutdown.

The optional SSH-agent key removal is in Settings. It applies only on explicit menu Quit, not Disconnect or the special Command-Q behavior.

## Security notes

- SSH host-key verification is enforced; do not bypass it to troubleshoot connections.
- The local forwarding listener binds to `127.0.0.1` and the remote VNC listener must be loopback-only.
- The application does not bundle private keys, passwords or user connection profiles.
- Do not commit SSH keys, signing certificates, local logs, `.build/`, or Xcode DerivedData.
- Because a key may be shared with other tools, enabling agent key removal can affect other sessions using the same registered identity.
- Unnotarized unsigned software may be restricted by Gatekeeper. Do not disable macOS security protections globally.

## Verification and limitations

This initial release source is based on Build 31.9.5.2, whose basic and key-cleanup behavior was tested on an Intel Mac. Long-duration, suspend/resume and failure-injection tests remain open; the revised `Retry Cleanup` behavior has not been fully retested against actual agent failure.

For the development/build test workflow, see [docs/TESTING.md](docs/TESTING.md).

## Acknowledgements

Special thanks to the [Astroberry Project](https://astroberry.io/), its founder **Radek Kaczorek**, and the contributors and community who make astronomy software accessible on Raspberry Pi. Their work on Astroberry OS and its integration of astronomy tools helped make this kind of remote observing workflow practical.

Thanks also to the open-source teams behind [TigerVNC](https://tigervnc.org/), [KStars/Ekos](https://kstars.kde.org/) and [INDI](https://indilib.org/). These are independent projects; Astroberry VNC does not bundle or claim ownership of their software.

## License

Copyright © 2026 Satoshi Masuko.

Licensed under the **GNU General Public License version 2 or (at your option) any later version**, SPDX identifier [`GPL-2.0-or-later`](https://spdx.org/licenses/GPL-2.0-or-later.html). See [LICENSE](LICENSE).

This is a source-license declaration for the project copyright holder's original work. Contributors must have rights to license their changes compatibly, and any third-party code and assets must retain their applicable notices.
