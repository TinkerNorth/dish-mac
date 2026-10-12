// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import DishKernelProbes
import XCTest

private struct Row: Equatable {
    let id: String
    let name: String
}

private final class RowRepository: KeyedRepository {
    private let backing = InMemoryRepository<String, Row>()

    func keyOf(_ value: Row) -> String {
        value.id
    }

    func get(_ key: String) -> Row? {
        backing.get(key)
    }

    func all() -> [Row] {
        backing.all()
    }

    func put(_ value: Row, for key: String) {
        backing.put(value, for: key)
    }

    func remove(_ key: String) {
        backing.remove(key)
    }

    func clear() {
        backing.clear()
    }
}

final class InMemoryRepositoryTests: XCTestCase {

    func testHonoursTheRepositoryContract() {
        let contract = RepositoryContract(
            makeEmpty: { InMemoryRepository<String, Int>() },
            keyA: "a",
            valueA: 1,
            keyB: "b",
            valueB: 2
        )
        XCTAssertEqual(contract.violations(), [])
    }

    func testAKeyedRepositoryStoresUnderTheValuesOwnKey() {
        let repo = RowRepository()
        repo.put(Row(id: "r1", name: "one"))
        XCTAssertEqual(repo.get("r1"), Row(id: "r1", name: "one"))
    }

    func testAKeyedRepositoryRemovesByValue() {
        let repo = RowRepository()
        repo.put(Row(id: "r1", name: "one"))
        repo.removeValue(Row(id: "r1", name: "one"))
        XCTAssertNil(repo.get("r1"))
    }

    func testTheContractReportsAViolationByName() {
        let contract = RepositoryContract(
            makeEmpty: { ForgetfulRepository() },
            keyA: "a",
            valueA: 1,
            keyB: "b",
            valueB: 2
        )
        XCTAssertTrue(contract.violations().contains("put then get returns the value"))
    }
}

/// A repository that drops every write, to prove the contract bites.
private final class ForgetfulRepository: Repository {
    func get(_ key: String) -> Int? {
        nil
    }

    func all() -> [Int] {
        []
    }

    func put(_ value: Int, for key: String) {}

    func remove(_ key: String) {}

    func clear() {}
}
