#!/usr/bin/env python3
"""Genera FPMStudioLive.xcodeproj (nessuno strumento esterno richiesto).
Uso: python3 tools/gen_xcodeproj.py   (dalla cartella del repository)
"""
import hashlib, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = "FPMStudioLive"
NAME = "FPMStudioLive"
BUNDLE_ID = "it.fpm.studiolive"
DEPLOY = "12.0"

def uid(*parts):
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:24].upper()

files = []  # (relative path inside SRC, kind)
for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, SRC)):
    dirnames[:] = sorted(d for d in dirnames if not d.endswith(".xcassets"))
    rel_dir = os.path.relpath(dirpath, os.path.join(ROOT, SRC))
    entries = sorted(filenames)
    if os.path.basename(dirpath) == "Resources":
        entries += ["Assets.xcassets"]
    for f in sorted(set(entries)):
        rel = os.path.normpath(os.path.join(rel_dir, f))
        if f.endswith(".swift"):
            files.append((rel, "swift"))
        elif f == "Assets.xcassets":
            files.append((rel, "assets"))
        elif f.endswith(".js"):
            files.append((rel, "js"))
        elif f == "Info.plist":
            files.append((rel, "plist"))
        elif f.endswith(".entitlements"):
            files.append((rel, "entitlements"))

ftype = {"swift": "sourcecode.swift", "assets": "folder.assetcatalog", "js": "sourcecode.javascript",
         "plist": "text.plist.xml", "entitlements": "text.plist.entitlements"}

# Gruppi
groups = {}  # path -> list of children ids
def group_id(path):
    return uid("group", path)
for rel, _ in files:
    parts = rel.split(os.sep)
    for i in range(len(parts)):
        parent = os.sep.join(parts[:i])
        child = os.sep.join(parts[:i + 1])
        groups.setdefault(parent, [])
        cid = uid("file", child) if i == len(parts) - 1 else group_id(child)
        if cid not in groups[parent]:
            groups[parent].append(cid)

main_group = uid("maingroup")
products_group = uid("products")
app_ref = uid("product", NAME)
target = uid("target", NAME)
project = uid("project", NAME)
src_phase, res_phase, fw_phase = uid("sources"), uid("resources"), uid("frameworks")
proj_cfgs = (uid("projcfg", "Debug"), uid("projcfg", "Release"))
tgt_cfgs = (uid("tgtcfg", "Debug"), uid("tgtcfg", "Release"))
proj_list, tgt_list = uid("projlist"), uid("tgtlist")

out = []
w = out.append
w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 54;\n\tobjects = {\n")

w("\n/* Begin PBXBuildFile section */\n")
for rel, kind in files:
    if kind in ("swift", "assets", "js"):
        w(f"\t\t{uid('build', rel)} /* {os.path.basename(rel)} */ = {{isa = PBXBuildFile; fileRef = {uid('file', rel)}; }};\n")
w("/* End PBXBuildFile section */\n")

w("\n/* Begin PBXFileReference section */\n")
w(f"\t\t{app_ref} /* FPM Studio Live.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \"FPM Studio Live.app\"; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
for rel, kind in files:
    name = os.path.basename(rel)
    w(f"\t\t{uid('file', rel)} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype[kind]}; path = \"{name}\"; sourceTree = \"<group>\"; }};\n")
w("/* End PBXFileReference section */\n")

w("\n/* Begin PBXFrameworksBuildPhase section */\n")
w(f"\t\t{fw_phase} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (\n\t\t\t); runOnlyForDeploymentPostprocessing = 0; }};\n")
w("/* End PBXFrameworksBuildPhase section */\n")

w("\n/* Begin PBXGroup section */\n")
w(f"\t\t{main_group} = {{isa = PBXGroup; children = (\n\t\t\t\t{group_id(SRC)},\n\t\t\t\t{products_group},\n\t\t\t); sourceTree = \"<group>\"; }};\n")
w(f"\t\t{products_group} /* Products */ = {{isa = PBXGroup; children = (\n\t\t\t\t{app_ref},\n\t\t\t); name = Products; sourceTree = \"<group>\"; }};\n")
for path, children in sorted(groups.items()):
    gid = group_id(SRC) if path == "" else group_id(path)
    name = SRC if path == "" else os.path.basename(path)
    kids = "".join(f"\t\t\t\t{c},\n" for c in children)
    w(f"\t\t{gid} /* {name} */ = {{isa = PBXGroup; children = (\n{kids}\t\t\t); path = \"{name}\"; sourceTree = \"<group>\"; }};\n")
w("/* End PBXGroup section */\n")

w("\n/* Begin PBXNativeTarget section */\n")
w(f"\t\t{target} /* {NAME} */ = {{isa = PBXNativeTarget; buildConfigurationList = {tgt_list}; buildPhases = (\n"
  f"\t\t\t\t{src_phase},\n\t\t\t\t{fw_phase},\n\t\t\t\t{res_phase},\n\t\t\t); buildRules = (\n\t\t\t); dependencies = (\n\t\t\t); "
  f"name = {NAME}; productName = {NAME}; productReference = {app_ref}; productType = \"com.apple.product-type.application\"; }};\n")
w("/* End PBXNativeTarget section */\n")

w("\n/* Begin PBXProject section */\n")
w(f"\t\t{project} /* Project object */ = {{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1420; LastUpgradeCheck = 1420; "
  f"TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 14.2; }}; }}; }}; buildConfigurationList = {proj_list}; compatibilityVersion = \"Xcode 12.0\"; "
  f"developmentRegion = it; hasScannedForEncodings = 0; knownRegions = (\n\t\t\t\tit,\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t); mainGroup = {main_group}; "
  f"productRefGroup = {products_group}; projectDirPath = \"\"; projectRoot = \"\"; targets = (\n\t\t\t\t{target},\n\t\t\t); }};\n")
w("/* End PBXProject section */\n")

w("\n/* Begin PBXResourcesBuildPhase section */\n")
res = "".join(f"\t\t\t\t{uid('build', rel)},\n" for rel, k in files if k in ("assets", "js"))
w(f"\t\t{res_phase} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (\n{res}\t\t\t); runOnlyForDeploymentPostprocessing = 0; }};\n")
w("/* End PBXResourcesBuildPhase section */\n")

w("\n/* Begin PBXSourcesBuildPhase section */\n")
srcs = "".join(f"\t\t\t\t{uid('build', rel)},\n" for rel, k in files if k == "swift")
w(f"\t\t{src_phase} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\n{srcs}\t\t\t); runOnlyForDeploymentPostprocessing = 0; }};\n")
w("/* End PBXSourcesBuildPhase section */\n")

def settings(d):
    return "".join(f"\t\t\t\t{k} = {v};\n" for k, v in d.items())

common_proj = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO", "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu11",
    "MACOSX_DEPLOYMENT_TARGET": DEPLOY, "SDKROOT": "macosx", "SWIFT_VERSION": "5.0", "MTL_FAST_MATH": "YES",
}
dbg_proj = dict(common_proj, **{"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0",
                                "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "SWIFT_OPTIMIZATION_LEVEL": "\"-Onone\""})
rel_proj = dict(common_proj, **{"DEBUG_INFORMATION_FORMAT": "\"dwarf-with-dsym\"", "ENABLE_NS_ASSERTIONS": "NO",
                                "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "\"-O\"", "ONLY_ACTIVE_ARCH": "NO"})
tgt = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "CODE_SIGN_ENTITLEMENTS": f"{SRC}/Resources/FPMStudioLive.entitlements",
    "CODE_SIGN_IDENTITY": "\"-\"", "CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": "\"\"", "COMBINE_HIDPI_IMAGES": "YES",
    "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "1.0", "ENABLE_HARDENED_RUNTIME": "NO", "ENABLE_APP_SANDBOX": "NO",
    "INFOPLIST_FILE": f"{SRC}/Resources/Info.plist", "LD_RUNPATH_SEARCH_PATHS": "\"$(inherited) @executable_path/../Frameworks\"",
    "MACOSX_DEPLOYMENT_TARGET": DEPLOY, "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID, "PRODUCT_NAME": "\"FPM Studio Live\"",
    "SWIFT_VERSION": "5.0", "ARCHS": "\"$(ARCHS_STANDARD)\"",
}

w("\n/* Begin XCBuildConfiguration section */\n")
for cid, name, d in [(proj_cfgs[0], "Debug", dbg_proj), (proj_cfgs[1], "Release", rel_proj),
                     (tgt_cfgs[0], "Debug", tgt), (tgt_cfgs[1], "Release", tgt)]:
    w(f"\t\t{cid} /* {name} */ = {{isa = XCBuildConfiguration; buildSettings = {{\n{settings(d)}\t\t\t}}; name = {name}; }};\n")
w("/* End XCBuildConfiguration section */\n")

w("\n/* Begin XCConfigurationList section */\n")
for lid, (a, b) in [(proj_list, proj_cfgs), (tgt_list, tgt_cfgs)]:
    w(f"\t\t{lid} = {{isa = XCConfigurationList; buildConfigurations = (\n\t\t\t\t{a},\n\t\t\t\t{b},\n\t\t\t); "
      f"defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};\n")
w("/* End XCConfigurationList section */\n")

w(f"\t}};\n\trootObject = {project} /* Project object */;\n}}\n")

proj_dir = os.path.join(ROOT, NAME + ".xcodeproj")
os.makedirs(proj_dir, exist_ok=True)
with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
    f.write("".join(out))

# Schema condiviso: Product > Archive/Run usano Release universale (Intel + Apple Silicon).
scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
ref = f'''<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target}" BuildableName = "FPM Studio Live.app" BlueprintName = "{NAME}" ReferencedContainer = "container:{NAME}.xcodeproj"></BuildableReference>'''
with open(os.path.join(scheme_dir, NAME + ".xcscheme"), "w") as f:
    f.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1420" version = "1.3">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Release" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
''')
print(f"Creato {proj_dir} con {sum(1 for _, k in files if k == 'swift')} file Swift")
