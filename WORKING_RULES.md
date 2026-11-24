# RemVibe Archive — working rules

- Own archive creation, validation and extraction only. Do not add filesystem-manager, transfer orchestration, network, UI, installer, update or service lifecycle responsibilities.
- NTA V2 format and established validation/extraction contracts are authoritative. Preserve existing Dart reader/writer and C++ reader. Do not invent another format or silently weaken critical metadata, path, limit, integrity or staging rules.
- New Rust core must be directly consumable as a Cargo library without Dart, Flutter or FFI dependencies, and suitable for static linkage. Keep progress/cancellation and resource ownership explicit; no duplicated application logic.
- Implement only approved checkpoints; request approval for new dependencies or scope expansion. No unrelated refactor, CI, hardening or extra worktrees. Use direct repository work; preserve unrelated changes.
- Distinguish source review, compilation, focused tests and real runtime acceptance. Never report an unrun check as passed. Windows and Linux are initial runtime acceptance platforms; design for macOS without claiming its acceptance. No screenshot/computer-use acceptance. Update continuity before moving to another checkpoint. Explicit merge approval is required.
