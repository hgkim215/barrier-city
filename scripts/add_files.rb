# 사용: ruby scripts/add_files.rb <target명> <파일경로>...
# 파일을 그룹 트리에 만들고 지정 타깃의 컴파일 소스에 추가한다(이미 있으면 건너뜀).
#
# 주의: 테스트 타깃("Barrier CityTests") 전용이다. 앱 타깃("Barrier City")에는
# 쓰지 말 것 — 앱 타깃 그룹은 PBXFileSystemSynchronizedRootGroup이라
# `Barrier City/` 아래에 파일을 만들기만 하면 자동으로 포함되고, 이 스크립트를
# 실행하면 set_source_tree 미지원으로 예외가 난다.
require 'xcodeproj'

target_name = ARGV.shift or abort '타깃명 필요'
proj = Xcodeproj::Project.open('Barrier City.xcodeproj')
target = proj.targets.find { |t| t.name == target_name } or abort "타깃 없음: #{target_name}"

ARGV.each do |path|
  next if proj.files.any? { |f| f.real_path.to_s.end_with?(path) }
  parts = path.split('/')
  fname = parts.pop
  group = proj.main_group
  parts.each { |p| group = group.find_subpath(p, true); group.set_source_tree('<group>'); group.set_path(p) if group.path.nil? }
  ref = group.new_file(fname)
  target.add_file_references([ref])
  puts "추가: #{path} -> #{target_name}"
end
proj.save
