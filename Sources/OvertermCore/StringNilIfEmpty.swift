extension String {
    /// Itself, or nil when it is empty.
    package var nilIfEmpty: String? { isEmpty ? nil : self }
}
