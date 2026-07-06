#!/usr/bin/env ruby
# Fügt dem LatexTerm-Projekt das `latexterm`-CLI-Target hinzu (idempotent, #28).
#
# Gleiche Begründung wie add_test_target.rb: das App-Target ist ein
# PBXFileSystemSynchronizedRootGroup — Dateien per GUI in ein ZWEITES Target zu
# hängen ist umständlich. Das CLI kompiliert seine main.swift plus die geteilte
# Protokoll-Datei (LatexTerm/Control/ControlProtocol.swift) direkt; das App-Target
# bekommt eine Dependency + Copy-Files-Phase, die das Tool nach
# LatexTerm.app/Contents/MacOS/latexterm einbettet (Code Sign on Copy).

require "xcodeproj"

PROJECT = "LatexTerm.xcodeproj"
# Target/Modul heißen bewusst NICHT "latexterm": auf case-insensitivem APFS
# kollidierten sonst Intermediates ("Debug/latexterm.build" ≡ "Debug/LatexTerm.build")
# und Products ("latexterm.swiftmodule" ≡ "LatexTerm.swiftmodule") mit dem App-Target —
# die App überschreibt dann die SwiftFileList des CLI. Nur die Binary heißt latexterm.
TARGET  = "LatexTermCLI"
BINARY  = "latexterm"
SOURCES = ["LatexTermCLI/main.swift", "LatexTerm/Control/ControlProtocol.swift"]

proj = Xcodeproj::Project.open(PROJECT)
app  = proj.targets.find { |t| t.name == "LatexTerm" }
raise "App-Target nicht gefunden" unless app

if proj.targets.any? { |t| t.name == TARGET }
  puts "CLI-Target '#{TARGET}' existiert bereits — nichts zu tun."
  exit 0
end

deploy = app.build_configurations.first.build_settings["MACOSX_DEPLOYMENT_TARGET"] || "14.0"
cli = proj.new_target(:tool, TARGET, :osx, deploy)
# Ältere xcodeproj-Gems persistieren product_type für :tool nicht — ohne den
# Schlüssel verweigert Xcode 26 den Build ("productTypeIdentifier missing").
cli.product_type = "com.apple.product-type.tool"
cli.product_reference.path = BINARY   # Copy-Phase muss die echte Binary finden

cli.build_configurations.each do |cfg|
  s = cfg.build_settings
  s["PRODUCT_NAME"]             = BINARY
  s["PRODUCT_MODULE_NAME"]      = TARGET
  s["SWIFT_VERSION"]            = "5.0"
  s["MACOSX_DEPLOYMENT_TARGET"] = deploy
  s["CODE_SIGNING_ALLOWED"]     = "NO"   # wie CI-Builds; Embed signiert on copy
  s["SKIP_INSTALL"]             = "YES"
  s["SWIFT_EMIT_LOC_STRINGS"]   = "NO"
end

group = proj.main_group.find_subpath("LatexTermCLI", true)
group.set_source_tree("SOURCE_ROOT")
SOURCES.each do |path|
  ref = proj.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = path
  ref.source_tree = "SOURCE_ROOT"
  ref.last_known_file_type = "sourcecode.swift"
  ref.name = File.basename(path)
  group.children << ref
  cli.source_build_phase.add_file_reference(ref)
end

# Kein eigenes Xcode-Schema fürs CLI: sonst schaltet Xcode nach dem Anlegen des
# Targets still das aktive Schema um und Cmd+R startet die CLI statt der App.
attrs = proj.root_object.attributes["TargetAttributes"] ||= {}
attrs[cli.uuid] = { "SuppressBuildableAutocreation" => "YES" }

# Ins App-Bundle einbetten — nach Contents/Helpers, NICHT Contents/MacOS: dort
# läge `latexterm` auf case-insensitivem APFS auf demselben Dateinamen wie die
# App-Binary `LatexTerm` und überschriebe sie (App startet dann als CLI und
# beendet sich sofort mit dem Usage-Text).
app.add_dependency(cli)
embed = app.new_copy_files_build_phase("Embed latexterm CLI")
embed.dst_subfolder_spec = Xcodeproj::Constants::COPY_FILES_BUILD_PHASE_DESTINATIONS[:wrapper]
embed.dst_path = "Contents/Helpers"
bf = embed.add_file_reference(cli.product_reference)
bf.settings = { "ATTRIBUTES" => ["CodeSignOnCopy"] }

proj.save
puts "CLI-Target '#{TARGET}' angelegt und ins App-Bundle eingebettet."
