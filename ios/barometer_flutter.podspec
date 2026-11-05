# Standalone mode (default): the plugin vendors its own Barometer.xcframework.
#
# Umbrella mode: the plugin compiles against the barometermobile facade inside a gomobile
# umbrella framework that another pod of the application vendors, and ships no native
# library of its own. Set both variables in the environment of `pod install`, for example at
# the top of the application's Podfile:
#
#   ENV['BAROMETER_FLUTTER_UMBRELLA_POD'] = '<pod that vendors the umbrella framework>'
#   ENV['BAROMETER_FLUTTER_UMBRELLA_MODULE'] = '<module name of the umbrella framework>'
#
# They make `Umbrella` the default subspec, which is what a Flutter application's Podfile
# installs. Umbrella mode needs static linkage (`use_frameworks! :linkage => :static` or no
# `use_frameworks!`), so that the facade symbols resolve once, in the application binary.
umbrella_pod = ENV.fetch('BAROMETER_FLUTTER_UMBRELLA_POD', '').strip
umbrella_module = ENV.fetch('BAROMETER_FLUTTER_UMBRELLA_MODULE', '').strip
if umbrella_pod.empty? != umbrella_module.empty?
  raise 'barometer_flutter: set both BAROMETER_FLUTTER_UMBRELLA_POD and BAROMETER_FLUTTER_UMBRELLA_MODULE, or neither'
end
unless umbrella_module.empty? || umbrella_module.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
  raise 'barometer_flutter: BAROMETER_FLUTTER_UMBRELLA_MODULE must be a module name'
end

Pod::Spec.new do |s|
  s.name             = 'barometer_flutter'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin for the Barometer network-measurement library.'
  s.description      = 'Flutter plugin for the Barometer embeddable network-measurement library.'
  s.homepage         = 'https://github.com/tv-rain/barometer-flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'TVR Studios B.V.'
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.default_subspecs = umbrella_pod.empty? ? 'Standalone' : 'Umbrella'

  s.subspec 'Standalone' do |ss|
    ss.source_files = 'barometer_flutter/Sources/barometer_flutter/**/*.swift'
    # Built by scripts/build-native.sh; not tracked in Git.
    ss.vendored_frameworks = 'Frameworks/Barometer.xcframework'
  end

  s.subspec 'Umbrella' do |ss|
    ss.source_files = 'barometer_flutter/Sources/barometer_flutter/**/*.swift'
    ss.preserve_paths = 'barometer_flutter/Umbrella/*'
    ss.dependency umbrella_pod unless umbrella_pod.empty?
    ss.pod_target_xcconfig = {
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) BAROMETER_UMBRELLA',
      'SWIFT_INCLUDE_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/barometer_flutter/Umbrella"',
      'OTHER_SWIFT_FLAGS' => "$(inherited) -Xcc -DBAROMETER_UMBRELLA_MODULE=#{umbrella_module}",
    }
  end
end
