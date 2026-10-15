"""
Builds what a host installs:

    dist/BeamJoyLive.zip      -> Resources/Client/BeamJoyLive.zip (next to BeamJoy's own zip)
    dist/Server/BeamJoyLive/  -> Resources/Server/BeamJoyLive/

    python3 tools/build.py
"""
import os
import shutil
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
CLIENT = os.path.join(ROOT, "Client")

shutil.rmtree(DIST, ignore_errors=True)
os.makedirs(DIST)
with zipfile.ZipFile(os.path.join(DIST, "BeamJoyLive.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    for base, _, files in os.walk(CLIENT):
        for f in sorted(files):
            path = os.path.join(base, f)
            z.write(path, os.path.relpath(path, CLIENT).replace(os.sep, "/"))
shutil.copytree(os.path.join(ROOT, "Server"), os.path.join(DIST, "Server"))
with zipfile.ZipFile(os.path.join(DIST, "BeamJoyLive-server.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    for base, _, files in os.walk(os.path.join(ROOT, "Server")):
        for f in sorted(files):
            path = os.path.join(base, f)
            z.write(path, os.path.relpath(path, os.path.join(ROOT, "Server")).replace(os.sep, "/"))
print("Built dist/BeamJoyLive.zip, dist/BeamJoyLive-server.zip and dist/Server/BeamJoyLive/")
