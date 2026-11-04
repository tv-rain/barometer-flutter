Pod::Spec.new do |s|
  s.name             = 'barometer_flutter'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin for the Barometer network-measurement library.'
  s.description      = 'Flutter plugin for the Barometer embeddable network-measurement library.'
  s.homepage         = 'https://github.com/tv-rain/barometer-flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'TVR Studios B.V.'
  s.source           = { :path => '.' }
  s.source_files     = 'barometer_flutter/Sources/barometer_flutter/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  # Built by scripts/build-native.sh; not tracked in Git.
  s.vendored_frameworks = 'Frameworks/Barometer.xcframework'

  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
