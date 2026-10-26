// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Open source licenses: the third-party notice the app ships with.
struct LicensesPage: View {

    let state: LicensesPageState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s5) {
                switch state {
                case let .missing(title, body):
                    EmptyStateCard(title: title, message: body)
                case let .notice(blocks, footer):
                    ForEach(blocks) { item in
                        LicenseBlockView(block: item.block)
                    }
                    Text(footer)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.muted)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DishSpace.page)
        }
    }
}

private struct LicenseBlockView: View {
    let block: LicenseBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(licenseHeadingFont(level))
                .foregroundColor(DishTheme.onSurface)
                .padding(.top, DishSpace.s4)
        case let .paragraph(text):
            Text(text)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
        case let .code(text):
            Text(text)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.muted)
                .padding(DishSpace.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DishTheme.surfaceDim)
                .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
        case let .row(cells, header):
            HStack(alignment: .top, spacing: DishSpace.s4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { cell in
                    Text(cell.element)
                        .font(licenseCellFont(header: header))
                        .foregroundColor(licenseCellColor(header: header))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .rule:
            Divider().background(DishTheme.outline)
        }
    }
}
