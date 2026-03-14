import Foundation

/// Trust verification status for a .vibeapp package.
enum TrustStatus: String, Codable {
    case unsigned
    case signed
    case verified
    case tampered
}
