# Superseded: Manifest Domain Contracts and Script IDL

This July 30, 2026 planning record is superseded by
`docs/maintenance/shell-qualified-script-variants-2026-08-03.md`.

The active architecture keeps the manifest editor, normalized JSON contracts,
revision checks, atomic writes, and Ballad semantic integration. Project
scripts are intentionally smaller: `[scripts] name = "opaque command"`.
Moonstone projects the resolved environment and the host shell interprets the
command. Scripts are not represented in `moonstone.lock`.
