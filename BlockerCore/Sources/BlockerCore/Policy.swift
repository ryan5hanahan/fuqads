import Foundation
import PublicSuffixList

/// Per-site blocking state (SPEC §4.2).
public enum SiteState: String, Codable, CaseIterable, Sendable {
    /// Nothing blocked: allowlisted in the content blockers, no dNR rules.
    case trusted
    /// Ads/trackers blocked; scripts allowed.
    case `default`
    /// Default + third-party scripts/frames/websockets blocked via dNR,
    /// except `allowOrigins`.
    case strict
    /// Strict + first-party scripts and (if dNR modifyHeaders is available)
    /// inline scripts via CSP.
    case untrusted
}

/// Global fallback for sites with no explicit policy (FR-15).
public enum GlobalDefaultState: String, Codable, Sendable {
    case `default`
    case strict
}

/// Policy for one eTLD+1 (SPEC §6 `sites`).
public struct SitePolicy: Codable, Sendable, Equatable {
    public var state: SiteState
    /// Origins the user explicitly allowed under Strict (FR-13).
    public var allowOrigins: [String]

    public init(state: SiteState, allowOrigins: [String] = []) {
        self.state = state
        self.allowOrigins = allowOrigins
    }
}

/// eTLD+1 for a hostname (policy keys, FR-10). `nil` for invalid hosts
/// (IPs, localhost): callers treat those as unkeyable and fall back to
/// the raw host.
public func eTLDPlusOne(_ host: String) -> String? {
    let lowered = host.lowercased()
    guard let hostName = lowered.components(separatedBy: ":").first, !hostName.isEmpty else {
        return nil
    }
    // Loopback and pure IPv4 have no public suffix.
    if !hostName.contains(".") {
        return nil
    }
    if hostName.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) {
        return nil
    }
    return PublicSuffixList.effectiveTLDPlusOne(hostName) ?? hostName
}
