#!/usr/bin/env python3
"""Regenerates ManualCameraApp.xcodeproj from the folders on disk (no gems or packages needed).

    python3 tools/generate_xcodeproj.py

* App target `ManualCameraApp`: every .swift and .metal file under Sources/ (recursively) and every
  file under Resources/ as a bundle resource.
* Unit-test target `ManualCameraAppTests`: every .swift file under Tests/ManualCameraAppTests/.
* A shared scheme that builds, runs and tests the app.

Object IDs are derived from file paths, so running the script twice gives an identical project.
Replaces the old generate_project.rb (F14), which only globbed Sources/*.swift and had no tests.
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "ManualCameraApp"
TEST_NAME = "ManualCameraAppTests"
BUNDLE_ID = "com.example.ManualCameraApp"
TEAM = "C3ZVJR656Q"
DEPLOYMENT_TARGET = "17.0"
# Swift language mode. Xcode only accepts 4, 4.2, 5 or 6 here; "5.9" is a compiler version, not a mode.
SWIFT_VERSION = "5.0"
# IOS27_APERTURE_API compiles Capture/ApertureSupport.swift against the iOS 27 SDK (variable aperture).
# Remove it to build with an older Xcode; the app then treats every lens as fixed-aperture.
APP_COMPILATION_CONDITIONS: list[str] = ["IOS27_APERTURE_API"]

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".metal": "sourcecode.metal",
    ".plist": "text.plist.xml",
    ".json": "text.json",
    ".cube": "text",
    ".caf": "file",
    ".png": "image.png",
    ".md": "net.daringfireball.markdown",
}
SOURCE_EXTENSIONS = {".swift", ".metal"}
IGNORED_NAMES = {".DS_Store"}


def oid(key: str) -> str:
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def quote(value: str) -> str:
    safe = all(c.isalnum() or c in "._/$" for c in value) and value != ""
    if safe and not value.startswith("$(") and "-" not in value:
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Project:
    def __init__(self) -> None:
        self.objects: dict[str, dict] = {}
        self.comments: dict[str, str] = {}

    def add(self, key: str, comment: str, fields: dict) -> str:
        identifier = oid(key)
        self.objects[identifier] = fields
        self.comments[identifier] = comment
        return identifier

    def ref(self, identifier: str) -> str:
        comment = self.comments.get(identifier)
        return f"{identifier} /* {comment} */" if comment else identifier

    def render_value(self, value, indent: int) -> str:
        pad = "\t" * indent
        if isinstance(value, dict):
            lines = ["{"]
            for k, v in value.items():
                lines.append(f"{pad}\t{quote(k)} = {self.render_value(v, indent + 1)};")
            lines.append(f"{pad}}}")
            return "\n".join(lines)
        if isinstance(value, list):
            lines = ["("]
            for item in value:
                lines.append(f"{pad}\t{self.render_value(item, indent + 1)},")
            lines.append(f"{pad})")
            return "\n".join(lines)
        if isinstance(value, Ref):
            return self.ref(value.identifier)
        return quote(str(value))

    def render(self, root: str) -> str:
        sections: dict[str, list[str]] = {}
        for identifier in sorted(self.objects):
            fields = self.objects[identifier]
            isa = fields["isa"]
            body = self.render_value(fields, 2)
            sections.setdefault(isa, []).append(f"\t\t{self.ref(identifier)} = {body};")
        out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {", ""]
        for isa in sorted(sections):
            out.append(f"/* Begin {isa} section */")
            out.extend(sections[isa])
            out.append(f"/* End {isa} section */")
            out.append("")
        out.append("\t};")
        out.append(f"\trootObject = {self.ref(root)};")
        out.append("}")
        return "\n".join(out) + "\n"


class Ref:
    def __init__(self, identifier: str) -> None:
        self.identifier = identifier


def collect(directory: Path, extensions: set[str] | None) -> list[Path]:
    if not directory.exists():
        return []
    files = []
    for path in sorted(directory.rglob("*")):
        if path.is_file() and path.name not in IGNORED_NAMES and (extensions is None or path.suffix in extensions):
            files.append(path.relative_to(ROOT))
    return files


def build_group_tree(project: Project, top: str, files: list[Path], file_refs: dict[Path, str]) -> str:
    """Creates nested PBXGroups for `files` (all under `top`) and returns the top group's id."""
    tree: dict = {}
    for path in files:
        node = tree
        for part in path.parts[1:-1]:
            node = node.setdefault(part, {})
        node.setdefault("__files__", []).append(path)

    def make(name: str, node: dict, prefix: str) -> str:
        children = []
        for child in sorted(k for k in node if k != "__files__"):
            children.append(Ref(make(child, node[child], f"{prefix}/{child}")))
        for path in sorted(node.get("__files__", []), key=lambda p: p.name):
            children.append(Ref(file_refs[path]))
        return project.add(f"group:{prefix}", name, {
            "isa": "PBXGroup",
            "children": children,
            "path": name,
            "sourceTree": "<group>",
        })

    return make(top, tree, top)


def main() -> int:
    project = Project()

    app_sources = collect(ROOT / "Sources", SOURCE_EXTENSIONS)
    app_resources = collect(ROOT / "Resources", None)
    test_sources = collect(ROOT / "Tests" / TEST_NAME, {".swift"})
    if not app_sources:
        print("No sources found under Sources/", file=sys.stderr)
        return 1

    file_refs: dict[Path, str] = {}
    for path in app_sources + app_resources + test_sources:
        file_refs[path] = project.add(f"file:{path}", path.name, {
            "isa": "PBXFileReference",
            "lastKnownFileType": FILE_TYPES.get(path.suffix, "file"),
            "path": path.name,
            "sourceTree": "<group>",
        })
    info_plist = project.add("file:Info.plist", "Info.plist", {
        "isa": "PBXFileReference",
        "lastKnownFileType": "text.plist.xml",
        "path": "Info.plist",
        "sourceTree": "<group>",
    })
    app_product = project.add("product:app", f"{PROJECT_NAME}.app", {
        "isa": "PBXFileReference",
        "explicitFileType": "wrapper.application",
        "includeInIndex": "0",
        "path": f"{PROJECT_NAME}.app",
        "sourceTree": "BUILT_PRODUCTS_DIR",
    })
    test_product = project.add("product:tests", f"{TEST_NAME}.xctest", {
        "isa": "PBXFileReference",
        "explicitFileType": "wrapper.cfbundle",
        "includeInIndex": "0",
        "path": f"{TEST_NAME}.xctest",
        "sourceTree": "BUILT_PRODUCTS_DIR",
    })

    def build_files(paths: list[Path], phase: str) -> list[Ref]:
        refs = []
        for path in paths:
            refs.append(Ref(project.add(f"build:{phase}:{path}", f"{path.name} in {phase}", {
                "isa": "PBXBuildFile",
                "fileRef": Ref(file_refs[path]),
            })))
        return refs

    app_sources_phase = project.add("phase:app:sources", "Sources", {
        "isa": "PBXSourcesBuildPhase",
        "buildActionMask": "2147483647",
        "files": build_files(app_sources, "Sources"),
        "runOnlyForDeploymentPostprocessing": "0",
    })
    app_frameworks_phase = project.add("phase:app:frameworks", "Frameworks", {
        "isa": "PBXFrameworksBuildPhase",
        "buildActionMask": "2147483647",
        "files": [],
        "runOnlyForDeploymentPostprocessing": "0",
    })
    app_resources_phase = project.add("phase:app:resources", "Resources", {
        "isa": "PBXResourcesBuildPhase",
        "buildActionMask": "2147483647",
        "files": build_files(app_resources, "Resources"),
        "runOnlyForDeploymentPostprocessing": "0",
    })
    test_sources_phase = project.add("phase:tests:sources", "Sources", {
        "isa": "PBXSourcesBuildPhase",
        "buildActionMask": "2147483647",
        "files": build_files(test_sources, "Sources"),
        "runOnlyForDeploymentPostprocessing": "0",
    })
    test_frameworks_phase = project.add("phase:tests:frameworks", "Frameworks", {
        "isa": "PBXFrameworksBuildPhase",
        "buildActionMask": "2147483647",
        "files": [],
        "runOnlyForDeploymentPostprocessing": "0",
    })
    test_resources_phase = project.add("phase:tests:resources", "Resources", {
        "isa": "PBXResourcesBuildPhase",
        "buildActionMask": "2147483647",
        "files": [],
        "runOnlyForDeploymentPostprocessing": "0",
    })

    # Groups
    top_children = [Ref(build_group_tree(project, "Sources", app_sources, file_refs))]
    if app_resources:
        top_children.append(Ref(build_group_tree(project, "Resources", app_resources, file_refs)))
    if test_sources:
        tests_inner = build_group_tree(project, TEST_NAME, [Path(*p.parts[1:]) for p in test_sources],
                                       {Path(*p.parts[1:]): file_refs[p] for p in test_sources})
        top_children.append(Ref(project.add("group:Tests", "Tests", {
            "isa": "PBXGroup",
            "children": [Ref(tests_inner)],
            "path": "Tests",
            "sourceTree": "<group>",
        })))
    top_children.append(Ref(info_plist))
    products_group = project.add("group:Products", "Products", {
        "isa": "PBXGroup",
        "children": [Ref(app_product), Ref(test_product)],
        "name": "Products",
        "sourceTree": "<group>",
    })
    main_group = project.add("group:main", "", {
        "isa": "PBXGroup",
        "children": top_children + [Ref(products_group)],
        "sourceTree": "<group>",
    })
    project.comments[main_group] = ""

    # Build configurations
    common_debug = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "MTL_FAST_MATH": "YES",
        "ONLY_ACTIVE_ARCH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    }
    common_release = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "MTL_FAST_MATH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "VALIDATE_PRODUCT": "YES",
    }
    app_conditions = " ".join(["$(inherited)"] + APP_COMPILATION_CONDITIONS)
    app_settings = {
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": TEAM,
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": app_conditions,
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_STRICT_CONCURRENCY": "targeted",
        "SWIFT_VERSION": SWIFT_VERSION,
        "TARGETED_DEVICE_FAMILY": "1",
    }
    test_settings = {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": TEAM,
        "GENERATE_INFOPLIST_FILE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + "Tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_STRICT_CONCURRENCY": "targeted",
        "SWIFT_VERSION": SWIFT_VERSION,
        "TARGETED_DEVICE_FAMILY": "1",
        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{PROJECT_NAME}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{PROJECT_NAME}",
    }

    def config_list(owner: str, comment: str, debug: dict, release: dict) -> str:
        debug_id = project.add(f"config:{owner}:Debug", "Debug", {"isa": "XCBuildConfiguration", "buildSettings": debug, "name": "Debug"})
        release_id = project.add(f"config:{owner}:Release", "Release", {"isa": "XCBuildConfiguration", "buildSettings": release, "name": "Release"})
        return project.add(f"configlist:{owner}", comment, {
            "isa": "XCConfigurationList",
            "buildConfigurations": [Ref(debug_id), Ref(release_id)],
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": "Release",
        })

    project_configs = config_list("project", f'Build configuration list for PBXProject "{PROJECT_NAME}"', common_debug, common_release)
    app_configs = config_list("app", f'Build configuration list for PBXNativeTarget "{PROJECT_NAME}"', dict(app_settings), dict(app_settings))
    test_configs = config_list("tests", f'Build configuration list for PBXNativeTarget "{TEST_NAME}"', dict(test_settings), dict(test_settings))

    app_target = project.add("target:app", PROJECT_NAME, {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": Ref(app_configs),
        "buildPhases": [Ref(app_sources_phase), Ref(app_frameworks_phase), Ref(app_resources_phase)],
        "buildRules": [],
        "dependencies": [],
        "name": PROJECT_NAME,
        "productName": PROJECT_NAME,
        "productReference": Ref(app_product),
        "productType": "com.apple.product-type.application",
    })
    project_id = oid("project")
    proxy = project.add("proxy:app", "PBXContainerItemProxy", {
        "isa": "PBXContainerItemProxy",
        "containerPortal": Ref(project_id),
        "proxyType": "1",
        "remoteGlobalIDString": app_target,
        "remoteInfo": PROJECT_NAME,
    })
    dependency = project.add("dependency:app", "PBXTargetDependency", {
        "isa": "PBXTargetDependency",
        "target": Ref(app_target),
        "targetProxy": Ref(proxy),
    })
    test_target = project.add("target:tests", TEST_NAME, {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": Ref(test_configs),
        "buildPhases": [Ref(test_sources_phase), Ref(test_frameworks_phase), Ref(test_resources_phase)],
        "buildRules": [],
        "dependencies": [Ref(dependency)],
        "name": TEST_NAME,
        "productName": TEST_NAME,
        "productReference": Ref(test_product),
        "productType": "com.apple.product-type.bundle.unit-test",
    })
    project.add("project", "Project object", {
        "isa": "PBXProject",
        "attributes": {
            "BuildIndependentTargetsInParallel": "1",
            "LastSwiftUpdateCheck": "1500",
            "LastUpgradeCheck": "1500",
            "TargetAttributes": {
                app_target: {"CreatedOnToolsVersion": "15.0"},
                test_target: {"CreatedOnToolsVersion": "15.0", "TestTargetID": app_target},
            },
        },
        "buildConfigurationList": Ref(project_configs),
        "compatibilityVersion": "Xcode 14.0",
        "developmentRegion": "en",
        "hasScannedForEncodings": "0",
        "knownRegions": ["en", "Base"],
        "mainGroup": Ref(main_group),
        "productRefGroup": Ref(products_group),
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [Ref(app_target), Ref(test_target)],
    })

    project_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    (project_dir / "project.pbxproj").write_text(project.render(project_id))

    workspace = project_dir / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n'
    )

    schemes = project_dir / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    (schemes / f"{PROJECT_NAME}.xcscheme").write_text(scheme_xml(app_target, test_target))

    print(f"Wrote {project_dir.relative_to(ROOT)}: {len(app_sources)} sources, {len(app_resources)} resources, {len(test_sources)} tests")
    return 0


def scheme_xml(app_target: str, test_target: str) -> str:
    container = f"container:{PROJECT_NAME}.xcodeproj"
    app_ref = (
        f'BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" '
        f'BuildableName = "{PROJECT_NAME}.app" BlueprintName = "{PROJECT_NAME}" ReferencedContainer = "{container}"'
    )
    test_ref = (
        f'BuildableIdentifier = "primary" BlueprintIdentifier = "{test_target}" '
        f'BuildableName = "{TEST_NAME}.xctest" BlueprintName = "{TEST_NAME}" ReferencedContainer = "{container}"'
    )
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               {app_ref}>
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               {test_ref}>
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            {app_ref}>
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            {app_ref}>
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''


if __name__ == "__main__":
    sys.exit(main())
