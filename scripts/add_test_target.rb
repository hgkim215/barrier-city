# 일회성: Barrier CityTests 유닛 테스트 타깃을 만들고 공유 스킴에 연결한다.
require 'xcodeproj'

proj = Xcodeproj::Project.open('Barrier City.xcodeproj')
abort '이미 존재' if proj.targets.any? { |t| t.name == 'Barrier CityTests' }
app = proj.targets.find { |t| t.name == 'Barrier City' } or abort '앱 타깃 없음'

test = proj.new_target(:unit_test_bundle, 'Barrier CityTests', :visionos,
                       app.deployment_target)
test.build_configurations.each do |c|
  c.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  c.build_settings['TEST_HOST'] =
    '$(BUILT_PRODUCTS_DIR)/Barrier City.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Barrier City'
  c.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.barriercity.BarrierCityTests'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['SWIFT_VERSION'] =
    app.build_configurations.first.build_settings['SWIFT_VERSION'] || '5.0'
end
test.add_dependency(app)

group = proj.main_group.find_subpath('Barrier CityTests', true)
group.set_source_tree('<group>')
group.set_path('Barrier CityTests')
file = group.new_file('SmokeTests.swift')
test.add_file_references([file])
proj.save

# 공유 스킴: 앱 빌드 + 테스트 타깃을 Test 액션에 연결.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(test)
scheme.set_launch_target(app)
scheme.save_as('Barrier City.xcodeproj', 'Barrier City')
puts 'OK'
