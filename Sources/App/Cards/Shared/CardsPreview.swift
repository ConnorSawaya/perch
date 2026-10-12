// CardsPreview.swift — a way to show a card part-way through being used.
//
// The app never needs this: cards start fresh and change as the user clicks. Snapshots cannot
// click, so they hand a card one of these to say "draw yourself as if the user had already
// opened the Other field" (and so on). Every field defaults to the fresh state.

import Foundation

struct CardsPreview {
    // Approval card
    /// The "are you sure?" step of a dangerous request is showing.
    var confirmArmed = false
    /// The "Always allow…" list is open.
    var rememberOpen = false

    // Approval and plan cards
    /// The note field is open (deny reason / plan feedback).
    var noteOpen = false
    var noteText = ""

    // Question card
    /// Which question is showing (0 = the first).
    var questionStep = 0
    /// Options already chosen, per question, as positions in that question's option list.
    var questionPicks: [Int: Set<Int>] = [:]
    /// The "Other…" field of the showing question is open.
    var otherOpen = false
    var otherText = ""

    // Activity tab
    /// Positions (0 = newest) of rows drawn expanded.
    var expandedRows: Set<Int> = []
}
