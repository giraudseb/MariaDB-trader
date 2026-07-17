import Foundation

/// DDL + seed data for the synthetic trading schema.
public enum Schema {
    public static let instruments = ["MDB", "ACME", "GLOB", "NOVA", "ORCL",
                                     "TSLA", "AAPL", "MSFT", "AMZN", "NFLX"]

    public static let ddl: [String] = [
        """
        CREATE TABLE IF NOT EXISTS accounts (
            id INT PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            balance DECIMAL(18,2) NOT NULL DEFAULT 0
        ) ENGINE=InnoDB
        """,
        """
        CREATE TABLE IF NOT EXISTS instruments (
            symbol VARCHAR(12) PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            last_price DECIMAL(12,4) NOT NULL DEFAULT 100,
            updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
        ) ENGINE=InnoDB
        """,
        """
        CREATE TABLE IF NOT EXISTS orders (
            id BIGINT PRIMARY KEY AUTO_INCREMENT,
            account_id INT NOT NULL,
            symbol VARCHAR(12) NOT NULL,
            side ENUM('BUY','SELL') NOT NULL,
            qty INT NOT NULL,
            price DECIMAL(12,4) NOT NULL,
            status ENUM('NEW','FILLED','CANCELLED') NOT NULL DEFAULT 'NEW',
            created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
            KEY idx_symbol_created (symbol, created_at)
        ) ENGINE=InnoDB
        """,
        """
        CREATE TABLE IF NOT EXISTS trades (
            id BIGINT PRIMARY KEY AUTO_INCREMENT,
            symbol VARCHAR(12) NOT NULL,
            qty INT NOT NULL,
            price DECIMAL(12,4) NOT NULL,
            buyer_id INT NOT NULL,
            seller_id INT NOT NULL,
            executed_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
            KEY idx_symbol_exec (symbol, executed_at)
        ) ENGINE=InnoDB
        """
    ]

    /// Quotes a SQL identifier (database/table name) with backticks, escaping
    /// any embedded backtick. DDL identifiers can't be parameterized, so this
    /// guards the user-supplied database name against injection.
    public static func quoteIdentifier(_ ident: String) -> String {
        "`" + ident.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// Creates the target database if it does not already exist. Idempotent.
    public static func ensureDatabase(_ conn: MariaConnection, name: String) throws {
        let db = name.trimmingCharacters(in: .whitespaces)
        guard !db.isEmpty else {
            throw MariaError(code: 1102, message: "empty database name")
        }
        try conn.execute("CREATE DATABASE IF NOT EXISTS \(quoteIdentifier(db)) "
                         + "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
    }

    /// Runs DDL and seeds reference data. Idempotent.
    public static func bootstrap(_ conn: MariaConnection, accounts: Int = 200) throws {
        for stmt in ddl { try conn.execute(stmt) }

        for symbol in instruments {
            let s = conn.escape(symbol)
            try conn.execute("""
                INSERT INTO instruments (symbol, name, last_price)
                VALUES ('\(s)', '\(s) Corp', 100)
                ON DUPLICATE KEY UPDATE name = VALUES(name)
            """)
        }

        // Seed accounts in one multi-row insert if the table is empty.
        let count = try conn.query("SELECT COUNT(*) FROM accounts")
        let existing = Int(count.first?.first.flatMap { $0 } ?? "0") ?? 0
        if existing < accounts {
            var values: [String] = []
            for i in existing..<accounts {
                values.append("(\(i), 'Trader \(i)', 1000000.00)")
            }
            let chunkSize = 500
            var idx = 0
            while idx < values.count {
                let chunk = values[idx..<min(idx + chunkSize, values.count)]
                try conn.execute("INSERT INTO accounts (id, name, balance) VALUES "
                                 + chunk.joined(separator: ",")
                                 + " ON DUPLICATE KEY UPDATE name = VALUES(name)")
                idx += chunkSize
            }
        }
    }
}
