//
//  PlayolaErrorReporter.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 3/21/25.
//
//
//  PlayolaErrorReporter.swift
//  PlayolaPlayer
//
//  Created on 3/21/25.
//

import Foundation
import os.log

/// Protocol defining the methods a delegate must implement to receive error reports
public protocol PlayolaErrorReporterDelegate: AnyObject {
  /// Called when an error occurs within the PlayolaPlayer library
  /// - Parameters:
  ///   - error: The error that occurred
  ///   - sourceFile: The file where the error originated
  ///   - sourceLine: The line number where the error originated
  ///   - function: The function where the error originated
  ///   - stackTrace: A string representation of the stack trace
  func playolaDidEncounterError(
    _ error: Error,
    sourceFile: String,
    sourceLine: Int,
    function: String,
    stackTrace: String
  )
}

/// Error reporting levels to control the verbosity of logging
public enum PlayolaErrorReportingLevel: Int, Sendable {
  case none = 0  // No error reporting
  case critical = 1  // Only critical errors that prevent functionality
  case error = 2  // All errors
  case warning = 3  // Errors and warnings
  case debug = 4  // Everything including debug information
}

/// Contains information about a PlayolaPlayer error
public struct PlayolaErrorReport: Sendable {
  public let error: Error
  public let sourceFile: String
  public let sourceLine: Int
  public let function: String
  public let stackTrace: String
  public let timestamp: Date
  public let threadName: String
  public let reportingLevel: PlayolaErrorReportingLevel

  init(
    error: Error,
    sourceFile: String,
    sourceLine: Int,
    function: String,
    stackTrace: String = Thread.callStackSymbols.joined(separator: "\n"),
    timestamp: Date = Date(),
    threadName: String = Thread.current.description,
    reportingLevel: PlayolaErrorReportingLevel = .error
  ) {
    self.error = error
    self.sourceFile = sourceFile
    self.sourceLine = sourceLine
    self.function = function
    self.stackTrace = stackTrace
    self.timestamp = timestamp
    self.threadName = threadName
    self.reportingLevel = reportingLevel
  }
}

/// Main error reporting class for PlayolaPlayer
public actor PlayolaErrorReporter {
  // MARK: - Singleton

  public static let shared = PlayolaErrorReporter()

  // MARK: - Properties

  private static let logger = OSLog(
    subsystem: "fm.playola.PlayolaPlayer", category: "ErrorReporter"
  )

  /// Delegate that will receive error reports
  public weak var delegate: PlayolaErrorReporterDelegate?

  /// Controls which errors get reported to the delegate
  public var reportingLevel: PlayolaErrorReportingLevel = .error

  /// Whether to log errors to system console even if no delegate is set
  public var logToConsole: Bool = true

  /// Maximum stack frame count to include in reports
  public var maxStackFrames: Int = 20

  /// Keeps track of recently reported errors to avoid duplicate reporting
  private var recentErrorHashes: [Int: Date] = [:]
  private let duplicateThresholdSeconds: TimeInterval = 5

  // MARK: - Initialization

  private init() {}

  // MARK: - Public Methods

  /// Report an error with source information
  /// - Parameters:
  ///   - error: The error to report
  ///   - file: Source file (automatically provided by default)
  ///   - line: Source line (automatically provided by default)
  ///   - function: Function name (automatically provided by default)
  ///   - level: The severity level of this error
  public func reportError(
    _ error: Error,
    file: String = #file,
    line: Int = #line,
    function: String = #function,
    level: PlayolaErrorReportingLevel = .error
  ) async {
    // Don't process if reporting level is not high enough
    guard level.rawValue <= reportingLevel.rawValue else { return }

    // Get file name without path
    let fileName = URL(fileURLWithPath: file).lastPathComponent

    // Capture stack trace
    let stackTrace = formatStackTrace(frames: Thread.callStackSymbols, maxFrames: maxStackFrames)

    // Create error report
    let report = PlayolaErrorReport(
      error: error,
      sourceFile: fileName,
      sourceLine: line,
      function: function,
      stackTrace: stackTrace,
      reportingLevel: level
    )

    // Deduplicate recent identical errors
    let errorHash = hashForError(error, file: fileName, line: line, function: function)
    if await isDuplicateError(hash: errorHash) {
      return
    }

    // Log to system console if enabled
    if logToConsole {
      logErrorToConsole(report)
    }

    // Call delegate on main thread
    if let delegate = delegate {
      await MainActor.run {
        delegate.playolaDidEncounterError(
          report.error,
          sourceFile: report.sourceFile,
          sourceLine: report.sourceLine,
          function: report.function,
          stackTrace: report.stackTrace
        )
      }
    }
  }

  /// Report an error with additional context
  /// - Parameters:
  ///   - error: The error to report
  ///   - context: Additional context to include in the error report
  ///   - file: Source file (automatically provided by default)
  ///   - line: Source line (automatically provided by default)
  ///   - function: Function name (automatically provided by default)
  ///   - level: The severity level of this error
  public func reportError(
    _ error: Error,
    context: String,
    file: String = #file,
    line: Int = #line,
    function: String = #function,
    level: PlayolaErrorReportingLevel = .error
  ) async {
    // Wrap the error with context
    let contextualError = NSError(
      domain: "fm.playola.PlayolaPlayer",
      code: (error as NSError).code,
      userInfo: [
        NSLocalizedDescriptionKey: "\(context): \(error.localizedDescription)",
        NSUnderlyingErrorKey: error,
      ]
    )

    await reportError(contextualError, file: file, line: line, function: function, level: level)
  }

  // MARK: - Private Methods

  private func logErrorToConsole(_ report: PlayolaErrorReport) {
    let errorMessage = """
      PLAYOLA ERROR: \(report.error.localizedDescription)
      File: \(report.sourceFile):\(report.sourceLine)
      Function: \(report.function)
      Thread: \(report.threadName)
      Stack Trace:
      \(report.stackTrace)
      """

    switch report.reportingLevel {
    case .critical:
      os_log(.fault, log: PlayolaErrorReporter.logger, "%{public}@", errorMessage)
    case .error:
      os_log(.error, log: PlayolaErrorReporter.logger, "%{public}@", errorMessage)
    case .warning:
      os_log(.info, log: PlayolaErrorReporter.logger, "%{public}@", errorMessage)
    case .debug:
      os_log(.debug, log: PlayolaErrorReporter.logger, "%{public}@", errorMessage)
    case .none:
      break
    }
  }

  private func formatStackTrace(frames: [String], maxFrames: Int) -> String {
    // Take only the specified number of frames and join them with newlines
    return frames.prefix(maxFrames).joined(separator: "\n")
  }

  private func hashForError(_ error: Error, file: String, line: Int, function: String) -> Int {
    // Create a hash that uniquely identifies this error instance
    var hasher = Hasher()
    hasher.combine(error.localizedDescription)
    hasher.combine(file)
    hasher.combine(line)
    hasher.combine(function)
    return hasher.finalize()
  }

  private func isDuplicateError(hash: Int) async -> Bool {
    let now = Date()

    // Clean up old entries
    recentErrorHashes = recentErrorHashes.filter { _, date in
      now.timeIntervalSince(date) < duplicateThresholdSeconds
    }

    // Check if this is a recent duplicate
    if let lastReported = recentErrorHashes[hash],
      now.timeIntervalSince(lastReported) < duplicateThresholdSeconds
    {
      return true
    }

    // Not a duplicate, add to recent errors
    recentErrorHashes[hash] = now
    return false
  }
}

// MARK: - Convenience Extensions

/// Extension to provide a simpler way to report errors
extension Error {
  /// Report this error through the PlayolaErrorReporter
  /// - Parameters:
  ///   - file: Source file (automatically provided by default)
  ///   - line: Source line (automatically provided by default)
  ///   - function: Function name (automatically provided by default)
  ///   - level: The severity level of this error
  public func playolaReport(
    file: String = #file,
    line: Int = #line,
    function: String = #function,
    level: PlayolaErrorReportingLevel = .error
  ) {
    Task {
      await PlayolaErrorReporter.shared.reportError(
        self, file: file, line: line, function: function, level: level
      )
    }
  }
}
