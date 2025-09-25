//
//  DateFormatterTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 3/21/25.
//

import Testing
import XCTest

@testable import PlayolaPlayer

struct DateFormatterTests {
  // Test that the iso8601Full formatter correctly formats dates
  @Test("iso8601Full correctly formats a date to ISO8601 format")
  func testIso8601FullFormatting() throws {
    // Create a specific date to test (January 15, 2023 10:30:45.123 UTC)
    let calendar = Calendar(identifier: .gregorian)
    var dateComponents = DateComponents()
    dateComponents.year = 2023
    dateComponents.month = 1
    dateComponents.day = 15
    dateComponents.hour = 10
    dateComponents.minute = 30
    dateComponents.second = 45
    dateComponents.nanosecond = 123_000_000  // 123 milliseconds

    let timeZone = TimeZone(secondsFromGMT: 0)!  // UTC
    dateComponents.timeZone = timeZone

    let testDate = calendar.date(from: dateComponents)!

    // Format the date using the iso8601Full formatter
    let formattedDate = DateFormatter.iso8601Full.string(from: testDate)

    // Expected ISO8601 format: "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    #expect(formattedDate == "2023-01-15T10:30:45.123+0000")
  }

  // Test that the iso8601Full formatter correctly parses ISO8601 strings
  @Test("iso8601Full correctly parses an ISO8601 formatted string")
  func testIso8601FullParsing() throws {
    // ISO8601 formatted string
    let dateString = "2023-01-15T10:30:45.123+0000"

    // Parse the string using the iso8601Full formatter
    let parsedDate = DateFormatter.iso8601Full.date(from: dateString)

    // Verify the parsed date is not nil
    #expect(parsedDate != nil)

    // Create the expected date for comparison
    let calendar = Calendar(identifier: .gregorian)
    var dateComponents = DateComponents()
    dateComponents.year = 2023
    dateComponents.month = 1
    dateComponents.day = 15
    dateComponents.hour = 10
    dateComponents.minute = 30
    dateComponents.second = 45
    dateComponents.nanosecond = 123_000_000  // 123 milliseconds

    let timeZone = TimeZone(secondsFromGMT: 0)!  // UTC
    dateComponents.timeZone = timeZone

    let expectedDate = calendar.date(from: dateComponents)!

    // Compare the dates
    // Since we're working with milliseconds, we'll check if they're within 1 millisecond of each other
    let tolerance = TimeInterval(0.001)
    #expect(abs(parsedDate!.timeIntervalSince(expectedDate)) < tolerance)
  }

  // Test that the formatter uses the correct settings
  @Test("iso8601Full has the correct configuration")
  func testIso8601FullConfiguration() throws {
    let formatter = DateFormatter.iso8601Full

    // Verify the formatter's configuration
    #expect(formatter.dateFormat == "yyyy-MM-dd'T'HH:mm:ss.SSSZ")
    #expect(formatter.calendar.identifier == .iso8601)
    #expect(formatter.timeZone.secondsFromGMT() == 0)
    #expect(formatter.locale.identifier == "en_US_POSIX")
  }

  // Test handling various edge cases
  @Test("iso8601Full correctly handles dates with different time zones")
  func testIso8601FullWithDifferentTimeZones() throws {
    // Create a date in a non-UTC timezone (GMT+2)
    let nonUtcTimeZone = TimeZone(secondsFromGMT: 7200)!  // GMT+2

    let calendar = Calendar(identifier: .gregorian)
    var dateComponents = DateComponents()
    dateComponents.year = 2023
    dateComponents.month = 6
    dateComponents.day = 30
    dateComponents.hour = 15
    dateComponents.minute = 45
    dateComponents.second = 30
    dateComponents.timeZone = nonUtcTimeZone

    let testDate = calendar.date(from: dateComponents)!

    // Format the date - should always output in UTC regardless of the date's timezone
    let formattedDate = DateFormatter.iso8601Full.string(from: testDate)

    // Since the formatter is set to UTC, the hour should be adjusted from the input timezone
    // GMT+2 15:45:30 should be formatted as 13:45:30 in UTC
    #expect(formattedDate == "2023-06-30T13:45:30.000+0000")
  }

  @Test("iso8601Full correctly handles parsing an ISO8601 string with different timezone")
  func testIso8601FullParsingWithDifferentTimeZone() throws {
    // ISO8601 formatted string with non-UTC timezone
    let dateString = "2023-01-15T10:30:45.123+0200"  // GMT+2

    // Parse the string using the iso8601Full formatter
    let parsedDate = DateFormatter.iso8601Full.date(from: dateString)

    // Verify the parsed date is not nil
    #expect(parsedDate != nil)

    // When formatted back, it should be in UTC
    let reformattedString = DateFormatter.iso8601Full.string(from: parsedDate!)

    // Expected: 08:30:45 UTC (10:30:45 GMT+2 converted to UTC)
    #expect(reformattedString == "2023-01-15T08:30:45.123+0000")
  }

  @Test("JSONDecoderWithIsoFull correctly decodes dates")
  func testJsonDecoderWithIsoFull() throws {
    // Create a simple struct with a date field
    struct TestStruct: Codable {
      let date: Date
    }

    // Create JSON data with an ISO8601 date string
    let jsonData = """
      {
          "date": "2023-01-15T10:30:45.123+0000"
      }
      """
    guard let jsonData = jsonData.data(using: .utf8) else {
      XCTFail("Failed to create JSON data")
      return
    }

    // Use our JSONDecoderWithIsoFull to decode
    let decoder = JSONDecoderWithIsoFull()
    let result = try decoder.decode(TestStruct.self, from: jsonData)

    // Format the decoded date back to a string
    let formattedDate = DateFormatter.iso8601Full.string(from: result.date)

    // Check that the date was correctly decoded
    #expect(formattedDate == "2023-01-15T10:30:45.123+0000")
  }
}
