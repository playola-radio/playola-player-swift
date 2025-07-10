import Foundation

/// Protocol for providing authentication tokens to PlayolaPlayer
public protocol PlayolaAuthenticationProvider {
    /// Returns the current user's authentication token
    /// - Returns: JWT token string if user is authenticated, nil otherwise
    func getCurrentToken() async -> String?
    
    /// Called when the library receives a 401 response and needs a fresh token
    /// - Returns: Refreshed JWT token string if successful, nil otherwise
    func refreshToken() async -> String?
}

