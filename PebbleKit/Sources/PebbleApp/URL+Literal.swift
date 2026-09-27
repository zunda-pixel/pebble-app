import Foundation

extension URL {
    /// A URL written into the source. `URL(string:)` is failable for what
    /// arrives at run time; a literal that does not parse is a typo, and this
    /// names it where it was made instead of trapping at a `!`.
    init(literal: StaticString) {
        guard let url = URL(string: "\(literal)") else {
            preconditionFailure("Not a URL: \(literal)")
        }
        self = url
    }
}
