# Moonstone documentation

Use this directory by reader intent:

- **Architecture:** [`ARCHITECTURE.md`](ARCHITECTURE.md), [`REGISTRY_MODEL.md`](REGISTRY_MODEL.md)
- **User/reference:** [`USAGE.md`](USAGE.md), [`PROJECT_ENVIRONMENT.md`](PROJECT_ENVIRONMENT.md), [`PLATFORMS.md`](PLATFORMS.md), [`GLOSSARY.md`](GLOSSARY.md)
- **Automation/protocols:** [`CLI_NDJSON_PROTOCOL.md`](CLI_NDJSON_PROTOCOL.md)
- **Release notes:** [`releases/`](releases/) — [0.7.0](releases/0.7.0.md) (complete CLI consolidation and corrected publication), [0.6.0](releases/0.6.0.md) (Lua flavors)
- **Examples:** [`../examples/`](../examples/)
- **Maintenance and design history:** [`maintenance/`](maintenance/)

The root README is the short first-success path. Keep detailed contracts here;
avoid duplicating them in package registry READMEs. Maintenance notes are not
normative until their conclusions are incorporated into a stable document.

Current design review: [CLI UX north and command audit](maintenance/CLI_UX_NORTH.md).

Command scope and shell primitives: [Choosing the right command](CLI_WORKFLOWS.md).
