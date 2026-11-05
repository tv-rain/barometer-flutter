/// Flutter plugin for Barometer, the embeddable network-measurement library.
///
/// [BarometerClient] is the lifecycle API. Only JSON maps, bytes and opaque
/// handles cross to the native layer: no call installs a local policy,
/// approval, trust root, issuer association or adapter. Those come only from
/// the application package, read by Barometer-owned native code.
library;

export 'src/barometer_client.dart';
