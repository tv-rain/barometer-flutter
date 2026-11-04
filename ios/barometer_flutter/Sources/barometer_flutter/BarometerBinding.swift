import Barometer

/// The only file that names gomobile-generated types: the `barometermobile` facade.
///
/// The types come from the standalone `Barometer.xcframework` or, in an umbrella build,
/// from the umbrella artifact. Naming the type makes the plugin link against the
/// framework without calling into Go.
enum BarometerBinding {
  static let clientType: BarometermobileClient.Type = BarometermobileClient.self
}
