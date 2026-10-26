// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Help & FAQ, the desktops' HelpScreen: a way into setup, the questions in
/// four sections, and the two links.
struct HelpPageState: Equatable {
    let walkThrough: String
    let sections: [HelpSectionState]
    let linksTitle: String
    let links: [HelpLinkState]
}

struct HelpSectionState: Equatable, Identifiable {
    let title: String
    let entries: [HelpEntryState]

    var id: String {
        title
    }
}

/// One question, folded until it is opened.
struct HelpEntryState: Equatable, Identifiable {
    let question: String
    let answer: String

    var id: String {
        question
    }
}

struct HelpLinkState: Equatable, Identifiable {
    let title: String
    let url: URL?

    var id: String {
        title
    }
}

func helpPageState(words: L10n = .app) -> HelpPageState {
    HelpPageState(
        walkThrough: words.walkMeThroughSetup,
        sections: [concepts(words), bestPerformance(words), troubleshooting(words), aboutDish(words)],
        linksTitle: words.linksSection,
        links: [
            HelpLinkState(title: words.privacyPolicy, url: URL(string: DishLinks.privacy)),
            HelpLinkState(title: words.viewSourceOnGithub, url: URL(string: DishLinks.github))
        ]
    )
}

private func concepts(_ words: L10n) -> HelpSectionState {
    HelpSectionState(title: words.conceptsSection, entries: [
        HelpEntryState(question: words.whatIsDish, answer: words.whatIsDishAnswer),
        HelpEntryState(question: words.whatIsSatellite, answer: words.whatIsSatelliteAnswer),
        HelpEntryState(question: words.whatsMotionAndTheTouchpad, answer: words.whatsMotionAnswer)
    ])
}

private func bestPerformance(_ words: L10n) -> HelpSectionState {
    HelpSectionState(title: words.bestPerformanceSection, entries: [
        HelpEntryState(question: words.bestSetupForLowLatency, answer: words.bestSetupAnswer),
        HelpEntryState(question: words.isWiredBetter, answer: words.isWiredBetterAnswer)
    ])
}

private func troubleshooting(_ words: L10n) -> HelpSectionState {
    HelpSectionState(title: words.troubleshootingSection, entries: [
        HelpEntryState(question: words.cantFindSatellites, answer: words.cantFindSatellitesAnswer),
        HelpEntryState(question: words.pinKeepsGettingRejected, answer: words.pinRejectedAnswer),
        HelpEntryState(question: words.keepsDisconnecting, answer: words.keepsDisconnectingAnswer),
        HelpEntryState(question: words.motionIsntWorking, answer: words.motionIsntWorkingAnswer)
    ])
}

private func aboutDish(_ words: L10n) -> HelpSectionState {
    HelpSectionState(title: words.aboutDishSection, entries: [
        HelpEntryState(question: words.isDishOpenSource, answer: words.isDishOpenSourceAnswer),
        HelpEntryState(question: words.whatDoesDishCollect, answer: words.whatDoesDishCollectAnswer)
    ])
}
