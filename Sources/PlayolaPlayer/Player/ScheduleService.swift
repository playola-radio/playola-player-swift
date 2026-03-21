import Foundation
import PlayolaCore
import os.log

enum ScheduleService {
  private static let logger = OSLog(
    subsystem: "PlayolaPlayer",
    category: "ScheduleService")

  static func getSchedule(
    stationId: String,
    baseUrl: URL,
    errorReporter: PlayolaErrorReporter = .shared
  ) async throws -> Schedule {
    let url = baseUrl.appending(path: "/v1/stations/\(stationId)/schedule")
      .appending(queryItems: [
        URLQueryItem(name: "includeRelatedTexts", value: "true"),
        URLQueryItem(name: "lockedIn", value: "true"),
      ])

    do {
      let (data, response) = try await URLSession.shared.data(from: url)

      guard let httpResponse = response as? HTTPURLResponse else {
        let error = StationPlayerError.networkError("Invalid response type")
        Task {
          await errorReporter.reportError(
            error,
            context: "Non-HTTP response received from schedule endpoint: \(url.absoluteString)",
            level: .error)
        }
        throw error
      }

      guard (200...299).contains(httpResponse.statusCode) else {
        let responseText = String(data: data, encoding: .utf8) ?? "Unable to decode response"
        let error = StationPlayerError.networkError("HTTP error: \(httpResponse.statusCode)")

        Task {
          if httpResponse.statusCode == 404 {
            await errorReporter.reportError(
              error,
              context: "Station not found: \(stationId) | Response: \(responseText.prefix(100))",
              level: .error)
          } else {
            await errorReporter.reportError(
              error,
              context:
                "HTTP \(httpResponse.statusCode) error getting schedule for station: \(stationId) | "
                + "Response: \(responseText.prefix(100))",
              level: .error)
          }
        }
        throw error
      }

      return try decodeSchedule(from: data, stationId: stationId, errorReporter: errorReporter)
    } catch let error as StationPlayerError {
      throw error
    } catch {
      Task {
        await errorReporter.reportError(
          error, context: "Failed to fetch schedule for station: \(stationId)", level: .error)
      }
      throw error
    }
  }

  private static func decodeSchedule(
    from data: Data, stationId: String, errorReporter: PlayolaErrorReporter
  ) throws -> Schedule {
    let decoder = JSONDecoderWithIsoFull()

    do {
      let spins = try decoder.decode([Spin].self, from: data)
      guard !spins.isEmpty else {
        let error = StationPlayerError.scheduleError(
          "No spins returned in schedule for station ID: \(stationId)")
        Task {
          await errorReporter.reportError(error, level: .error)
        }
        throw error
      }
      return Schedule(stationId: spins[0].stationId, spins: spins)
    } catch let decodingError as DecodingError {
      let context: String
      switch decodingError {
      case .dataCorrupted(let reportedContext):
        context = "Corrupted data: \(reportedContext.debugDescription)"
      case .keyNotFound(let key, _):
        context = "Missing key: \(key)"
      case .typeMismatch(let type, _):
        context = "Type mismatch for: \(type)"
      default:
        context = "Unknown decoding error"
      }

      Task {
        await errorReporter.reportError(
          decodingError, context: "Failed to decode schedule: \(context)", level: .error)
      }

      throw StationPlayerError.scheduleError("Invalid schedule data: \(context)")
    }
  }
}
