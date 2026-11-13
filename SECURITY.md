# Security policy

This is a small community source project. Please avoid posting private SSH keys, passwords, complete SSH logs with sensitive hosts, or credentials in public GitHub issues.

If you find a potential security vulnerability, contact the maintainer privately using a contact method they have chosen to publish. No dedicated security response SLA is currently offered.

Security expectations:
- Host-key verification must not be bypassed.
- VNC must remain loopback-only and be transported over SSH.
- No unrelated Viewer/SSH process should be terminated.
- Key files must not be deleted by SSH-agent cleanup.
