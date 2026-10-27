import Foundation

public enum VIN {
    /// Whether `s` is a VIN: exactly 17 ASCII characters from `A-HJ-NPR-Z0-9`, so no `I`, `O` or `Q` and no
    /// lower case.
    public static func isValid(_ s: String) -> Bool {
        let allowed = "ABCDEFGHJKLMNPRSTUVWXYZ0123456789".utf8
        return s.utf8.count == 17 && s.utf8.allSatisfy(allowed.contains)
    }

    /// The car's VIN: data identifier `0xF190` read from each of `ModuleTable.gatewayCandidates` in order,
    /// returning the first answer that is a valid VIN. A module that refuses, stays silent or answers with
    /// something else is passed over. Throws `VINError.noVIN` after the last one, and lets the `LinkError`s
    /// of `diag` through.
    public static func read(diag: Diag) async throws -> String {
        // ponytail: no fallback to standard OBD mode 09, which needs a second adapter addressing mode. Add it
        // if a car answers 0xF190 on none of the four candidates.
        for address in ModuleTable.gatewayCandidates {
            try await diag.select(module: address)
            guard case .positive(let data) = try await diag.readDID(address, 0xF190) else { continue }
            // Bytes that are not UTF-8 decode to U+FFFD, which `isValid` rejects.
            let vin = String(decoding: data, as: UTF8.self)
            if isValid(vin) { return vin }
        }
        throw VINError.noVIN
    }
}

public enum VINError: Error, Equatable {
    /// None of the candidate modules answered with a valid VIN.
    case noVIN
}

/// A car the owner has given a nickname.
public struct CarRecord: Codable, Equatable, Sendable {
    public var vin: String
    public var nickname: String
}

/// The cars the owner has named, kept in a JSON file that is readable and editable by hand.
public struct CarBook: Codable, Equatable {
    public var cars: [CarRecord]

    /// The book in the file at `url`. Empty when there is no file or it cannot be decoded, in which case
    /// the next `save` replaces it.
    public static func load(from url: URL) -> CarBook {
        (try? JSONDecoder().decode(CarBook.self, from: Data(contentsOf: url))) ?? CarBook(cars: [])
    }

    /// Writes the book to `url` as pretty-printed JSON with sorted keys, creating the folders on the way.
    /// The file is replaced as a whole, so a crash half-way leaves the old one.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The record whose VIN is exactly `vin`, or `nil` when the book has none.
    public func car(for vin: String) -> CarRecord? { cars.first { $0.vin == vin } }

    /// Names the car with `vin`: replaces its nickname if it is in the book, otherwise adds it at the end.
    public mutating func set(nickname: String, for vin: String) {
        if let index = cars.firstIndex(where: { $0.vin == vin }) {
            cars[index].nickname = nickname
        } else {
            cars.append(CarRecord(vin: vin, nickname: nickname))
        }
    }
}
