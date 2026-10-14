#!/usr/bin/env python3
# Aplica a assinatura fixa (suporte.jks) no build de release, Groovy ou Kotlin DSL.
import os, sys

p = "android/app/build.gradle" if os.path.exists("android/app/build.gradle") else "android/app/build.gradle.kts"
s = open(p).read()

if p.endswith(".kts"):
    blk = (
        '    signingConfigs {\n'
        '        create("release") {\n'
        '            storeFile = file("suporte.jks")\n'
        '            storePassword = "suporte123"\n'
        '            keyAlias = "suporte"\n'
        '            keyPassword = "suporte123"\n'
        '        }\n'
        '    }\n'
    )
    if "signingConfigs {" not in s:
        s = s.replace("    buildTypes {", blk + "    buildTypes {", 1)
    s = s.replace('signingConfig = signingConfigs.getByName("debug")',
                  'signingConfig = signingConfigs.getByName("release")')
    ok = 'getByName("release")' in s
else:
    blk = (
        '    signingConfigs {\n'
        '        release {\n'
        '            storeFile file("suporte.jks")\n'
        '            storePassword "suporte123"\n'
        '            keyAlias "suporte"\n'
        '            keyPassword "suporte123"\n'
        '        }\n'
        '    }\n'
    )
    if "signingConfigs {" not in s:
        s = s.replace("    buildTypes {", blk + "    buildTypes {", 1)
    s = s.replace("signingConfig signingConfigs.debug",
                  "signingConfig signingConfigs.release")
    s = s.replace("signingConfig = signingConfigs.debug",
                  "signingConfig = signingConfigs.release")
    ok = ("signingConfig signingConfigs.release" in s or
          "signingConfig = signingConfigs.release" in s)

open(p, "w").write(s)
if not ok:
    print("ERRO: assinatura de release nao aplicada em " + p)
    sys.exit(1)
print("Assinatura fixa aplicada em " + p)
