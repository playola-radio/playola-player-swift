//
//  MockAuthProvider.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 7/10/25.
//
@testable import PlayolaPlayer

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
