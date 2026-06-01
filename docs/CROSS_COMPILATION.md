# Plan: Cross-Compilation Polish

## Objective
Ensure that Moonstone can reliably compile Lua C modules for any target architecture supported by Zig, regardless of the host platform.

## 1. Native Build Environment refinement
- **Zig CC Integration**: Finalize the passing of target-specific flags (`-target`, `-mcpu`) from Moonstone's global configuration to the `native-cmodule` materializer.
- **Sysroot Management**: Allow users to specify custom sysroots in `config.toml` for targets that require specialized headers/libraries (e.g., older glibc versions).

## 2. CMake Materializer Expansion
- **Target Injection**: Automatically inject `CMAKE_SYSTEM_NAME` and `CMAKE_C_COMPILER` (pointing to `zig cc`) when a cross-compilation target is active.
- **Toolchain Generation**: Generate a temporary CMake toolchain file on-the-fly to ensure consistent results across various project structures.

## 3. Runtime ABI Verification
- **Cross-ABI Compatibility**: Verify that headers from a cross-compiled Lua runtime are correctly used when building native modules for that same target.
- **Static vs Shared**: Support both static and shared linking of the Lua library during the cross-compilation phase.

## 4. Test Matrix
Implement synthetic tests that build a C module on macOS for:
- Linux x86_64 (musl)
- Linux aarch64 (gnu)
- Windows x86_64 (msvc/gnu)
- FreeBSD x86_64

## Verification
- Use `file` or `readelf` on produced artifacts to verify the target architecture and ABI.
- Run the produced binaries in a QEMU or Docker-based emulator environment.
