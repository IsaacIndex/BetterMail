# MailKit Helper Summary

`MailHelperExtension` ships MailKit handlers that demonstrate extension hooks.
These are currently sample implementations and may evolve into automation tie-ins.

## Handlers

- `MailExtension`: entry point that provides handlers to Mail.
- `ContentBlocker`: loads `ContentBlockerRules.json` for content blocking.
- `MessageActionHandler`: example action rule (currently highlights subjects containing "Mars").
- `ComposeSessionHandler`: example compose annotations and headers.
- `MessageSecurityHandler`: placeholder hooks for signing/encryption.
- `ComposeSessionViewController` / `MessageSecurityViewController`: view controllers for extension UI.

## Notes

- MailKit protocol method names must remain unchanged.
- If production logic is added, update this document with the new responsibilities.
