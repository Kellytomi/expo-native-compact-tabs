Pod::Spec.new do |s|
  s.name           = 'ExpoNativeCompactTabs'
  s.version        = '0.2.0'
  s.summary        = 'A standalone UIKit tab bar that keeps every tab visible when compact.'
  s.description    = 'Hosts a real UITabBar while React Native owns navigation and compact-state policy.'
  s.license        = { :type => 'MIT' }
  s.author         = 'Etoma-etoto Odi'
  s.homepage       = 'https://github.com/Kellytomi/expo-native-compact-tabs'
  s.platforms      = { :ios => '16.4' }
  s.source         = { :git => 'https://github.com/Kellytomi/expo-native-compact-tabs.git', :tag => s.version.to_s }
  s.static_framework = true
  s.source_files   = '**/*.{h,m,mm,swift}'
  s.dependency 'ExpoModulesCore'
  s.swift_version = '5.9'
end
