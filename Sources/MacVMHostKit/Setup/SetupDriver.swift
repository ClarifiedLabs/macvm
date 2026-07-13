import Foundation

/// Strategy for getting a fresh guest from first boot to a logged-in desktop with
/// the setup account created. The VNC path drives Setup Assistant; the native
/// path waits for Virtualization.framework provisioning and logs in if needed.
protocol SetupDriver {
    func reachLoggedInDesktop(progress: VMOperationHandler?) async throws
}

/// Drives Setup Assistant over VNC by running an OCR-anchored step flow.
struct VNCSetupDriver: SetupDriver {
    let runner: SetupStepRunner
    let steps: [SetupStep]

    func reachLoggedInDesktop(progress: VMOperationHandler?) async throws {
        if await runner.visibleScreen(.desktop, timeout: 8) != nil {
            progress?(.status("Finder is already visible; skipping Setup Assistant driving."))
            return
        }

        if let loginStep = steps.first(where: { $0.action == .type && ($0.whenText ?? "").contains("Enter Password") }),
           let loginText = loginStep.whenText,
           await runner.visibleText(loginText, timeout: 8) != nil {
            progress?(.status("Login window is already visible; logging in before provisioning."))
            var resumeRunner = runner
            resumeRunner.phases = []
            var resumeSteps: [SetupStep] = []
            if let focusStep = steps.first(where: {
                $0.action == .clickTextWhenText && $0.whenText == loginText && ($0.text ?? "").contains("Password")
            }) {
                resumeSteps.append(focusStep)
            }
            resumeSteps.append(loginStep)
            if let returnStep = steps.first(where: {
                $0.action == .keys && $0.keys == ["return"] && $0.whenText == loginText
            }) {
                resumeSteps.append(returnStep)
            }
            resumeSteps += [
                .delay(8),
                .advanceUntilText("Finder", timeout: 240),
            ]
            try await resumeRunner.run(resumeSteps)
            return
        }

        progress?(.status("Driving Setup Assistant (\(steps.count) steps)"))
        try await runner.run(steps)
    }
}

/// Native guest provisioning advances Setup Assistant without host input. Wait
/// passively for its handoff to the login window or Finder, then reuse the VNC
/// driver's verified login recovery for `--no-auto-login`.
struct NativeGuestProvisioningSetupDriver: SetupDriver {
    let runner: SetupStepRunner
    let loginSteps: [SetupStep]
    var timeout: TimeInterval = 360

    func reachLoggedInDesktop(progress: VMOperationHandler?) async throws {
        progress?(.status("Native provisioning: waiting for the login window or desktop"))
        guard await runner.visibleScreen(.loginWindowOrDesktop, timeout: timeout) != nil else {
            throw MacVMError.message(
                "Native guest provisioning did not reach the login window or desktop within \(Int(timeout)) seconds."
            )
        }
        try await VNCSetupDriver(runner: runner, steps: loginSteps)
            .reachLoggedInDesktop(progress: progress)
    }
}
