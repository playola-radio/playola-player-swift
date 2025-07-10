//
//  URLSessionProtocol.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 7/10/25.
//
import Foundation

// Protocol for URLSession dependency injection
protocol URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}
