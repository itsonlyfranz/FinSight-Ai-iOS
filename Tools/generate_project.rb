require "xcodeproj"

DEPLOYMENT_TARGET = "26.0".freeze
SWIFT_VERSION = "6.0".freeze
MARKDOWN_UI_URL = "https://github.com/gonzalezreal/swift-markdown-ui".freeze
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

app_target = project.new_target(:application, PROJECT_NAME, :ios, DEPLOYMENT_TARGET)
app_target.product_reference.name = "#{PROJECT_NAME}.app"
test_target = project.new_target(:unit_test_bundle, TEST_DIR, :ios, DEPLOYMENT_TARGET)
test_target.product_reference.name = "#{TEST_DIR}.xctest"
test_target.add_dependency(app_target)

app_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.finsightai.app"
  config.build_settings["CURRENT_PROJECT_VERSION"] = "1"
  config.build_settings["MARKETING_VERSION"] = "1.0"
  config.build_settings["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = "YES"
  config.build_settings["INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents"] = "YES"
  config.build_settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
  config.build_settings["INFOPLIST_KEY_CFBundleDisplayName"] = "FinSight AI"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["SWIFT_VERSION"] = SWIFT_VERSION
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  config.build_settings["ENABLE_PREVIEWS"] = "YES"
  config.build_settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  config.build_settings["LOCALIZATION_PREFERS_STRING_CATALOGS"] = "YES"
end

test_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.finsightai.tests"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["SWIFT_VERSION"] = SWIFT_VERSION
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
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

# Privacy manifest (required by App Store Connect).
privacy_manifest = "#{APP_DIR}/PrivacyInfo.xcprivacy"
if File.exist?(privacy_manifest)
  file_ref = app_group.new_file(File.basename(privacy_manifest))
  app_target.resources_build_phase.add_file_reference(file_ref, true)
end

# String Catalog: English source strings with Filipino (fil) translations.
string_catalog = "#{APP_DIR}/Localizable.xcstrings"
string_catalog_ref = nil
if File.exist?(string_catalog)
  string_catalog_ref = app_group.new_file(File.basename(string_catalog))
  app_target.resources_build_phase.add_file_reference(string_catalog_ref, true)
end
project.root_object.development_region = "en"
project.root_object.known_regions = ["en", "Base", "fil"]

# Swift package: MarkdownUI (renders AI responses).
markdown_package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
markdown_package.repositoryURL = MARKDOWN_UI_URL
markdown_package.requirement = { "kind" => "upToNextMajorVersion", "minimumVersion" => "2.4.1" }
project.root_object.package_references << markdown_package

markdown_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
markdown_product.package = markdown_package
markdown_product.product_name = "MarkdownUI"
app_target.package_product_dependencies << markdown_product

markdown_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
markdown_build_file.product_ref = markdown_product
app_target.frameworks_build_phase.files << markdown_build_file

# Widget extension shares the persistence and deterministic calculation sources.
widget_group = main_group.new_group("FinSightWidgets", "FinSightWidgets")
widget_target = project.new_target(:app_extension, "FinSightWidgets", :ios, DEPLOYMENT_TARGET)
widget_target.build_configurations.each do |config|
  config.build_settings.merge!({
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.finsightai.app.widgets",
    "CURRENT_PROJECT_VERSION" => "1", "MARKETING_VERSION" => "1.0",
    "GENERATE_INFOPLIST_FILE" => "YES", "INFOPLIST_FILE" => "FinSightWidgets/Info.plist",
    "CODE_SIGN_ENTITLEMENTS" => "FinSightWidgets/FinSightWidgets.entitlements",
    "SWIFT_VERSION" => SWIFT_VERSION, "TARGETED_DEVICE_FAMILY" => "1",
    "SWIFT_EMIT_LOC_STRINGS" => "YES", "LOCALIZATION_PREFERS_STRING_CATALOGS" => "YES",
    "APPLICATION_EXTENSION_API_ONLY" => "YES", "SKIP_INSTALL" => "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "$(inherited) WIDGET_EXTENSION",
    "CODE_SIGN_STYLE" => "Automatic"
  })
end
Dir.glob("FinSightWidgets/*.swift").sort.each { |path| widget_target.add_file_references([widget_group.new_file(File.basename(path))]) }
shared_files = swift_files.select do |path|
  path.start_with?("#{APP_DIR}/Models/", "#{APP_DIR}/Utils/", "#{APP_DIR}/Services/Insights/") ||
    ["Services/Simulation/ForwardSimulator.swift", "Services/Simulation/RunRateBaseline.swift", "Services/Simulation/ScenarioComparison.swift", "Services/SimulationService.swift", "Services/CapabilityService.swift", "Services/PlanningCalculators.swift", "Services/RecurringExpenseRepository.swift",
     "Services/SwiftDataTransactionRepository.swift", "Services/TransactionRepository.swift",
     "Services/AI/LedgerSnapshot.swift", "Services/AI/NarrationContext.swift", "App/StoreRecovery.swift"].any? { |suffix| path == "#{APP_DIR}/#{suffix}" } ||
    ["SharedStore.swift", "SystemSnapshot.swift", "ExpenseControlIntent.swift"].any? { |name| path == "#{APP_DIR}/Services/System/#{name}" }
end
shared_files.each do |path|
  ref = project.files.find { |file| file.real_path.to_s == File.expand_path(path) }
  widget_target.add_file_references([ref])
end
privacy_ref = project.files.find { |file| file.real_path.to_s == File.expand_path(privacy_manifest) }
widget_target.resources_build_phase.add_file_reference(privacy_ref, true) if privacy_ref
widget_target.resources_build_phase.add_file_reference(string_catalog_ref, true) if string_catalog_ref
app_target.add_dependency(widget_target)
embed = app_target.new_copy_files_build_phase("Embed App Extensions")
embed.dst_subfolder_spec = "13"
embed.add_file_reference(widget_target.product_reference, true).settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
app_target.build_configurations.each do |config|
  config.build_settings["INFOPLIST_FILE"] = "FinSightAI/Info.plist"
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] = "FinSightAI/FinSightAI.entitlements"
end

project.save

# Shared scheme, so command-line builds and CI don't depend on auto-generated schemes.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_test_target(test_target)
scheme.set_launch_target(app_target)
scheme.save_as(project.path, PROJECT_NAME, true)
