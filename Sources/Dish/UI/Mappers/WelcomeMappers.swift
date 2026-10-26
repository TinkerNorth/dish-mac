// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The first-run welcome, the desktops' four pages: what Dish is, how it
/// reaches the host, Satellite to install there, and the walk Finish opens.
struct WelcomeState: Equatable {
    let page: Int
    let eyebrow: String
    let title: String
    let body: String
    /// The dish mark heads the first page only.
    let showsMark: Bool
    /// The page's one call to action, the Satellite download.
    let download: WelcomeLink?
    let dots: [StepPip]
    /// Nil on the first page.
    let back: String?
    let skip: String
    let primary: String
    /// The page Next turns to; nil on the last, where the primary is Finish.
    let nextPage: Int?
    /// The page Back turns to; nil on the first.
    let previousPage: Int?
}

struct WelcomeLink: Equatable {
    let title: String
    let url: URL?
}

/// The welcome's pages, in order.
enum WelcomePage: Int, CaseIterable {
    case welcome
    case howItWorks
    case oneMoreThing
    case youreSet
}

/// The welcome on `page`, clamped to the four there are.
func welcomeState(page: Int, words: L10n = .app) -> WelcomeState {
    let pages = WelcomePage.allCases
    let index = min(max(page, 0), pages.count - 1)
    let shown = pages[index]
    let last = index == pages.count - 1
    let text = welcomeWords(shown, words: words)
    return WelcomeState(
        page: index,
        eyebrow: text.eyebrow,
        title: text.title,
        body: text.body,
        showsMark: shown == .welcome,
        download: shown == .oneMoreThing ? WelcomeLink(title: words.openDownloadPage, url: URL(string: DishLinks.satellite)) : nil,
        dots: pages.indices.map { StepPip(id: $0, label: nil, phase: welcomeDot($0, current: index)) },
        back: index == 0 ? nil : words.back,
        skip: words.skip,
        primary: last ? words.finish : words.next,
        nextPage: last ? nil : index + 1,
        previousPage: index == 0 ? nil : index - 1
    )
}

private struct WelcomeWords {
    let eyebrow: String
    let title: String
    let body: String
}

private func welcomeWords(_ page: WelcomePage, words: L10n) -> WelcomeWords {
    switch page {
    case .welcome: WelcomeWords(eyebrow: words.welcomeEyebrow, title: words.yourControllerOnYourPc, body: words.welcomeIntro)
    case .howItWorks: WelcomeWords(eyebrow: words.howItWorks, title: words.aShortHopOverWifi, body: words.howItWorksBody)
    case .oneMoreThing: WelcomeWords(
            eyebrow: words.oneMoreThing,
            title: words.installSatelliteOnTheHostPc,
            body: words.installSatelliteBody
        )
    case .youreSet: WelcomeWords(eyebrow: words.youreSet, title: words.readyWhenYouAre, body: words.youreSetBody)
    }
}

/// The dots light the page on screen; the ones before it are passed.
private func welcomeDot(_ index: Int, current: Int) -> StepPipPhase {
    if index == current { return .current }
    return index < current ? .done : .upcoming
}
