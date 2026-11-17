import os

/// Unified logging. Rules: never log prompt / completion / chat / file content, API keys, or
/// bound SQL values. Log identifiers, counts, durations and error categories only.
public enum Log {
    public static let subsystem = "app.layx"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let inference = Logger(subsystem: subsystem, category: "inference")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let models = Logger(subsystem: subsystem, category: "models")
    public static let work = Logger(subsystem: subsystem, category: "work")
    public static let server = Logger(subsystem: subsystem, category: "server")
}
