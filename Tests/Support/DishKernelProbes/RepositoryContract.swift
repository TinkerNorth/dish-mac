// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import Foundation

/// The properties every `Repository` must satisfy. A concrete repository's
/// test constructs the contract with two distinct values and a key for each,
/// runs it, and asserts the returned list of violations is empty. The
/// contract carries no XCTest dependency so every test target can share it.
public struct RepositoryContract<Repo: Repository> where Repo.Value: Equatable {
    public let makeEmpty: () -> Repo
    public let keyA: Repo.Key
    public let valueA: Repo.Value
    public let keyB: Repo.Key
    public let valueB: Repo.Value

    public init(
        makeEmpty: @escaping () -> Repo,
        keyA: Repo.Key,
        valueA: Repo.Value,
        keyB: Repo.Key,
        valueB: Repo.Value
    ) {
        self.makeEmpty = makeEmpty
        self.keyA = keyA
        self.valueA = valueA
        self.keyB = keyB
        self.valueB = valueB
    }

    /// Every property that failed, named for the behaviour it pins. Empty
    /// means the repository honours the contract.
    public func violations() -> [String] {
        let checks: [(String, () -> Bool)] = [
            ("a fresh repository is empty", emptyRepositoryHasNothing),
            ("put then get returns the value", putThenGetReturnsTheValue),
            ("put overwrites the same key without adding a row", putOverwritesTheSameKey),
            ("all lists every value", allListsEveryValue),
            ("remove drops only that key", removeDropsOnlyThatKey),
            ("removing an absent key is a no-op", removingAnAbsentKeyIsANoOp),
            ("clear empties everything", clearEmptiesEverything),
            ("a missing key reads nil", aMissingKeyReadsNil)
        ]
        return checks.filter { !$0.1() }.map(\.0)
    }

    func emptyRepositoryHasNothing() -> Bool {
        makeEmpty().all().isEmpty
    }

    func putThenGetReturnsTheValue() -> Bool {
        let repo = makeEmpty()
        repo.put(valueA, for: keyA)
        return repo.get(keyA) == valueA
    }

    func putOverwritesTheSameKey() -> Bool {
        let repo = makeEmpty()
        repo.put(valueA, for: keyA)
        repo.put(valueB, for: keyA)
        let holdsTheNewValue = repo.get(keyA) == valueB
        let holdsOneRow = repo.all().count == 1
        return holdsTheNewValue && holdsOneRow
    }

    func allListsEveryValue() -> Bool {
        let repo = makeEmpty()
        repo.put(valueA, for: keyA)
        repo.put(valueB, for: keyB)
        let listed = repo.all()
        let hasBoth = listed.contains(valueA) && listed.contains(valueB)
        return listed.count == 2 && hasBoth
    }

    func removeDropsOnlyThatKey() -> Bool {
        let repo = makeEmpty()
        repo.put(valueA, for: keyA)
        repo.put(valueB, for: keyB)
        repo.remove(keyA)
        return repo.get(keyA) == nil && repo.get(keyB) == valueB
    }

    func removingAnAbsentKeyIsANoOp() -> Bool {
        let repo = makeEmpty()
        repo.put(valueB, for: keyB)
        repo.remove(keyA)
        return repo.all().count == 1
    }

    func clearEmptiesEverything() -> Bool {
        let repo = makeEmpty()
        repo.put(valueA, for: keyA)
        repo.put(valueB, for: keyB)
        repo.clear()
        return repo.all().isEmpty && repo.get(keyA) == nil
    }

    func aMissingKeyReadsNil() -> Bool {
        makeEmpty().get(keyA) == nil
    }
}
