# Stage 1 storage clarifications

The approved specification is in tefter-v1-specs.md. Space IDs and entity IDs are UUID strings generated independently of paths. Markdown stays UTF-8. Typed Markdown uses the contract’s YAML keys. Directory names do not convey a type.

Within each space, .tefter/entities.json version 1 contains a documents array mapping id, path and revision for identified plain documents. Revision tokens are lowercase SHA-256 of exact file bytes. An unambiguous matching revision can reconcile an externally moved unmodified document. Ambiguous matches require operator reconciliation. Comments use .tefter/comments/ID.json version 1 with a comments array, replaced atomically. View preferences use .tefter/views.json version 1. Operational grants and sessions remain outside the space.
