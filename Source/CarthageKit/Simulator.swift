import Foundation
import XCDBLD

internal struct Simulator: Decodable {
	enum CodingKeys: String, CodingKey {
		case name
		case udid
		case isAvailable
		case availability
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		name = try container.decode(String.self, forKey: .name)
		udid = try container.decode(UUID.self, forKey: .udid)
		// To Xcode 10.0, Return values of `xcrun simctl list devices --json` contains `availability` field.
		// Its value is possible to be `(available)` or `(unavailable)`.
		// Since Xcode 10.1, `availability` field is obsolated.
		// Using `isAvailable` instead. its value is possible to be `YES` or `NO`.
		let availability = try container.decodeIfPresent(String.self, forKey: .availability)
		
		do {
			let isAvailable = try container.decodeIfPresent(String.self, forKey: .isAvailable)
			self.isAvailable = isAvailable == "YES" || availability == "(available)"
		} catch {
			// Xcode 10.1 uses key `isAvailable` with bool value so try to keep it backward compatible
			self.isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
		}
	}

	var isAvailable: Bool
	var name: String
	var udid: UUID
}

/// Select available simulator from output value of `simclt devices list`
/// If there are multiple OSs for the SDK, the latest one would be selected.
internal func selectAvailableSimulator(of sdk: SDK, from data: Data) -> Simulator? {
	let decoder = JSONDecoder()
	// simctl returns following JSON:
	// {"devices": {"iOS 12.0": [<simulators...>]}]
	guard let jsonObject = try? decoder.decode([String: [String: [Simulator]]].self, from: data),
		let devices = jsonObject["devices"] else {
		return nil
	}
	let platformName = sdk.platform.rawValue
	func reducePlatformNames(_ result: inout [String: [Simulator]], _ entry: (key: String, value: [Simulator])) {
		guard let platformVersion = parsePlatformVersion(for: platformName, from: entry.key) else { return }
		result[platformVersion] = entry.value
	}
	let allTargetSimulators = devices.filter({ _, devices in 
		return devices.contains { $0.isAvailable }
		}).reduce(into: [:], reducePlatformNames)
	func sortedByVersion(_ osNames: [String]) -> [String] {
		return osNames.sorted { lhs, rhs in
			guard let lhsVersion = SemanticVersion.from(PinnedVersion(lhs)).value,
				let rhsVersion = SemanticVersion.from(PinnedVersion(rhs)).value else {
					return lhs < rhs
			}
			return lhsVersion < rhsVersion
		}
	}
	guard let latestOSName = sortedByVersion(Array(allTargetSimulators.keys)).last else {
		return nil
	}
	return allTargetSimulators[latestOSName]?
		.first { $0.isAvailable }
}

/// Parses a matching platform and version from a given identifier.
internal func parsePlatformVersion(for platformName: String, from identifier: String) -> String? {
	guard let platformRange = identifier.range(of: platformName) else { return nil }

	let nonDigitCharacters = CharacterSet.decimalDigits.inverted
	let version = identifier
		.suffix(from: platformRange.upperBound)
		.split(whereSeparator: { $0.unicodeScalars.contains(where: { nonDigitCharacters.contains($0) }) })
		.joined(separator: ".")

	return "\(platformName) \(version)"
}