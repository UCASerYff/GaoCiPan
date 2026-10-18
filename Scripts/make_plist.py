import json, pathlib, plistlib, sys
out, version, build = sys.argv[1:]
resources = pathlib.Path(out).parent/'Resources'
capabilities = json.loads((resources/'GaoCapabilities.json').read_text())
assert capabilities == {'schemaVersion':1,'bundleID':'com.gaoseries.GaoCiPan','appVersion':version,'actions':[]}
info = {
'CFBundleName':'搞磁盘', 'CFBundleDisplayName':'搞磁盘', 'CFBundleExecutable':'GaoCiPan',
'CFBundleIdentifier':'com.gaoseries.GaoCiPan', 'CFBundlePackageType':'APPL',
'CFBundleShortVersionString':version, 'CFBundleVersion':build, 'CFBundleIconFile':'AppIcon.icns',
'LSMinimumSystemVersion':'14.0', 'NSHighResolutionCapable':True, 'NSPrincipalClass':'NSApplication',
'LSApplicationCategoryType':'public.app-category.utilities',
'NSHumanReadableCopyright':'Copyright © 2026 UCASerYff. MIT License.',
'CFBundleDevelopmentRegion':'zh_CN', 'CFBundleLocalizations':['zh_CN'],
'CFBundleDocumentTypes':[{'CFBundleTypeName':'NTFS 原始镜像','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','CFBundleTypeExtensions':['ntfs','img','raw','dd'],'LSItemContentTypes':['public.disk-image']}]
}
with open(out,'wb') as file: plistlib.dump(info,file,sort_keys=True)
