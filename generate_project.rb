require 'xcodeproj'

project_name = 'ManualCameraApp'
project_path = "#{project_name}.xcodeproj"

# Remove existing empty project if it exists to start fresh
`rm -rf "#{project_path}"`

project = Xcodeproj::Project.new(project_path)
target = project.new_target(:application, project_name, :ios, '17.0')

# Correct the Main Group setup so files actually show up in Xcode
main_group = project.main_group
app_group = main_group.new_group(project_name)
sources_group = app_group.new_group('Sources', 'Sources')

# Add all .swift files
swift_files = Dir.glob('Sources/*.swift')
file_refs = []
swift_files.each do |file|
  file_refs << sources_group.new_reference(File.basename(file))
end

target.add_file_references(file_refs)

# Add Info.plist reference structurally 
info_plist_ref = app_group.new_reference('Info.plist', 'Info.plist')

# Build Settings 
target.build_configurations.each do |config|
  config.build_settings['INFOPLIST_FILE'] = 'Info.plist'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "com.example.#{project_name}"
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1' # iPhone
  config.build_settings['PRODUCT_NAME'] = project_name
end

project.save
puts "Rebuilt #{project_path}"
