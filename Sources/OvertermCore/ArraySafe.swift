extension Array {
    /// The element at `index`, nil past either end.
    package subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
