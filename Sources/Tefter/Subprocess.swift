import Foundation
import Hummingbird
import PreviewTransport

struct ExecutionResult: Sendable {
  let output: Data
  let exitCode: Int32
  let outcome: String
}

enum Subprocess {
  static func run(executable: String, arguments: [String], environment: [String: String],
    directory: String, input: Data, timeout: Int = 30, maximum: Int = 1_048_576
  ) async -> ExecutionResult {
    await Task.detached(priority: .utility) {
      let args = ([executable] + arguments).map { strdup($0) } + [nil]
      let env = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
      defer { args.forEach { free($0) }; env.forEach { free($0) } }
      var output: UnsafeMutablePointer<CChar>?
      var length = 0
      var code: Int32 = -1
      let result = args.withUnsafeBufferPointer { argv in
        env.withUnsafeBufferPointer { envp in
          input.withUnsafeBytes { bytes in
            tefter_subprocess(executable, argv.baseAddress, envp.baseAddress, directory,
              bytes.baseAddress, bytes.count, Int32(timeout * 1000), maximum, &output, &length, &code)
          }
        }
      }
      defer { free(output) }
      return ExecutionResult(output: output.map { Data(bytes: $0, count: length) } ?? Data(),
        exitCode: code, outcome: result == 1 ? "timed-out" : result == 2 ? "output-limit" :
          result != 0 || code != 0 ? "failed" : "completed")
    }.value
  }
}
