// PanelExpander.swift — the one door through which the shell opens or closes the panel.
//
// Hovering, clicking, Escape and the menu-bar icon all end up here, so there is a single path:
// ask the app (`AppActions.setExpanded`), which lets the app controller react in one place too.
//
// In snapshots, tests and the shell's own harness there is no app controller, only the
// do-nothing `NoopActions`. So after asking, this checks whether the panel state actually
// changed and, if nobody did it, flips `UIState.isExpanded` itself. With the real controller
// the check passes and the second step never runs.

import Foundation

struct PanelExpander {
    let env: AppEnv

    func setExpanded(_ expanded: Bool) {
        guard env.ui.isExpanded != expanded else { return }
        env.actions.setExpanded(expanded)
        if env.ui.isExpanded != expanded {
            env.ui.isExpanded = expanded
        }
    }

    func toggle() {
        setExpanded(!env.ui.isExpanded)
    }
}
