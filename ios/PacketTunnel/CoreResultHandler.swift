import Foundation
import Mobile

/// gobind hands results to an Objective-C object; this one forwards them to a
/// closure, on whatever goroutine thread the Core answers from.
final class CoreResultHandler: NSObject, MobileResultHandlerProtocol {
  private let callback: (Data) -> Void

  init(_ callback: @escaping (Data) -> Void) {
    self.callback = callback
  }

  func onResult(_ data: Data?) throws {
    callback(data ?? Data())
  }
}
