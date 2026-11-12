#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the PubkyRingCredentialProvider app extension (ios/PubkyRingCredentialProvider) to
# ios/pubkyring.xcodeproj and embeds it in the app. Safe to run more than once.
#
#   ruby scripts/passkey/add-ios-credential-provider.rb
#
# Needs the xcodeproj gem, which CocoaPods already installs. Fill in ios/Config/Signing.xcconfig first.
# Undo with: git checkout ios/pubkyring.xcodeproj/project.pbxproj

require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
PROJECT_PATH = File.join(ROOT, 'ios', 'pubkyring.xcodeproj')
TARGET_NAME = 'PubkyRingCredentialProvider'
EXTENSION_DIR = File.join(ROOT, 'ios', TARGET_NAME)
PUBKY_IOS = File.join(ROOT, 'node_modules', '@synonymdev', 'react-native-pubky', 'ios')
DEPLOYMENT_TARGET = '17.0'

abort "Run yarn install first: #{PUBKY_IOS} is missing" unless File.directory?(PUBKY_IOS)

project = Xcodeproj::Project.open(PROJECT_PATH)
app = project.targets.find { |target| target.name == 'pubkyring' } or abort 'pubkyring target not found'

if project.targets.any? { |target| target.name == TARGET_NAME }
  puts "#{TARGET_NAME} is already in the project"
  exit 0
end

extension = project.new_target(:app_extension, TARGET_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)
# new_target links Foundation by a path tied to the local SDK version; Swift links it automatically.
extension.frameworks_build_phase.files.dup.each do |build_file|
  ref = build_file.file_ref
  extension.frameworks_build_phase.remove_build_file(build_file)
  ref.remove_from_project if ref && ref.build_files.empty?
end

group = project.main_group.new_group(TARGET_NAME, TARGET_NAME)
Dir[File.join(EXTENSION_DIR, '*.swift')].sort.each do |path|
  extension.add_file_references([group.new_reference(File.basename(path))])
end
group.new_reference('Info.plist')
group.new_reference("#{TARGET_NAME}.entitlements")

# The consent sheet draws Ring's fonts, shield and translations from the extension bundle.
resources = group.new_group('Resources')
%w[Regular Medium SemiBold Bold].each do |weight|
  extension.add_resources([resources.new_reference("../../assets/fonts/InterTight-#{weight}.ttf")])
end
extension.add_resources([resources.new_reference('../../src/images/shield.png')])
%w[en es].each do |language|
  extension.add_resources([resources.new_reference("../../src/i18n/locales/#{language}.json")])
end

# PubkyCore: the uniffi Swift bindings compile into the extension. Link the static
# library directly. Adding the xcframework copies its module map into the shared
# build include directory and redefines pubkycoreFFI for the app target.
core = group.new_group('PubkyCore')
extension.add_file_references([core.new_reference(File.join(PUBKY_IOS, 'pubkycore.swift'))])
pubky_core = '$(SRCROOT)/../node_modules/@synonymdev/react-native-pubky/ios/Frameworks/PubkyCore.xcframework'

app_settings = app.build_configurations.first.build_settings
extension.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(RING_PASSKEY_EXTENSION_ID)'
  settings['DEVELOPMENT_TEAM'] = '$(RING_DEVELOPMENT_TEAM)'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CODE_SIGN_ENTITLEMENTS'] = "#{TARGET_NAME}/#{TARGET_NAME}.entitlements"
  settings['INFOPLIST_FILE'] = "#{TARGET_NAME}/Info.plist"
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['SWIFT_VERSION'] = '5.0'
  settings['MARKETING_VERSION'] = app_settings['MARKETING_VERSION'] if app_settings['MARKETING_VERSION']
  settings['CURRENT_PROJECT_VERSION'] = app_settings['CURRENT_PROJECT_VERSION'] if app_settings['CURRENT_PROJECT_VERSION']
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['SKIP_INSTALL'] = 'YES'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  # The xcframework ships arm64 slices only, like react-native-pubky's podspec.
  settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'x86_64'
  settings['LIBRARY_SEARCH_PATHS[sdk=iphoneos*]'] = "#{pubky_core}/ios-arm64"
  settings['LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]'] = "#{pubky_core}/ios-arm64-simulator"
  settings['SWIFT_INCLUDE_PATHS[sdk=iphoneos*]'] = "#{pubky_core}/ios-arm64/Headers"
  settings['SWIFT_INCLUDE_PATHS[sdk=iphonesimulator*]'] = "#{pubky_core}/ios-arm64-simulator/Headers"
  settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lpubkycore', '-framework', 'SystemConfiguration', '-framework', 'Security', '-lresolv']
end

embed = app.copy_files_build_phases.find { |phase| phase.name == 'Embed Foundation Extensions' } ||
        app.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.add_file_reference(extension.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
app.add_dependency(extension)

project.save
puts "Added #{TARGET_NAME}. Open ios/pubkyring.xcworkspace and build the pubkyring scheme."
