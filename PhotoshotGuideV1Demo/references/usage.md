# Usage Guide — xcodebuild-runner Skill

## Quick Start

    # Run one command to stop the previous project build, check the simulator, and build.
    bash .agents/skills/xcodebuild-runner/scripts/xcodebuild.sh

## Detailed Workflow

### Step 1: Stop an old build for the matching project

    bash .agents/skills/xcodebuild-runner/scripts/kill-processes.sh --workspace "$(pwd)/AR-DRAWING.xcworkspace"

Output:

- [STOPPING] Previous build ... (PID 12345) — an old build exists for this project.
- [OK] No previous build ... — no old build exists.

### Step 2: Check the simulator

    bash .agents/skills/xcodebuild-runner/scripts/check-simulator.sh

Output when a simulator is booted:

    [STATUS] BOOTED
    [DEVICE] iPhone 17 (iOS 27.0)
    [UDID] D696F193-FF6D-4D58-BD1E-30CE439EA8D5

Output when no simulator is booted:

    [STATUS] NO_SIMULATOR
    No booted simulator was found.
    Available simulators:
        iPhone 16 Pro (...)
        ...
    Open the Simulator app, boot a device, and try again.

### Step 3: Build

    bash .agents/skills/xcodebuild-runner/scripts/xcodebuild.sh

Successful build output:

    [SCHEME] AR-DRAWING
    [DEVICE] iPhone 17 (iOS 27.0)
    [UDID] D696F193-...
    [OK] No previous build for /path/to/AR-DRAWING.xcworkspace
    [BUILDING]...

    [STATUS] SUCCESS
    [BUILD_TIME] 135s
    [ERRORS] 0
    [WARNINGS] 2

Failed build output:

    [STATUS] FAILED
    [BUILD_TIME] 45s
    [ERRORS] 3
    [WARNINGS] 5

    [ERRORS]
    HomeViewController.swift:142 — cannot find 'foo' in scope
    HomeViewController.swift:200 — type mismatch
    ...

    [HINT] The pre-built framework cache is corrupt.
           Run: rm -rf ~/Library/Developer/Xcode/DerivedData/AR-DRAWING-*
           Then: xcodebuild -resolvePackageDependencies ...

## Output Filtering

The script **EXCLUDES** unnecessary output:

- Pre-built framework errors (corrupt swiftinterface or swiftmodule files).
- Verbose build steps.
- dSYM warnings (build-setting issues).
- Could not read priors warnings.
- Duplicate-file warnings.
- NetConfig or private warnings.
- Firebase-script warnings.

The script **RETAINS**:

- Source-code errors (YourFile.swift:LINE — message).
- Source-code warnings.
- Build-configuration errors, such as a missing scheme.
- Hints for fixing issues, such as cleaning DerivedData.

## Best Practices

### 1. Build before committing

    bash .agents/skills/xcodebuild-runner/scripts/xcodebuild.sh
    # If SUCCESS → commit.
    # If FAILED → fix the errors first.

### 2. Quick debugging

    # Check only the simulator or stop an old build for the project.
    bash .agents/skills/xcodebuild-runner/scripts/check-simulator.sh
    bash .agents/skills/xcodebuild-runner/scripts/kill-processes.sh --workspace "$(pwd)/AR-DRAWING.xcworkspace"

### 3. Clean the build when encountering unusual errors

    rm -rf ~/Library/Developer/Xcode/DerivedData/AR-DRAWING-*
    xcodebuild -resolvePackageDependencies -workspace AR-DRAWING.xcworkspace -scheme AR-DRAWING
    bash .agents/skills/xcodebuild-runner/scripts/xcodebuild.sh

## Troubleshooting

### No scheme found

- The workspace may contain multiple schemes, including Pods and dependencies.
- The script filters common dependency schemes.
- If the main scheme is not AR-DRAWING, update the script.

### Build fails without visible errors

- The pre-built framework cache may be corrupt.
- Run the cleanup commands in the [HINT] section.

### Simulator cannot be detected

- Run xcrun simctl list devices to view available devices.
- Open the Simulator app, boot a device, and try again.

### Build takes too long

- Normal: 5–10 minutes for the first, clean build.
- Afterwards: 1–3 minutes for incremental builds.
- If it exceeds 10 minutes, check Activity Monitor for multiple xcodebuild processes.

## Customization

If the project uses a scheme other than AR-DRAWING:

1. Open scripts/xcodebuild.sh.
2. Update the grep -v -E "(Pods|...)" filter to match the project.
3. Or hardcode SCHEME="YourScheme".

To add output filters:

- Update the patterns in the ERRORS= and WARNINGS= lines.
- Add grep -v "your_pattern" to exclude a pattern.
