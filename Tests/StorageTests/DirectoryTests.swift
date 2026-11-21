import Foundation
import Testing

@testable import Tefter

@Test func pinnedDirectoryRetainsIdentityWhenRenamed() throws {
  let fm = FileManager.default
  let rootURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at: rootURL, withIntermediateDirectories: false)
  defer { try? fm.removeItem(at: rootURL) }
  let root = try Directory(root: rootURL.path)
  let folder = try root.directory("original", create: true)
  try fm.moveItem(
    at: rootURL.appendingPathComponent("original"), to: rootURL.appendingPathComponent("renamed"))
  _ = try root.directory("replacement", create: true)
  try fm.createSymbolicLink(
    at: rootURL.appendingPathComponent("original"),
    withDestinationURL: rootURL.appendingPathComponent("replacement"))
  try folder.write("sample.md", data: Data("pinned".utf8), replacing: false)
  #expect(try root.directory("replacement").entries().isEmpty)
  #expect(try root.directory("renamed").read("sample.md") == Data("pinned".utf8))
  #expect(throws: (any Error).self) { try root.directory("original") }
}

@Test func privateMetadataNamesAreSingleComponents() {
  for name in ["/notes", "../notes", "nested/notes", "notes\0.md", "..", "."] {
    #expect(throws: (any Error).self) { try Directory.singleName(name) }
  }
  #expect(throws: (any Error).self) { try Directory.components("notes/.TEFTER/comments") }
}
