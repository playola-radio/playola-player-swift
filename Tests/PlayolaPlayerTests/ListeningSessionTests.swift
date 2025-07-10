//  ListeningSessionTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 2/13/25.
//

import Testing
import Foundation
@testable import PlayolaPlayer

// Mock auth provider for testing
class MockAuthProvider: PlayolaAuthenticationProvider {
    var currentToken: String?
    var refreshedToken: String?
    var refreshCallCount = 0
    
    init(currentToken: String? = nil, refreshedToken: String? = nil) {
        self.currentToken = currentToken
        self.refreshedToken = refreshedToken
    }
    
    func getCurrentToken() async -> String? {
        return currentToken
    }
    
    func refreshToken() async -> String? {
        refreshCallCount += 1
        return refreshedToken
    }
}

// Mock URLSession for testing
class MockURLSession: URLSessionProtocol {
    var responses: [(Data, URLResponse)] = []
    var requestCallCount = 0
    
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCallCount += 1
        
        if responses.isEmpty {
            // Default successful response
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
        
        // Return the first response and remove it (FIFO)
        return responses.removeFirst()
    }
    
    func addResponse(data: Data = Data(), statusCode: Int, url: URL? = nil) {
        let response = HTTPURLResponse(
            url: url ?? URL(string: "https://test.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        responses.append((data, response))
    }
}

@MainActor
struct ListeningSessionTests {
    
    @Suite("HTTP Request Authorization Headers")
    struct RequestHeaders {
        @Test("Uses Bearer token when auth provider has token")
        func testUsesBearerTokenWhenProvided() async throws {
            let mockAuth = MockAuthProvider(currentToken: "valid.jwt.token")
            let reporter = await ListeningSessionReporter(authProvider: mockAuth)
            
            // Create a request using the reporter's createPostRequest method
            let requestBody = ["test": "data"]
            let url = URL(string: "https://test.com")!
            
            let request = try await reporter.createPostRequest(url: url, requestBody: requestBody)
            
            // Check that Authorization header contains Bearer token
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader == "Bearer valid.jwt.token")
        }
        
        @Test("Uses Basic auth when no token available")
        func testUsesBasicAuthWhenNoToken() async throws {
            let mockAuth = MockAuthProvider(currentToken: nil)
            let reporter = await ListeningSessionReporter(authProvider: mockAuth)
            
            let requestBody = ["test": "data"]
            let url = URL(string: "https://test.com")!
            
            let request = try await reporter.createPostRequest(url: url, requestBody: requestBody)
            
            // Check that Authorization header contains Basic auth
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader == "Basic aW9zQXBwOnNwb3RpZnlTdWNrc0FCaWcx")
        }
        
        @Test("Uses Basic auth when auth provider is nil")
        func testUsesBasicAuthWhenProviderIsNil() async throws {
            let reporter = await ListeningSessionReporter(authProvider: nil)
            
            let requestBody = ["test": "data"]
            let url = URL(string: "https://test.com")!
            
            let request = try await reporter.createPostRequest(url: url, requestBody: requestBody)
            
            // Check that Authorization header contains Basic auth
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader == "Basic aW9zQXBwOnNwb3RpZnlTdWNrc0FCaWcx")
        }
    }
    
    @Suite("Token Refresh on 401")
    struct TokenRefreshFlow {
        @Test("Calls refresh token on 401 response")
        func testCallsRefreshOn401() async throws {
            let mockAuth = MockAuthProvider(
                currentToken: "expired.token",
                refreshedToken: "fresh.token"
            )
            let mockURLSession = MockURLSession()
            
            // First request returns 401
            let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!
            mockURLSession.addResponse(statusCode: 401, url: testURL)
            
            // Second request (after refresh) returns 200
            mockURLSession.addResponse(statusCode: 200, url: testURL)
            
            let reporter = await ListeningSessionReporter(authProvider: mockAuth, urlSession: mockURLSession)
            
            // This should trigger the 401 handling
            try await reporter.reportOrExtendListeningSession("test-station-id")
            
            // Verify that refresh was called
            #expect(mockAuth.refreshCallCount == 1)
            
            // Verify that two HTTP requests were made (initial + retry)
            #expect(mockURLSession.requestCallCount == 2)
        }
        
        @Test("Handles failed token refresh gracefully")
        func testHandlesFailedRefresh() async throws {
            let mockAuth = MockAuthProvider(
                currentToken: "expired.token",
                refreshedToken: nil // Refresh fails
            )
            let mockURLSession = MockURLSession()
            
            // First request returns 401
            let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!
            mockURLSession.addResponse(statusCode: 401, url: testURL)
            
            // Basic auth fallback returns 200
            mockURLSession.addResponse(statusCode: 200, url: testURL)
            
            let reporter = await ListeningSessionReporter(authProvider: mockAuth, urlSession: mockURLSession)
            
            // This should fall back to Basic auth
            try await reporter.reportOrExtendListeningSession("test-station-id")
            
            // Verify that refresh was called
            #expect(mockAuth.refreshCallCount == 1)
            
            // Verify that two HTTP requests were made (initial + Basic auth fallback)
            #expect(mockURLSession.requestCallCount == 2)
        }
        
        @Test("Exceeds max refresh attempts and falls back to Basic auth")
        func testExceedsMaxRefreshAttempts() async throws {
            let mockAuth = MockAuthProvider(
                currentToken: "expired.token",
                refreshedToken: "still.expired.token" // Refresh returns token but still gets 401
            )
            let mockURLSession = MockURLSession()
            
            let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!
            
            // First request returns 401
            mockURLSession.addResponse(statusCode: 401, url: testURL)
            
            // All refresh attempts also return 401 (simulating broken refresh token)
            for _ in 0..<3 {
                mockURLSession.addResponse(statusCode: 401, url: testURL)
            }
            
            // Final Basic auth fallback returns 200
            mockURLSession.addResponse(statusCode: 200, url: testURL)
            
            let reporter = await ListeningSessionReporter(authProvider: mockAuth, urlSession: mockURLSession)
            
            // This should exhaust refresh attempts and fall back to Basic auth
            try await reporter.reportOrExtendListeningSession("test-station-id")
            
            // Verify that refresh was called 3 times (max attempts)
            #expect(mockAuth.refreshCallCount == 3)
            
            // Verify correct number of HTTP requests:
            // 1 initial + 3 refresh attempts + 1 Basic auth fallback = 5
            #expect(mockURLSession.requestCallCount == 5)
        }
        
        @Test("Resets retry counter after successful request")
        func testResetsRetryCounterAfterSuccess() async throws {
            let mockAuth = MockAuthProvider(
                currentToken: "expired.token",
                refreshedToken: "fresh.token"
            )
            let mockURLSession = MockURLSession()
            
            let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!
            
            // First attempt: 401 then success
            mockURLSession.addResponse(statusCode: 401, url: testURL)
            mockURLSession.addResponse(statusCode: 200, url: testURL)
            
            let reporter = await ListeningSessionReporter(authProvider: mockAuth, urlSession: mockURLSession)
            
            // First call should succeed after refresh
            try await reporter.reportOrExtendListeningSession("test-station-id")
            
            // Second attempt: 401 then success (should work again, counter was reset)
            mockURLSession.addResponse(statusCode: 401, url: testURL)
            mockURLSession.addResponse(statusCode: 200, url: testURL)
            
            // Second call should also succeed
            try await reporter.reportOrExtendListeningSession("test-station-id")
            
            // Verify that refresh was called twice (once for each attempt)
            #expect(mockAuth.refreshCallCount == 2)
            
            // Verify correct number of HTTP requests: 2 + 2 = 4
            #expect(mockURLSession.requestCallCount == 4)
        }
        
        @Test("Succeeds on first request when token is valid")
        func testSucceedsOnFirstRequest() async throws {
            let mockAuth = MockAuthProvider(currentToken: "valid.token")
            let mockURLSession = MockURLSession()
            
            // First request returns 200 (success)
            let testURL = URL(string: "https://admin-api.playola.fm/v1/listeningSessions")!
            mockURLSession.addResponse(statusCode: 200, url: testURL)
            
            let reporter = await ListeningSessionReporter(authProvider: mockAuth, urlSession: mockURLSession)
            
            // This should succeed without refreshing
            try await reporter.reportOrExtendListeningSession("test-station-id")
            
            // Verify that refresh was NOT called
            #expect(mockAuth.refreshCallCount == 0)
            
            // Verify that only one HTTP request was made
            #expect(mockURLSession.requestCallCount == 1)
        }
    }
}