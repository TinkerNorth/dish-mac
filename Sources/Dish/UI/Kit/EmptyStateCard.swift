// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// What a list says when it has nothing to list: a title and one line, the
/// reason in the warning colour when the system is the cause, and the ways
/// forward when there are any.
struct EmptyStateCard<Actions: View>: View {
    let title: String
    let message: String
    let hint: String?
    let actions: Actions

    init(title: String, message: String, hint: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.hint = hint
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s2) {
            Text(title)
                .font(DishFont.body)
                .foregroundColor(DishTheme.onSurface)
            Text(message)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DishSpace.s4) {
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DishSpace.s6)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: DishSize.cardRadius).stroke(DishTheme.cardStroke, lineWidth: DishSize.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }
}

extension EmptyStateCard where Actions == EmptyView {
    init(title: String, message: String, hint: String? = nil) {
        self.init(title: title, message: message, hint: hint) { EmptyView() }
    }
}
