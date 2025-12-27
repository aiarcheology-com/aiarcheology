//
//  DeviceInfo.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import UIKit

struct DeviceInfo {
    @MainActor static func information() -> String {
		let device = UIDevice.current
		let deviceModel = DeviceInfo.deviceModelName()
		let iosVersion = device.systemVersion

		let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown"
		let appVersionNumber = AppEnvironment.shortVersion ?? "Unknown"
		let appBuildNumber = AppEnvironment.buildNumber ?? "Unknown"

		let storageStatus = getDeviceStorageStatus()

		let date = getCurrentFormattedDate()

		let info = """
		   Device Model: \(deviceModel)
		   iOS Version: \(iosVersion)
		   App Name: \(appName)
		   App Version Number: \(appVersionNumber)
		   App Build Number: \(appBuildNumber)
		   Current Device Storage Status: \(storageStatus)
		   Info Gathered to Date: \(date)
		"""

		return info
	}

	static func getDeviceStorageStatus() -> String {
		let fileManager = FileManager.default
		do {
			let attributes = try fileManager.attributesOfFileSystem(forPath: NSHomeDirectory())
			let freeSpace = attributes[.systemFreeSize] as? NSNumber
			let totalSpace = attributes[.systemSize] as? NSNumber

			let freeSpaceGB = (freeSpace?.doubleValue ?? 0.0) / 1_000_000_000
			let totalSpaceGB = (totalSpace?.doubleValue ?? 0.0) / 1_000_000_000

			return "Free: \(String(format: "%.2f", freeSpaceGB)) GB, Total: \(String(format: "%.2f", totalSpaceGB)) GB"
		} catch {
			return "Storage information could not be retrieved"
		}
	}

	static func getCurrentFormattedDate() -> String {
		let dateFormatter = DateFormatter()
		dateFormatter.dateStyle = .medium
		dateFormatter.timeStyle = .short

		let currentDate = Date()
		return dateFormatter.string(from: currentDate)
	}

	static func deviceModelName() -> String {
		var systemInfo = utsname()
		uname(&systemInfo)

		let machineMirror = Mirror(reflecting: systemInfo.machine)
		let identifier = machineMirror.children.reduce("") { identifier, element in
			guard let value = element.value as? Int8, value != 0 else { return identifier }
			return identifier + String(UnicodeScalar(UInt8(value)))
		}

		return identifier
	}
}
