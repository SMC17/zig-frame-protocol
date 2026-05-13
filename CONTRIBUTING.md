# Contributing to zig-frame-protocol

Issues and pull requests welcome. The code surface is intentionally small;
changes that grow it should justify why.

## Ground rules

- **Zero allocation, no hidden heap.** Every function operates on
  caller-provided buffers. Keep it that way.
- **Freestanding-friendly.** No `std.heap`, no thread-local state, no
  filesystem I/O. The library must work in `freestanding` Zig builds.
- **`O(n)` time.** Both encode and decode are single-pass over input.
  Don't introduce algorithms with worse asymptotic behavior.
- **No external dependencies.** Pure `std`-only Zig.
- **No LLM-generated code shipped without human review and editing.**
  AI as research aid is fine; AI-as-final-author is not.

## Testing

```sh
zig fmt --check src/ build.zig
zig build test
```

CI runs the same on every push and pull request. Don't merge unless CI is
green.

New behavior must come with a property-based or boundary-case test that
would fail without the change. See `src/root.zig` test blocks for the
existing pattern.

## Versioning

`zig-frame-protocol` follows [Semantic Versioning](https://semver.org). API changes
require a major version bump; new functionality without breaking changes
is a minor bump; bug fixes are patch.

## Reporting issues

Bug reports should include:
- Zig version (`zig version`)
- A minimal reproduction (input bytes + expected vs actual output)
- Whether your platform uses LLD or self-hosted linker (this matters
  for some edge cases)

## License

By contributing, you agree your contribution is licensed under the same
MIT license as the rest of the project.
