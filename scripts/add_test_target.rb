#!/usr/bin/env ruby
# Fügt dem LatexTerm-Projekt ein Logic-Unit-Test-Target hinzu (idempotent).
#
# Warum dieses Script existiert: Das App-Target nutzt einen
# PBXFileSystemSynchronizedRootGroup (Xcode-16-Auto-Sync-Ordner), in dem Dateien
# nicht einzeln referenziert sind. Ein normales "Datei zu Target hinzufügen" per
# GUI ist hier umständlich. Das Test-Target ist ein Logic-Test (KEIN Test-Host):
# die App startet beim Testen nicht, kein PTY/SwiftTerm/Metal nötig fürs Bundle.
# Es kompiliert die beiden reinen Quelldateien direkt mit.

require "xcodeproj"

PROJECT  = "LatexTerm.xcodeproj"
TARGET   = "LatexTermTests"
TESTS    = ["LatexTermTests/LaTeXDetectorTests.swift", "LatexTermTests/LaTeXReadableTests.swift"]
# Source-under-test: reine Foundation-Logik, direkt ins Test-Target kompiliert.
SOURCES  = ["LatexTerm/Latex/LaTeXDetector.swift", "LatexTerm/Latex/LaTeXReadable.swift"]

proj = Xcodeproj::Project.open(PROJECT)
app  = proj.targets.find { |t| t.name == "LatexTerm" }
raise "App-Target nicht gefunden" unless app

if proj.targets.any? { |t| t.name == TARGET }
  puts "Test-Target '#{TARGET}' existiert bereits — nichts zu tun."
  exit 0
end

test_target = proj.new(Xcodeproj::Project::Object::PBXNativeTarget)
proj.targets << test_target
test_target.name = TARGET
test_target.product_name = TARGET
test_target.product_type = "com.apple.product-type.bundle.unit-test"
test_target.build_configuration_list =
  Xcodeproj::Project::ProjectHelper.configuration_list(proj, :osx, nil, :unit_test_bundle)

# Produkt-Referenz (.xctest) in der Products-Gruppe
product_ref = proj.products_group.new_product_ref_for_target(TARGET, :unit_test_bundle)
test_target.product_reference = product_ref

# Build-Settings: Logic-Test ohne Test-Host
deploy = app.build_configurations.first.build_settings["MACOSX_DEPLOYMENT_TARGET"] || "14.0"
test_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"]  = "com.mats.LatexTermTests"
  s["PRODUCT_NAME"]               = "$(TARGET_NAME)"
  s["SWIFT_VERSION"]              = "5.0"
  s["MACOSX_DEPLOYMENT_TARGET"]   = deploy
  s["GENERATE_INFOPLIST_FILE"]    = "YES"
  s["CODE_SIGNING_ALLOWED"]       = "NO"
  s["SDKROOT"]                    = "macosx"
  s["SWIFT_EMIT_LOC_STRINGS"]     = "NO"
end

# Source-Build-Phase befüllen (Tests + Source-under-test)
group = proj.main_group.find_subpath(TARGET, true)
group.set_source_tree("SOURCE_ROOT")
(TESTS + SOURCES).each do |path|
  ref = proj.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = path
  ref.source_tree = "SOURCE_ROOT"
  ref.last_known_file_type = "sourcecode.swift"
  ref.name = File.basename(path)
  group.children << ref
  test_target.source_build_phase.add_file_reference(ref)
end

# Test-Action des bestehenden Schemas um das Test-Target erweitern
proj.save

scheme_path = File.join(PROJECT, "xcshareddata", "xcschemes", "LatexTerm.xcscheme")
if File.exist?(scheme_path)
  scheme = Xcodeproj::XCScheme.new(scheme_path)
  scheme.add_test_target(test_target)
  scheme.save_as(PROJECT, "LatexTerm", true)
  puts "Schema-Test-Action um '#{TARGET}' erweitert."
end

puts "Test-Target '#{TARGET}' angelegt."
