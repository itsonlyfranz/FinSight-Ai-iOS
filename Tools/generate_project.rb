require "xcodeproj"

PROJECT_NAME = "FinSightAI".freeze
APP_DIR = PROJECT_NAME
TEST_DIR = "#{PROJECT_NAME}Tests".freeze

project = Xcodeproj::Project.new("#{PROJECT_NAME}.xcodeproj")
project.root_object.attributes["LastSwiftUpdateCheck"] = "1630"
project.root_object.attributes["LastUpgradeCheck"] = "1630"

def ensure_group(root_group, relative_path)
  return root_group if relative_path.nil? || relative_path.empty? || relative_path == "."

  relative_path.split("/").reject(&:empty?).reduce(root_group) do |group, component|
    group.groups.find { |child| child.display_name == component } || group.new_group(component, component)
  end
end

main_group = project.main_group
app_group = main_group.new_group(APP_DIR, APP_DIR)
tests_group = main_group.new_group(TEST_DIR, TEST_DIR)
products_group = project.products_group

app_target = project.new_target(:application, PROJECT_NAME, :ios, "18.0")
app_target.product_reference.name = "#{PROJECT_NAME}.app"
test_target = project.new_target(:unit_test_bundle, TEST_DIR, :ios, "18.0")
test_target.product_reference.name = "#{TEST_DIR}.xctest"
test_target.add_dependency(app_target)

app_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.finsightai.app"
  config.build_settings["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = "YES"
  config.build_settings["INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents"] = "YES"
  config.build_settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
  config.build_settings["INFOPLIST_KEY_CFBundleDisplayName"] = "FinSight AI"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "18.0"
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = ""
  config.build_settings["ENABLE_PREVIEWS"] = "YES"
  config.build_settings["DEVELOPMENT_ASSET_PATHS"] = "\"FinSightAI/Preview Content\""
  config.build_settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
end

test_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.finsightai.tests"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "18.0"
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/FinSightAI.app/FinSightAI"
  config.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
end

swift_files = Dir.glob("#{APP_DIR}/**/*.swift").sort
asset_catalogs = Dir.glob("#{APP_DIR}/**/*.xcassets").sort

swift_files.each do |path|
  parent = File.dirname(path)
  group = ensure_group(app_group, parent.sub(%r{\A#{APP_DIR}/?}, ""))
  file_ref = group.new_file(File.basename(path))
  app_target.add_file_references([file_ref])
end

asset_catalogs.each do |path|
  parent = File.dirname(path)
  group = ensure_group(app_group, parent.sub(%r{\A#{APP_DIR}/?}, ""))
  file_ref = group.new_file(File.basename(path))
  app_target.resources_build_phase.add_file_reference(file_ref, true)
end

Dir.glob("#{TEST_DIR}/**/*.swift").sort.each do |path|
  group = ensure_group(tests_group, File.dirname(path).sub(%r{\A#{TEST_DIR}/?}, ""))
  file_ref = group.new_file(File.basename(path))
  test_target.add_file_references([file_ref])
end

project.save
