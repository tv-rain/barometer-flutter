import Foundation

/// Reads the trusted local document (`barometer-trust/1`) that the facade's `NewClient` takes:
/// the local policy and the configuration and context approvals, as strict JSON.
///
/// The document comes only from the application bundle, as the resource `barometer/trust.json`.
/// It is never fetched, and never taken from Dart, method-channel arguments, task data or a
/// network reply. This reader checks only the size bound; the facade decodes and validates the
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
