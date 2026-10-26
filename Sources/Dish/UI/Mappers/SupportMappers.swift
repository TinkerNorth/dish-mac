// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// One way to give, as its row shows it.
struct DonationOption: Equatable, Identifiable {
    let name: String
    /// What the service is.
    let blurb: String
    let cadence: String
    let paysWith: String
    let url: URL?
    let recommended: Bool

    var id: String {
        name
    }
}

struct SupportPageState: Equatable {
    let eyebrow: String
    let headline: String
    let callToAction: String
    let callToActionURL: URL?
    let callToActionNote: String
    let thanks: String
    let recommendedLabel: String
    let cadenceLabel: String
    let paysWithLabel: String
    let options: [DonationOption]
}

/// The desktops' Donate page: GitHub Sponsors first and recommended, then
/// Ko-fi and Buy Me a Coffee.
func supportPageState(words: L10n = .app) -> SupportPageState {
    SupportPageState(
        eyebrow: words.supportTheProject,
        headline: words.coffeeAndGoodwill,
        callToAction: words.sponsorOnGitHubSponsors,
        callToActionURL: URL(string: DishLinks.sponsors),
        callToActionNote: words.sponsorsRecommendedNote,
        thanks: words.thankYouEmir,
        recommendedLabel: words.recommended,
        cadenceLabel: words.cadence,
        paysWithLabel: words.paysWith,
        options: donationOptions(words: words)
    )
}

private func donationOptions(words: L10n) -> [DonationOption] {
    [
        DonationOption(
            name: words.gitHubSponsors,
            blurb: words.sponsorsRecommendedNote,
            cadence: words.recurring,
            paysWith: words.sponsorsPaysWith,
            url: URL(string: DishLinks.sponsors),
            recommended: true
        ),
        DonationOption(
            name: words.koFi,
            blurb: words.koFiBlurb,
            cadence: words.oneTime,
            paysWith: words.koFiPaysWith,
            url: URL(string: DishLinks.koFi),
            recommended: false
        ),
        DonationOption(
            name: words.buyMeACoffee,
            blurb: words.buyMeACoffeeBlurb,
            cadence: words.either,
            paysWith: words.buyMeACoffeePaysWith,
            url: URL(string: DishLinks.buyMeACoffee),
            recommended: false
        )
    ]
}
