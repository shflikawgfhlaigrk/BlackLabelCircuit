//
//  DeveloperMachine.swift
//  leanring-buddy
//
//  Debug-only behaviors (the RUN_DEMO / RUN_SAY / RUN_NOTES flag files, local
//  model CLIs, and developer launch narration) must never fire in a release.
//  A folder name on the buyer's Mac is not an authority boundary. Only Xcode's
//  DEBUG build configuration may admit developer-only behavior.
//

import Foundation

nonisolated enum DeveloperMachine {
    /// Release archives are always self-contained clients of Ace's hosted brain.
    /// Local CLIs remain available only to an explicitly built Debug app.
    static var isDeveloperMachine: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
