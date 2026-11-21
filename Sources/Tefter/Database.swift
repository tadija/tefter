import CSQLite
import Foundation

/// Owned by the workspace actor. All calls, including transaction closures, are synchronous.
final class Database {
  private let handle: OpaquePointer
  enum Failure: Error { case sqlite(Int32) }

  init(path: String) throws {
    var pointer: OpaquePointer?
    let result = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard result == SQLITE_OK, let pointer else {
      sqlite3_close(pointer)
      throw Failure.sqlite(result)
    }
    handle = pointer
    sqlite3_busy_timeout(handle, 5000)
    try execute("PRAGMA foreign_keys=ON")
  }

  deinit { sqlite3_close(handle) }

  func execute(_ sql: String, _ arguments: [String] = []) throws {
    _ = try rows(sql, arguments)
  }

  func rows(_ sql: String, _ arguments: [String] = []) throws -> [[String: String]] {
    var statement: OpaquePointer?
    var result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard result == SQLITE_OK else { throw Failure.sqlite(result) }
    defer { sqlite3_finalize(statement) }
    for (offset, argument) in arguments.enumerated() {
      result = sqlite3_bind_text(
        statement, Int32(offset + 1), argument, Int32(argument.utf8.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      guard result == SQLITE_OK else { throw Failure.sqlite(result) }
    }
    var records = [[String: String]]()
    while true {
      result = sqlite3_step(statement)
      if result == SQLITE_DONE { return records }
      guard result == SQLITE_ROW else { throw Failure.sqlite(result) }
      var record = [String: String]()
      for index in 0..<sqlite3_column_count(statement) {
        if let value = sqlite3_column_text(statement, index) {
          record[String(cString: sqlite3_column_name(statement, index))] = String(
            decoding: UnsafeBufferPointer(
              start: value, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
        }
      }
      records.append(record)
    }
  }

  func transaction<T>(_ work: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let value = try work()
      try execute("COMMIT")
      return value
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
}
