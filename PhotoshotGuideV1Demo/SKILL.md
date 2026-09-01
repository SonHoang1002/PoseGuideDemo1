---
name: xcodebuild-runner
description: Run iOS simulator builds and XCTest suites with a shared cache, one active xcodebuild job, and concise diagnostics.
---

# xcodebuild-runner Skill

Run builds and XCTest suites for an iOS Simulator without verbose `xcodebuild` logs.

## When to use

- The user asks to build, compile, test, or check an iOS app for errors.
- You need to verify Swift compilation or XCTest results before committing.

## When NOT to use

- Physical-device testing, App Store archives, or TestFlight uploads.

## Workflow

Build:

```bash
bash scripts/xcodebuild.sh --scheme Carbina
```

Test all bundles configured by a scheme:

```bash
bash scripts/xcodebuild-test.sh --scheme Carbina
```

Run a smaller scope while investigating:

```bash
bash scripts/xcodebuild-test.sh --scheme Carbina \
  --only-testing CarbinaTests/AppShellTests
```

Both commands share `.build-cli`; no `.test-cli` cache is created. They acquire the same temporary lock before invoking `xcodebuild`. If another build or test is active for the project, the new command exits with `[STATUS] BUSY` instead of competing for the cache or terminating the active job.

Pass `--scheme` whenever the app scheme is known. Auto-detection prefers the project-named app scheme.

### Test timeout

Tests run serially on one simulator destination and default to a five-minute timeout. Use `--timeout SECONDS` only for a known long-running suite. A timed-out run is stopped and returns `[STATUS] TIMEOUT`.

### Find the scheme when it is unknown

```bash
# Workspace
xcodebuild -workspace <workspace>.xcworkspace -list -json | python3 -m json.tool

# Project (without a workspace)
xcodebuild -project <project>.xcodeproj -list -json | python3 -m json.tool
```

Choose the app scheme, not a Pods, widget, dependency, or test-only scheme.

## Scripts (internal)

| Script | Type | Purpose |
|--------|------|---------|
| `scripts/xcodebuild.sh` | **Main** | Builds and filters output. |
| `scripts/xcodebuild-test.sh` | **Main** | Runs XCTest and prints concise failures. |
| `scripts/run-lock.sh` | Internal helper | Coordinates the shared cache so only one build/test runs. |
| `scripts/kill-processes.sh` | Internal helper | Stops an orphaned `xcodebuild` process for the same project only. |
| `scripts/check-simulator.sh` | Internal helper | Checks for a booted simulator. |

> ⚠️ Invoke only the two main scripts; the helpers are managed automatically.

## Output format

The script returns JSON-like output for easy parsing:

```
[STATUS] SUCCESS | FAILED | BUSY | CACHE_CORRUPT | NO_SIMULATOR
[SCHEME] Carbina
[DESTINATION] iPhone 17 (iOS 27.0)
[ERRORS] 3
[WARNINGS] 12
[BUILD_TIME] 135s

[ERRORS]
1. HomeViewController.swift:142 — cannot find 'foo' in scope
2. ...
```

For tests, the summary also includes `[TESTS]`, `[FAILURES]`, and `[TEST_TIME]`; failed assertions appear under `[TEST_FAILURES]`. Warning lines are counted but not dumped.

Do not dump:

- **Warning lists** (only the count is shown) to avoid noise.
- Pre-built framework errors, which are often caused by a corrupt cache rather than application code.
- Verbose build steps.
- dSYM warnings, which are typically unimportant build-setting issues.
- Dependency-resolution logs.

## Bypass the cache when needed

If the build fails because of a corrupt pre-built framework, the script prints a `[HINT]` with cleanup commands. You can also run:

```bash
# Automatically derive the project basename by removing the .xcworkspace or .xcodeproj extension.
PROJECT=$(basename *.xcworkspace *.xcodeproj 2>/dev/null | head -1 | cut -d. -f1)
xcodebuild -resolvePackageDependencies -workspace *.xcworkspace -scheme <YourScheme>
rm -rf ~/Library/Developer/Xcode/DerivedData/${PROJECT}-*
```

## Anti-patterns

❌ Do not run unfiltered `xcodebuild build`; it produces 1,000+ lines of output.
❌ Do not dump all warnings; retain only what is relevant.
❌ Do not globally kill `clang`, `swift-frontend`, `ld`, or processes from another project.
❌ Do not assume a simulator is available; always check.

## Examples

### Build

```bash
bash scripts/xcodebuild.sh --scheme Carbina
# Output: SUCCESS, 0 errors, 4 warnings
```

### Test a class

```bash
bash scripts/xcodebuild-test.sh --scheme Carbina --only-testing CarbinaTests/AppShellTests
# Output: SUCCESS, 24 tests, 0 failures
```

### Test failures

```bash
./scripts/xcodebuild-test.sh --scheme Carbina
# Output: FAILED with XCTest assertion failures only
```

### Another project

```bash
cd /path/to/other/ios-project
bash /path/to/xcodebuild-runner/scripts/xcodebuild-test.sh --scheme OtherApp
```

## Integration with other skills

- When a build or test fails, inspect the reported source errors or assertions before changing the cache.

## Notes

- Scripts assume `pwd` is the iOS project root.
- `.build-cli/` is the only CLI DerivedData cache; ignore it in version control when appropriate.
- A booted simulator is required. Its ID may change after it is reset.
