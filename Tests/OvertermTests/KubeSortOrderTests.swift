import XCTest

@testable import Overterm
@testable import OvertermKubernetes

/// Kubernetes' own copy of the list's order sorts as `ResourceSort.sorted`
/// does: the same keys either way, ties and missing keys in the order they came.
final class KubeSortOrderTests: XCTestCase {
    func testSameOrderAsResourceSort() {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<50 {
            let rows: [(id: Int, number: Double?, text: String?)] = (0..<200).map { id in
                (
                    id,
                    Int.random(in: 0..<5, using: &generator) == 0 ? nil : Double(Int.random(in: 0..<20, using: &generator)),
                    Int.random(in: 0..<5, using: &generator) == 0 ? nil : String(Int.random(in: 0..<20, using: &generator))
                )
            }
            for ascending in [true, false] {
                let sort = ResourceSort(column: "c", ascending: ascending)
                XCTAssertEqual(
                    KubeSortOrder.sorted(rows, sort) { $0.number }.map(\.id), sort.sorted(rows) { $0.number }.map(\.id),
                    "numbers, round \(round), ascending \(ascending)")
                XCTAssertEqual(
                    KubeSortOrder.sorted(rows, sort) { $0.text }.map(\.id), sort.sorted(rows) { $0.text }.map(\.id),
                    "text, round \(round), ascending \(ascending)")
            }
        }
    }

    func testMissingKeysLastEitherWay() {
        let rows: [(id: Int, key: Int?)] = [(0, nil), (1, 3), (2, 1), (3, nil), (4, 3)]
        XCTAssertEqual(KubeSortOrder.sorted(rows, ResourceSort(column: "c")) { $0.key }.map(\.id), [2, 1, 4, 0, 3])
        XCTAssertEqual(KubeSortOrder.sorted(rows, ResourceSort(column: "c", ascending: false)) { $0.key }.map(\.id), [1, 4, 2, 0, 3])
    }
}
