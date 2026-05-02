import Foundation
import GRDB

public struct SettingsRepository {
    private let pool: DatabasePool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(pool: DatabasePool) {
        self.pool = pool
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func fetchConfiguration() throws -> AppConfiguration? {
        try fetchValue(AppConfiguration.self, key: AppConfiguration.storageKey)
    }

    public func saveConfiguration(_ configuration: AppConfiguration) throws {
        try saveValue(configuration, key: AppConfiguration.storageKey)
    }

    public func fetchValue<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        try pool.read { db in
            guard let valueJSON = try String.fetchOne(
                db,
                sql: "SELECT value_json FROM settings WHERE key = ?",
                arguments: [key]
            ) else {
                return nil
            }

            return try decoder.decode(T.self, from: Data(valueJSON.utf8))
        }
    }

    public func saveValue<T: Encodable>(_ value: T, key: String, updatedAt: Date = Date()) throws {
        let data = try encoder.encode(value)
        guard let valueJSON = String(data: data, encoding: .utf8) else {
            throw SDImportError.invalidDatabaseValue(column: "settings.value_json", value: "<non-utf8>")
        }

        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_json = excluded.value_json,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    key,
                    valueJSON,
                    DateCoding.string(from: updatedAt)
                ]
            )
        }
    }
}
