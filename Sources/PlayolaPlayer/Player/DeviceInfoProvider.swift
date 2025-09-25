//
//  DeviceInfoProvider.swift
//  PlayolaPlayer
//
//  Created by Brian D Keane on 8/8/25.
//

import Foundation

#if os(iOS)
    import UIKit
#endif

/// Provides cross-platform device information
public enum DeviceInfoProvider {
    public static var deviceName: String {
        #if os(iOS)
            return UIDevice.current.name
        #elseif os(macOS)
            return Host.current().localizedName ?? "Mac"
        #endif
    }

    public static var systemVersion: String {
        #if os(iOS)
            return UIDevice.current.systemVersion
        #elseif os(macOS)
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }

    public static var identifierForVendor: UUID? {
        #if os(iOS)
            return UIDevice.current.identifierForVendor
        #elseif os(macOS)
            return getOrCreateVendorIdentifier()
        #endif
    }

    #if os(macOS)
        private static let vendorIdentifierKey = "PlayolaPlayer.VendorIdentifier"

        private static func getOrCreateVendorIdentifier() -> UUID? {
            if let uuidString = UserDefaults.standard.string(forKey: vendorIdentifierKey),
               let uuid = UUID(uuidString: uuidString)
            {
                return uuid
            }

            let newUUID = UUID()
            UserDefaults.standard.set(newUUID.uuidString, forKey: vendorIdentifierKey)
            return newUUID
        }
    #endif
}
