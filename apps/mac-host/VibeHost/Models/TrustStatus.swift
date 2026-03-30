import Foundation

/// Trust verification status for a .vibeapp package.
enum TrustStatus: String, Codable {
    /// No signature present. Intended for local development.
    case unsigned
    /// Valid signature from a publisher key the user has not yet trusted (TOFU prompt needed).
    case newPublisher
    /// Valid signature from a publisher key the user has explicitly trusted (TOFU).
    case trustedByUser
    /// Valid signature from the Vibe root key embedded in the app bundle.
    case verified
    /// Signature present but verification failed, or file digests do not match.
    case tampered
}
