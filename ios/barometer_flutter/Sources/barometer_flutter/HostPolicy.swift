import CryptoKit
import Foundation

/// The host policy adapter: the only path by which a trusted local document reaches the channel
/// host's facade client, and the gate a replacement document passes before the current one is
/// given up.
///
/// The document comes from `source`, which in production reads the bundle resource
/// `barometer/trust.json` that the host packages with its release (`TrustDocument`); the
/// application's code signature covers it. It never comes from Dart, method-channel arguments,
/// task data, collector replies, targets, proxies or context endpoints. The adapter reads the
/// document at every `initialize`; a document that differs from the active one is a replacement
/// and is activated only by reinitialization, and only when its `policy_generation` is strictly
/// greater than every generation this adapter has activated. A lower or equal generation fails
/// closed with `policy_rejected` and leaves the active policy, its runs and handles untouched; the
/// facade validates the rest of the document before the active client is closed.
///
/// The generation floor lives in memory for the adapter's lifetime: `shared` serves every engine
/// of the process, so a later engine cannot activate an earlier generation either. It is not
/// persisted. An application bundle does not change while its process runs, so across releases
/// the check rests on the App Store's refusal to install an earlier version over a later one and
/// on Go, which rejects admission under a generation below its retained replay records as
/// `policy_rollback`.
final class HostPolicy {
  static let trustInvalid = "trust_invalid"
  static let policyRejected = "policy_rejected"

  /// The process's adapter over the application bundle's trusted local document.
  static let shared = HostPolicy(bundle: .main)

  /// One read of the trusted local document.
  struct Document {
    let bytes: Data
    let generation: Int64
    private let digest: Data

    init(bytes: Data, generation: Int64) {
      self.bytes = bytes
      self.generation = generation
      digest = Data(SHA256.hash(data: bytes))
    }

    /// True when `other` has the same exact bytes.
    func sameAs(_ other: Document) -> Bool { digest == other.digest }
  }

  private let source: () throws -> Data
  private let lock = NSLock()
  private var highest: Document?

  init(source: @escaping () throws -> Data) {
    self.source = source
  }

  /// An adapter over the `barometer/trust.json` resource of `bundle`.
  convenience init(bundle: Bundle) {
    self.init { try TrustDocument.read(bundle: bundle) }
  }

  /// Reads the current document, or throws `trust_invalid` when it is unreadable or has no
  /// positive integer generation.
  func read() throws -> Document {
    let bytes: Data
    do {
      bytes = try source()
    } catch {
      throw HostCodeError(code: Self.trustInvalid)
    }
    guard let generation = Self.generation(bytes) else { throw HostCodeError(code: Self.trustInvalid) }
    return Document(bytes: bytes, generation: generation)
  }

  /// Checks that `next` may become the active document after `active`, the document of the
  /// client still open, or after none. The same bytes as `active` are no replacement and are not
  /// checked here. Throws `policy_rejected` unless `next` has a generation strictly greater than
  /// every activated one or, with no client open, is exactly the highest activated document, as
  /// when a closed client is initialized again.
  func check(_ next: Document, active: Document?) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let floor = highest else { return }
    let reopened = active == nil && next.sameAs(floor)
    if next.generation <= floor.generation && !reopened {
      throw HostCodeError(code: Self.policyRejected)
    }
  }

  /// Records `document` as activated, raising the floor.
  func activated(_ document: Document) {
    lock.lock()
    defer { lock.unlock() }
    if let floor = highest, document.generation <= floor.generation { return }
    highest = document
  }

  /// The `policy.generation` of `document`, or nil when it is not a strict JSON object with an
  /// integer generation in the facade's range 1 to 2^63-1. The document is read with `StrictJSON`
  /// under the facade's trusted-document bounds, so a repeated or escaped-equivalent member name,
  /// an integer in another spelling (`-0`, `7.0`, `7e0`) or out of range, invalid UTF-8 or a
  /// byte-order mark yields no generation, as the facade selects none; an escaped spelling of
  /// `generation` is the same member. Unknown members are left to the facade, which rejects them.
  static func generation(_ document: Data) -> Int64? {
    guard let root = try? StrictJSON.decode(document, limits: StrictJSON.trustDocument) else { return nil }
    return root["policy"]?["generation"]?.integer(in: 1...Int64.max)
  }
}
