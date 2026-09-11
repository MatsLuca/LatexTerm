#!/usr/bin/env ruby
# Fügt dem LatexTerm-Projekt die WidgetKit-Extension `LatexTermWidgets` hinzu (idempotent).
#
# Wie add_cli_target.rb / add_test_target.rb: das App-Target ist ein
# PBXFileSystemSynchronizedRootGroup, ein zweites Target hängt man besser per Skript an.
# Die Extension (Desktop-Widgets „Claude-Cockpit" und „Claude Wrapped") ist sandboxed und liest
# nur den Schnappschuss aus dem App-Group-Container (Entitlements-Datei); die App bekommt eine
# Dependency + Copy-Files-Phase „Embed Foundation Extensions" (PlugIns, Code Sign on Copy).
#
#   /opt/homebrew/bin/ruby scripts/add_widgets_target.rb      # braucht das Gem xcodeproj

require "xcodeproj"

PROJECT = "LatexTerm.xcodeproj"
TARGET  = "LatexTermWidgets"
SOURCES = ["LatexTermWidgets/LatexTermWidgets.swift", "LatexTermWidgets/WidgetSnapshot.swift"]
OTHERS  = ["LatexTermWidgets/Info.plist", "LatexTermWidgets/LatexTermWidgets.entitlements"]

proj = Xcodeproj::Project.open(PROJECT)
app  = proj.targets.find { |t| t.name == "LatexTerm" }
raise "App-Target nicht gefunden" unless app

if proj.targets.any? { |t| t.name == TARGET }
  puts "Widget-Target '#{TARGET}' existiert bereits — nichts zu tun."
  exit 0
end

deploy = app.build_configurations.first.build_settings["MACOSX_DEPLOYMENT_TARGET"] || "14.0"
team   = app.build_configurations.first.build_settings["DEVELOPMENT_TEAM"]
ext = proj.new_target(:app_extension, TARGET, :osx, deploy)
ext.product_type = "com.apple.product-type.app-extension"

ext.build_configurations.each do |cfg|
  s = cfg.build_settings
  s["PRODUCT_NAME"]                        = "$(TARGET_NAME)"
  s["PRODUCT_BUNDLE_IDENTIFIER"]           = "com.mats.LatexTerm.Widgets"
  s["MACOSX_DEPLOYMENT_TARGET"]            = deploy
  s["SWIFT_VERSION"]                       = "5.0"
  s["SWIFT_EMIT_LOC_STRINGS"]              = "YES"
  s["CODE_SIGN_STYLE"]                     = "Automatic"
  s["DEVELOPMENT_TEAM"]                    = team if team
  s["CODE_SIGN_ENTITLEMENTS"]              = "LatexTermWidgets/LatexTermWidgets.entitlements"
  s["ENABLE_HARDENED_RUNTIME"]             = "YES"
  s["GENERATE_INFOPLIST_FILE"]             = "YES"
  s["INFOPLIST_FILE"]                      = "LatexTermWidgets/Info.plist"
  s["INFOPLIST_KEY_CFBundleDisplayName"]   = "LatexTerm"
  s["INFOPLIST_KEY_NSHumanReadableCopyright"] = ""
  s["CURRENT_PROJECT_VERSION"]             = "1"
  s["MARKETING_VERSION"]                   = "0.1"
  s["SKIP_INSTALL"]                        = "YES"
  s["LD_RUNPATH_SEARCH_PATHS"]             = ["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"]
end

group = proj.main_group.find_subpath(TARGET, true)
group.set_source_tree("SOURCE_ROOT")
(SOURCES + OTHERS).each do |path|
  ref = proj.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = path
  ref.source_tree = "SOURCE_ROOT"
  ref.name = File.basename(path)
  ref.last_known_file_type = case File.extname(path)
                             when ".swift" then "sourcecode.swift"
                             when ".plist" then "text.plist.xml"
                             when ".entitlements" then "text.plist.entitlements"
                             end
  group.children << ref
  ext.source_build_phase.add_file_reference(ref) if SOURCES.include?(path)
end
ext.add_system_frameworks(["WidgetKit", "SwiftUI"])

app.add_dependency(ext)
phase = app.new_copy_files_build_phase("Embed Foundation Extensions")
phase.symbol_dst_subfolder_spec = :plug_ins
bf = phase.add_file_reference(ext.product_reference)
bf.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }

attrs = proj.root_object.attributes["TargetAttributes"] ||= {}
attrs[ext.uuid] = { "SuppressBuildableAutocreation" => "YES" }

proj.save
puts "Widget-Target '#{TARGET}' angelegt, in LatexTerm.app/Contents/PlugIns eingebettet."
