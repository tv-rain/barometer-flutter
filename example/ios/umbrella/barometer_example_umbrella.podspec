# Umbrella mode of the example only: stands in for the application pod that vendors the
# gomobile umbrella framework. Copy or link that framework into ios/umbrella/Frameworks/
# (not tracked in Git); see the README.
Pod::Spec.new do |s|
  s.name             = 'barometer_example_umbrella'
  s.version          = '0.0.1'
  s.summary          = 'Vendors a host-supplied umbrella framework for the barometer_flutter example.'
  s.homepage         = 'https://github.com/tv-rain/barometer-flutter'
  s.license          = { :type => 'MIT', :file => '../../../LICENSE' }
  s.author           = 'TVR Studios B.V.'
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  # A source file gives the pod its own target, which prepares the framework before the
  # pods that depend on it compile.
  s.source_files     = 'Sources/*.swift'
  s.vendored_frameworks = 'Frameworks/*.xcframework'
  s.pod_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
