#!/usr/bin/env python3
"""
生成 TeslaDash.xcodeproj/project.pbxproj（部署目标 iOS 15）。
用法: python3 gen_project.py
会在脚本同级目录 TeslaDash/ 下生成 .xcodeproj 工程。
"""
import os
import glob
import uuid

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(ROOT, "TeslaDash")          # 含 *.swift / Info.plist / Assets.xcassets
PROJ_NAME = "TeslaDash"
BUNDLE_ID = "com.example.tesladash"
DEPLOY = "15.0"

def uid():
    # Xcode 风格的 24 位大写十六进制 ID
    return uuid.uuid4().hex[:24].upper()

swift_files = sorted(glob.glob(os.path.join(SRC_DIR, "*.swift")))
swift_files = [os.path.basename(p) for p in swift_files]

# 组织对象 ID
proj_id        = uid()
target_id      = uid()
main_group     = uid()
src_group      = uid()
prod_ref       = uid()
sources_phase  = uid()
frameworks_ph  = uid()
resources_ph   = uid()
cfg_list_proj  = uid()
cfg_list_tgt   = uid()
cfg_p_debug    = uid()
cfg_p_release  = uid()
cfg_t_debug    = uid()
cfg_t_release  = uid()

# 为文件分配引用/构建文件 ID
file_refs = {f: uid() for f in swift_files}
build_files = {f: uid() for f in swift_files}
assets_ref = uid()
info_ref   = uid()

def pbx_objs():
    lines = []
    # PBXBuildFile
    lines.append("\t/* Begin PBXBuildFile section */")
    for f in swift_files:
        lines.append(f"\t\t{build_files[f]} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[f]} /* {f} */; }};")
    lines.append(f"\t\t{uid_res()} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};")
    lines.append("\t/* End PBXBuildFile section */")
    return "\n".join(lines)

def uid_res():
    # 资源构建文件 ID，单独固定
    return RES_BUILD

RES_BUILD = uid()

# PBXFileReference
def pbx_file_refs():
    lines = ["\t/* Begin PBXFileReference section */"]
    for f in swift_files:
        lines.append(f"\t\t{file_refs[f]} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = \"<group>\"; }};")
    lines.append(f"\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};")
    lines.append(f"\t\t{info_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
    lines.append(f"\t\t{prod_ref} /* {PROJ_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PROJ_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    lines.append("\t/* End PBXFileReference section */")
    return "\n".join(lines)

# PBXFrameworksBuildPhase (空，SwiftUI/CryptoKit 为系统框架，自动链接)
fw_ref = uid()
fw_build = uid()

def pbx_frameworks():
    return (
        "\t/* Begin PBXFrameworksBuildPhase section */\n"
        f"\t\t{frameworks_ph} /* Frameworks */ = {{\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "\t/* End PBXFrameworksBuildPhase section */"
    )

def pbx_groups():
    src_children = "\n".join(f"\t\t\t\t{file_refs[f]} /* {f} */," for f in swift_files)
    return (
        "\t/* Begin PBXGroup section */\n"
        f"\t\t{main_group} = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"\t\t\t\t{src_group} /* TeslaDash */,\n"
        f"\t\t\t\t{prod_ref} /* {PROJ_NAME}.app */,\n"
        "\t\t\t);\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
        f"\t\t{src_group} /* TeslaDash */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"{src_children}\n"
        f"\t\t\t\t{assets_ref} /* Assets.xcassets */,\n"
        f"\t\t\t\t{info_ref} /* Info.plist */,\n"
        "\t\t\t);\n"
        "\t\t\tpath = TeslaDash;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
        "\t/* End PBXGroup section */"
    )

def pbx_resources():
    return (
        "\t/* Begin PBXResourcesBuildPhase section */\n"
        f"\t\t{resources_ph} /* Resources */ = {{\n"
        "\t\t\tisa = PBXResourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t\t{RES_BUILD} /* Assets.xcassets in Resources */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "\t/* End PBXResourcesBuildPhase section */"
    )

def pbx_sources():
    items = "\n".join(f"\t\t\t\t{build_files[f]} /* {f} in Sources */," for f in swift_files)
    return (
        "\t/* Begin PBXSourcesBuildPhase section */\n"
        f"\t\t{sources_phase} /* Sources */ = {{\n"
        "\t\t\tisa = PBXSourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"{items}\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "\t/* End PBXSourcesBuildPhase section */"
    )

COMMON_BUILD = f"""\
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Manual;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = TeslaDash/Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = {DEPLOY};
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
"""

def pbx_configs():
    return (
        "\t/* Begin XCBuildConfiguration section */\n"
        # 工程 Debug
        f"\t\t{cfg_p_debug} /* Debug */ = {{\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n"
        "\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n"
        "\t\t\t\tCLANG_ANALYZER_NONNULL = YES;\n"
        "\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = " + DEPLOY + ";\n"
        "\t\t\t\tSDKROOT = iphoneos;\n"
        "\t\t\t\tSWIFT_VERSION = 5.0;\n"
        "\t\t\t};\n"
        "\t\t\tname = Debug;\n"
        "\t\t};\n"
        # 工程 Release
        f"\t\t{cfg_p_release} /* Release */ = {{\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n"
        "\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n"
        "\t\t\t\tCLANG_ANALYZER_NONNULL = YES;\n"
        "\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = " + DEPLOY + ";\n"
        "\t\t\t\tSDKROOT = iphoneos;\n"
        "\t\t\t\tSWIFT_VERSION = 5.0;\n"
        "\t\t\t\tVALIDATE_PRODUCT = YES;\n"
        "\t\t\t};\n"
        "\t\t\tname = Release;\n"
        "\t\t};\n"
        # 目标 Debug
        f"\t\t{cfg_t_debug} /* Debug */ = {{\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n"
        + COMMON_BUILD +
        "\t\t\t};\n"
        "\t\t\tname = Debug;\n"
        "\t\t};\n"
        # 目标 Release
        f"\t\t{cfg_t_release} /* Release */ = {{\n"
        "\t\t\tisa = XCBuildConfiguration;\n"
        "\t\t\tbuildSettings = {\n"
        + COMMON_BUILD +
        "\t\t\t};\n"
        "\t\t\tname = Release;\n"
        "\t\t};\n"
        "\t/* End XCBuildConfiguration section */"
    )

def pbx_config_lists():
    return (
        "\t/* Begin XCConfigurationList section */\n"
        f"\t\t{cfg_list_proj} /* Build configuration list for PBXProject */ = {{\n"
        "\t\t\tisa = XCConfigurationList;\n"
        "\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{cfg_p_debug} /* Debug */,\n"
        f"\t\t\t\t{cfg_p_release} /* Release */,\n"
        "\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n"
        "\t\t\tdefaultConfigurationName = Release;\n"
        "\t\t};\n"
        f"\t\t{cfg_list_tgt} /* Build configuration list for PBXNativeTarget */ = {{\n"
        "\t\t\tisa = XCConfigurationList;\n"
        "\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{cfg_t_debug} /* Debug */,\n"
        f"\t\t\t\t{cfg_t_release} /* Release */,\n"
        "\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n"
        "\t\t\tdefaultConfigurationName = Release;\n"
        "\t\t};\n"
        "\t/* End XCConfigurationList section */"
    )

pbx = f"""\
// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

{pbx_objs()}

{pbx_file_refs()}

{pbx_frameworks()}

{pbx_groups()}

{pbx_resources()}

{pbx_sources()}

{pbx_configs()}

{pbx_config_lists()}

\t/* Begin PBXNativeTarget section */
\t\t{target_id} /* {PROJ_NAME} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cfg_list_tgt} /* Build configuration list for PBXNativeTarget */;
\t\t\tbuildPhases = (
\t\t\t\t{sources_phase} /* Sources */,
\t\t\t\t{frameworks_ph} /* Frameworks */,
\t\t\t\t{resources_ph} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = {PROJ_NAME};
\t\t\tproductName = {PROJ_NAME};
\t\t\tproductReference = {prod_ref} /* {PROJ_NAME}.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
\t/* End PBXNativeTarget section */

\t/* Begin PBXProject section */
\t\t{proj_id} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target_id} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {cfg_list_proj} /* Build configuration list for PBXProject */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = zh-Hans;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\t"zh-Hans",
\t\t\t);
\t\t\tmainGroup = {main_group};
\t\t\tproductRefGroup = {src_group} /* TeslaDash */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target_id} /* {PROJ_NAME} */,
\t\t\t);
\t\t}};
\t/* End PBXProject section */
\t}};
\trootObject = {proj_id} /* Project object */;
}}
"""

proj_dir = os.path.join(ROOT, f"{PROJ_NAME}.xcodeproj")
os.makedirs(proj_dir, exist_ok=True)
out = os.path.join(proj_dir, "project.pbxproj")
with open(out, "w", encoding="utf-8") as f:
    f.write(pbx)
print(f"已生成: {out}")
print(f"源文件数: {len(swift_files)}")
