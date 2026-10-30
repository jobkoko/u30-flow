"""Build locally; installation is opt-in and never bundles pairing credentials."""
import argparse
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--install', action='store_true', help='Also copy to ~/Applications')
    parser.add_argument('--output', type=Path, default=ROOT / 'build')
    args = parser.parse_args()
    arch = platform.machine()
    if arch not in ('arm64', 'x86_64'):
        raise SystemExit('Build on an Apple Silicon or Intel Mac with Xcode Command Line Tools.')
    with tempfile.TemporaryDirectory(prefix='u30-flow-build-') as folder:
        app = Path(folder) / 'U30 Flow.app'
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        subprocess.run(['swiftc', '-swift-version', '5', '-O', '-target', f'{arch}-apple-macos13.0', '-framework', 'AppKit', '-framework', 'ServiceManagement', str(ROOT / 'mac/main.swift'), '-o', str(contents / 'MacOS/U30Flow')], check=True)
        info = {'CFBundleIdentifier': 'local.u30flow.menubar', 'CFBundleName': 'U30 Flow', 'CFBundleDisplayName': 'U30 Flow', 'CFBundleExecutable': 'U30Flow', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.1.0', 'CFBundleVersion': '1', 'LSUIElement': True, 'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True, 'NSLocalNetworkUsageDescription': '只读显示已配置路由器的订阅流量和网络状态。'}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', info['CFBundleIdentifier'], str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
        args.output.mkdir(parents=True, exist_ok=True)
        destinations = [args.output / app.name]
        if args.install:
            destinations.append(Path.home() / 'Applications' / app.name)
        for target in destinations:
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                old = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
                if old.get('CFBundleIdentifier') != info['CFBundleIdentifier']:
                    raise SystemExit('Refusing to overwrite another application.')
                shutil.rmtree(target)
            shutil.copytree(app, target)
            subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)
            print(target)


if __name__ == '__main__':
    main()
