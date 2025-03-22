//
//  SpinTests.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 1/8/25.
//
import Foundation
import Testing
@testable import PlayolaPlayer

struct SpinTests {
    var spin: Spin = .mock
    let dateProviderMock = DateProviderMock()

    init() {
        spin.dateProvider = dateProviderMock
    }

    @Test("isPlaying returns false if .now is too early")
    func testIsPlaying_nowIsBeforeSpin() throws {
        // Use mockWith to create a spin with a controlled airtime
        let now = Date()
        dateProviderMock.mockDate = now

        // Create a spin that starts 30 seconds in the future
        let futureSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(30),
            dateProvider: dateProviderMock
        )

        #expect(futureSpin.isPlaying == false)
    }

    @Test("isPlaying returns true if .now is between start and endTime")
    func testIsPlaying_nowIsDuringSpin() throws {
        // Use mockWith to create a spin that's currently playing
        let now = Date()
        dateProviderMock.mockDate = now

        // Create a spin that started 3 seconds ago
        let playingSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-3),
            dateProvider: dateProviderMock
        )

        #expect(playingSpin.isPlaying == true)
    }

    @Test("isPlaying returns false if .now is after endtime")
    func testIsPlaying_nowIsAfterSpin() throws {
        // Create an audio block with a specific duration
        let shortAudioBlock = AudioBlock.mockWith(
            durationMS: 10000,  // 10 second duration
            endOfMessageMS: 10000
        )

        // Set up the current time
        let now = Date()
        dateProviderMock.mockDate = now

        // Create a spin that started 30 seconds ago with a 10-second duration
        // This means it finished 20 seconds ago
        let finishedSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-30),
            audioBlock: shortAudioBlock,
            dateProvider: dateProviderMock
        )

        #expect(finishedSpin.isPlaying == false)
    }

    @Test("isPlaying returns true at exactly the airtime")
    func testIsPlaying_exactlyAtAirtime() throws {
        // Set up the current time
        let now = Date()
        dateProviderMock.mockDate = now

        // Create a spin that starts exactly now
        let startingSpin = Spin.mockWith(
            airtime: now,
            dateProvider: dateProviderMock
        )

        #expect(startingSpin.isPlaying == true)
    }

    @Test("isPlaying returns true just before endtime")
    func testIsPlaying_justBeforeEndtime() throws {
        // Create an audio block with a specific duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 10000,  // 10 second duration
            endOfMessageMS: 10000
        )

        // Set up the current time
        let now = Date()
        dateProviderMock.mockDate = now

        // Create a spin that started almost 10 seconds ago (just 1 millisecond before endtime)
        let almostFinishedSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-9.999),
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )

        #expect(almostFinishedSpin.isPlaying == true)
    }

    @Test("isPlaying returns true at exactly the endtime")
    func testIsPlaying_exactlyAtEndtime() throws {
        // Create an audio block with a specific duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 10000,  // 10 second duration
            endOfMessageMS: 10000
        )

        // Set up the current time
        let now = Date()
        dateProviderMock.mockDate = now

        // Create a spin that started exactly 10 seconds ago (exactly at endtime)
        let justFinishedSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-10),
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )

        #expect(justFinishedSpin.isPlaying == true)
    }

    @Test("endtime is calculated correctly from airtime and audioBlock duration")
    func testEndtimeCalculation() throws {
        // Verify the endtime is calculated as airtime + audioBlock.endOfMessageMS milliseconds
        let expectedEndtime = spin.airtime + TimeInterval(Double(spin.audioBlock?.endOfMessageMS ?? 0) / 1000.0)
        #expect(spin.endtime == expectedEndtime)
    }

    @Test("Spin plays between airtime and endtime")
    func testSpinTimeInterval() throws {
        // Create an audio block with a specific duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 15000,  // 15 second duration
            endOfMessageMS: 15000
        )

        // Set up the current time
        let now = Date()
        dateProviderMock.mockDate = now

        // Test with the current time before the spin's airtime
        let futureSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(5), // Starts in 5 seconds
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )
        #expect(futureSpin.isPlaying == false)

        // Test with the current time during the spin's play interval
        let playingSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-5), // Started 5 seconds ago
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )
        #expect(playingSpin.isPlaying == true)

        // Test with the current time after the spin's play interval
        let finishedSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-20), // Started 20 seconds ago
            audioBlock: audioBlock,
            dateProvider: dateProviderMock
        )
        #expect(finishedSpin.isPlaying == false)
    }

    @Test("Manual time range checking")
    func testManualTimeRangeChecking() throws {
        // Create an audio block with a specific duration
        let audioBlock = AudioBlock.mockWith(
            durationMS: 20000,  // 20 second duration
            endOfMessageMS: 20000
        )

        // Set a reference time
        let referenceTime = Date()

        // Create a spin starting at our reference time
        let testSpin = Spin.mockWith(
            airtime: referenceTime,
            audioBlock: audioBlock
        )

        // We can manually check if a time is within a spin's play range

        // Time before the spin starts (5 seconds before reference)
        let beforeTime = referenceTime.addingTimeInterval(-5)
        let isBeforeTimeInRange = beforeTime >= testSpin.airtime && beforeTime < testSpin.endtime
        #expect(isBeforeTimeInRange == false)

        // Time during the spin (10 seconds after reference, which is halfway through)
        let duringTime = referenceTime.addingTimeInterval(10)
        let isDuringTimeInRange = duringTime >= testSpin.airtime && duringTime < testSpin.endtime
        #expect(isDuringTimeInRange == true)

        // Time at exact airtime (should be in range)
        let isAirtimeInRange = testSpin.airtime >= testSpin.airtime && testSpin.airtime < testSpin.endtime
        #expect(isAirtimeInRange == true)

        // Time at exact endtime (should not be in range)
        let isEndtimeInRange = testSpin.endtime >= testSpin.airtime && testSpin.endtime < testSpin.endtime
        #expect(isEndtimeInRange == false)
    }

    @Test("Testing varying playback scenarios with custom mocks")
    func testPlaybackScenarios() throws {
        let now = Date()
        let dateProviderMock = DateProviderMock(mockDate: now)

        // Create an AudioBlock with custom duration
        let customAudioBlock = AudioBlock.mockWith(
            title: "Custom Test Track",
            artist: "Test Artist",
            durationMS: 10000,  // 10 second duration
            endOfMessageMS: 10000
        )

        // 1. Test a spin that's currently playing
        let playingSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-2),  // Started 2 seconds ago
            audioBlock: customAudioBlock,
            dateProvider: dateProviderMock
        )

        #expect(playingSpin.isPlaying)

        // 2. Test a spin that hasn't started yet
        let upcomingSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(30),  // Starts in 30 seconds
            audioBlock: customAudioBlock,
            dateProvider: dateProviderMock
        )

        #expect(!upcomingSpin.isPlaying)

        // 3. Test a spin that has already finished
        let finishedSpin = Spin.mockWith(
            airtime: now.addingTimeInterval(-15),  // Started 15 seconds ago with 10 second duration
            audioBlock: customAudioBlock,
            dateProvider: dateProviderMock
        )

        #expect(!finishedSpin.isPlaying)
    }
}
