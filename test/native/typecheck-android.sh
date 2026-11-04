#!/usr/bin/env bash
# Standalone Kotlin/Compose compilation. Does not build an APK, run Gradle,
# launch an emulator, fetch dependencies, or validate Mob's native registration.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: bash test/native/typecheck-android.sh

Prerequisites: Python 3, JDK 17+, an installed Android SDK platform (default 35),
Kotlin compiler + Compose compiler plugin (both default 2.4.21), and the AndroidX
Compose/activity/lifecycle/WebKit libraries already downloaded for a Mob build.
Uses cached dependencies only. It never downloads missing artifacts.

Environment overrides:
  MOB_WEBVIEW_GRADLE_CACHE          Gradle user home; defaults to GRADLE_USER_HOME
                                   or the sibling .cache/mobile-gradle directory.
  MOB_WEBVIEW_ANDROID_SDK           SDK root; defaults to ANDROID_SDK_ROOT,
                                   ANDROID_HOME, or ~/Library/Android/sdk.
  MOB_WEBVIEW_ANDROID_API           SDK platform number; default 35.
  MOB_WEBVIEW_JAVA                  Java executable; defaults to JAVA_HOME/bin/java,
                                   Android Studio's bundled JDK, then PATH java.
  MOB_WEBVIEW_KOTLIN_VERSION        Compiler/plugin version; default 2.4.21.
  MOB_WEBVIEW_KOTLIN_COMPILER_JAR   Explicit Kotlin compiler JAR.
  MOB_WEBVIEW_COMPOSE_COMPILER_JAR  Explicit matching Compose compiler plugin JAR.
  MOB_WEBVIEW_KOTLIN_CLASSPATH      Full colon-separated compiler runtime classpath;
                                   overrides inferred compiler support libraries.
  MOB_WEBVIEW_ANDROID_CLASSPATH     Full colon-separated dependency classpath;
                                   overrides cached AndroidX JAR/AAR discovery.
                                   The SDK android.jar is appended automatically.
  MOB_WEBVIEW_WEBKIT_AAR            Optional downloaded webkit-1.12.1.aar when it
                                   is absent from the Gradle cache. No download
                                   is performed. Ignored with explicit Android CP.

Example when the WebKit AAR is held separately:
  MOB_WEBVIEW_WEBKIT_AAR=/path/to/webkit-1.12.1.aar bash test/native/typecheck-android.sh

Generated classes and extracted AAR libraries use a temporary directory that is
removed after the check. Compiler diagnostics identify actual source errors.
HELP
  exit 0
fi
if [[ $# -ne 0 ]]; then echo 'Use --help for usage.' >&2; exit 2; fi
python3 - <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile


def fail(message):
    raise SystemExit('Android typecheck prerequisites: ' + message)


def env_paths(name):
    return [Path(part).expanduser() for part in os.environ.get(name, '').split(os.pathsep) if part]


def require_file(path, label):
    if not path.is_file():
        fail(f'{label} not found: {path}. See --help for overrides.')
    return path


project = Path.cwd()
gradle = Path(os.environ.get('MOB_WEBVIEW_GRADLE_CACHE') or os.environ.get('GRADLE_USER_HOME') or project.parent / '.cache/mobile-gradle').expanduser()
modules = gradle if gradle.name == 'files-2.1' else gradle / 'caches/modules-2/files-2.1'
jars = sorted(modules.rglob('*.jar')) if modules.is_dir() else []
version = os.environ.get('MOB_WEBVIEW_KOTLIN_VERSION', '2.4.21')


def artifact(override, filename):
    if os.environ.get(override):
        return require_file(Path(os.environ[override]).expanduser(), override)
    result = next((path for path in jars if path.name == filename), None)
    if result is None:
        fail(f'{filename} is absent from {modules}; set {override} or use an existing complete Gradle cache.')
    return result


compiler = artifact('MOB_WEBVIEW_KOTLIN_COMPILER_JAR', f'kotlin-compiler-embeddable-{version}.jar')
plugin = artifact('MOB_WEBVIEW_COMPOSE_COMPILER_JAR', f'kotlin-compose-compiler-plugin-embeddable-{version}.jar')
java = os.environ.get('MOB_WEBVIEW_JAVA')
if not java:
    candidates = [Path(os.environ.get('JAVA_HOME', '/nonexistent')) / 'bin/java', Path('/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java')]
    java = next((str(path) for path in candidates if path.is_file()), None) or shutil.which('java')
if not java:
    fail('JDK not found; set MOB_WEBVIEW_JAVA or JAVA_HOME.')
sdk = Path(os.environ.get('MOB_WEBVIEW_ANDROID_SDK') or os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or Path.home() / 'Library/Android/sdk').expanduser()
android_jar = require_file(sdk / 'platforms' / ('android-' + os.environ.get('MOB_WEBVIEW_ANDROID_API', '35')) / 'android.jar', 'Android SDK platform')
runtime = env_paths('MOB_WEBVIEW_KOTLIN_CLASSPATH')
if not runtime:
    support = ['kotlin-stdlib-', 'kotlin-reflect-', 'kotlin-script-runtime-', 'kotlin-daemon-embeddable', 'trove4j', 'kotlinx-coroutines-core-jvm', 'annotations-']
    runtime = [compiler] + [path for path in jars if any(name in path.name for name in support)]
for path in runtime:
    require_file(path, 'Compiler runtime JAR')

with tempfile.TemporaryDirectory(prefix='mob-webview-kotlin-') as directory:
    work = Path(directory)
    dependencies = env_paths('MOB_WEBVIEW_ANDROID_CLASSPATH')
    if not dependencies:
        dependencies = list(jars)
        aars = sorted(modules.rglob('*.aar')) if modules.is_dir() else []
        if os.environ.get('MOB_WEBVIEW_WEBKIT_AAR'):
            aars.append(require_file(Path(os.environ['MOB_WEBVIEW_WEBKIT_AAR']).expanduser(), 'WebKit AAR'))
        has_webkit = False
        for number, aar in enumerate(aars):
            with zipfile.ZipFile(aar) as archive:
                if 'classes.jar' not in archive.namelist():
                    continue
                output = work / f'{number}-{aar.stem}.jar'
                output.write_bytes(archive.read('classes.jar'))
                dependencies.append(output)
                with zipfile.ZipFile(output) as classes:
                    has_webkit |= 'androidx/webkit/WebViewCompat.class' in classes.namelist()
        if not has_webkit:
            fail('AndroidX WebKit is absent from cached AARs; set MOB_WEBVIEW_WEBKIT_AAR to an existing webkit-1.12.1.aar or provide MOB_WEBVIEW_ANDROID_CLASSPATH.')
    for path in dependencies:
        if not path.exists():
            fail(f'Android dependency classpath entry does not exist: {path}')
    command = [str(java), '-Xmx768m', '-cp', os.pathsep.join(map(str, runtime)), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
               '-no-stdlib', '-no-reflect', '-classpath', os.pathsep.join(map(str, dependencies + [android_jar])),
               '-Xplugin=' + str(plugin), '-jvm-target', '17', '-d', str(work / 'classes'),
               str(project / 'priv/native/android/WebView.kt')]
    print(f'Typechecking Android WebView with Kotlin/Compose {version}, SDK {android_jar.parent.name}.', flush=True)
    result = subprocess.run(command)
    if result.returncode:
        sys.exit(result.returncode)
    print('Android WebView Kotlin/Compose compile check passed (no APK build or device run).')
PY
