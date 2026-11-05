import Barometer
import Foundation

/// The only file that names gomobile-generated types: the `barometermobile` facade.
///
/// The types come from the standalone `Barometer.xcframework` or, in an umbrella build,
/// from the umbrella artifact. Naming a type makes the plugin link against the framework
/// without calling into Go; constructing a facade value does.
enum BarometerBinding {
  static let clientType: BarometermobileClient.Type = BarometermobileClient.self

  /// The facade `Records` callback backed by `store`.
  static func records(_ store: RecordStore) -> BarometermobileRecordsProtocol {
    StoreRecords(store)
  }
}

/// Adapts `RecordStore` to the facade callback. Every failure surfaces as the store's
/// detail-free error, which the facade reports as unavailable.
private final class StoreRecords: NSObject, BarometermobileRecordsProtocol {
  private let store: RecordStore

  init(_ store: RecordStore) {
    self.store = store
  }

  /// A key the store does not hold is the facade's absent value: Swift cannot return nil here
  /// without throwing, and the facade reads a nil return as unavailable.
  func get(_ key: String?, timeoutMillis: Int64) throws -> BarometermobileRecordValue {
    guard let key else { throw RecordStoreError() }
    let value: BarometermobileRecordValue?
    if let data = try store.get(key, timeoutMillis: timeoutMillis) {
      value = BarometermobileNewRecordValue(data)
    } else {
      value = BarometermobileNewAbsentRecordValue()
    }
    guard let value else { throw RecordStoreError() }
    return value
  }

  func put(_ key: String?, value: Data?, timeoutMillis: Int64) throws {
    guard let key else { throw RecordStoreError() }
    try store.put(key, value ?? Data(), timeoutMillis: timeoutMillis)
  }

  func delete(_ key: String?, timeoutMillis: Int64) throws {
    guard let key else { throw RecordStoreError() }
    try store.delete(key, timeoutMillis: timeoutMillis)
  }

  func list(_ class: Int64, timeoutMillis: Int64) throws -> BarometermobileStringList {
    let keys = try store.list(`class`, timeoutMillis: timeoutMillis)
    guard let list = BarometermobileNewStringList() else { throw RecordStoreError() }
    for key in keys { list.add(key) }
    return list
  }
}
