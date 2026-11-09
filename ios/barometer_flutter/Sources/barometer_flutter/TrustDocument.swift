import Foundation

/// Reads the trusted local document (`barometer-trust/1`) that the facade's `NewClient` takes:
/// the local policy and the configuration and context approvals, as strict JSON.
///
/// The document comes only from the application bundle, as the resource `barometer/trust.json`
/// that the host packages with its release, and reaches the channel host's client through the
/// host policy adapter (`HostPolicy`). It is never fetched, and never taken from Dart,
/// method-channel arguments, task data or a network reply. This reader checks only the size bound; the facade decodes and validates the
/// content and rejects an invalid document as `trust_invalid`.
enum TrustDocument {
  /// The resource's subdirectory, name and extension in the application bundle.
  static let directory = "barometer"
  static let name = "trust"
  static let fileExtension = "json"

  /// The facade's size bound for the document.
  static let maxBytes = 1 << 20

  /// Returns the document bytes from `bundle`, or throws if it is missing or too large.
  static func read(
    bundle: Bundle = .main, name: String = TrustDocument.name, directory: String = TrustDocument.directory
  ) throws -> Data {
    guard let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: directory)
    else { throw AdapterUnavailableError() }
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values?.isRegularFile == true, let size = values?.fileSize, size > 0, size <= maxBytes else {
      throw AdapterUnavailableError()
    }
    guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= maxBytes else {
      throw AdapterUnavailableError()
    }
    return data
  }
}

extension TrustDocument {
  /// Returns the issuer of embedded tasks named by `document`, or nil when there is none.
  ///
  /// It is the one issuer of the policy that has no trusted key. An issuer with a key can sign
  /// remote packages; a keyless issuer can only be reached through an embedded delivery, so it is
  /// the document's embedded issuer. Zero or several keyless issuers leave the association
  /// undefined, and embedded tasks are then not installed. Call this only with a document the
  /// facade has accepted, which has already been validated in full.
  static func embeddedIssuer(_ document: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
      let policy = root["policy"] as? [String: Any],
      let keys = policy["keys"] as? [Any],
      let issuers = policy["issuers"] as? [Any]
    else { return nil }
    var keyed = Set<String>()
    for key in keys {
      guard let id = (key as? [String: Any])?["issuer_id"] as? String else { return nil }
      keyed.insert(id)
    }
    var keyless = Set<String>()
    for issuer in issuers {
      guard let id = (issuer as? [String: Any])?["issuer_id"] as? String else { return nil }
      if !keyed.contains(id) { keyless.insert(id) }
    }
    return keyless.count == 1 ? keyless.first : nil
  }
}

/// Returns the bytes of the bundle resource at `url`, or nil if it is missing, unreadable, empty
/// or larger than `max` bytes. It stops reading once more than `max` bytes have arrived.
func readResource(_ url: URL, max: Int) -> Data? {
  guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
  defer { try? handle.close() }
  var data = Data()
  do {
    while data.count <= max {
      guard let chunk = try handle.read(upToCount: 8192), !chunk.isEmpty else { break }
      data.append(chunk)
    }
  } catch {
    return nil
  }
  return data.isEmpty || data.count > max ? nil : data
}
