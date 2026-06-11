"""Select GalacticOdyssey.saver as the screensaver for ALL displays/spaces.

macOS 14+ stores the screensaver choice in the wallpaper store; legacy .saver
bundles must use the com.apple.NeptuneOneExtension provider. System Settings
occasionally rewrites entries with a provider that can't host legacy savers,
so build.sh re-runs this after every install. Follow with:
    killall WallpaperAgent
"""
import plistlib, datetime, os, urllib.parse

HOME = os.path.expanduser("~")
INDEX = os.path.join(HOME, "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
SAVER_URL = "file://" + urllib.parse.quote(
    os.path.join(HOME, "Library/Screen Savers/GalacticOdyssey.saver"))

config = plistlib.dumps({"module": {"relative": SAVER_URL}}, fmt=plistlib.FMT_BINARY)
choice = {
    "Configuration": config,
    "Files": [],
    "Provider": "com.apple.NeptuneOneExtension",
}
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)

with open(INDEX, "rb") as f:
    root = plistlib.load(f)

count = 0
def patch(node):
    global count
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "Idle" and isinstance(v, dict) and "Content" in v:
                v["Content"]["Choices"] = [dict(choice)]
                v["Content"]["Shuffle"] = "$null"
                v["LastSet"] = now
                count += 1
            else:
                patch(v)
    elif isinstance(node, list):
        for item in node:
            patch(item)

patch(root)
with open(INDEX, "wb") as f:
    plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)
print(f"patched {count} Idle sections")
