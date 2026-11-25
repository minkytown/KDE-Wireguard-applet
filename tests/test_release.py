import json
from pathlib import Path
import runpy
import shutil
import struct
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch


ROOT = Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    def test_python_sources_compile(self):
        sources = [ROOT / "pia-vopono", ROOT / "pia_apps.py", ROOT / "guard/app-netns"]
        sources.extend((ROOT / "guard").glob("*.py"))
        for source in sources:
            with self.subTest(source=source.name):
                compile(source.read_text(), str(source), "exec")

    def test_fresh_profile_can_save_a_location_catalog(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, dbus=ModuleType("dbus")):
            client = runpy.run_path(str(ROOT / "pia-vopono"))
            cache = Path(directory) / "new-home/.local/share/pia-vopono/locations.json"
            locations = [{"id": "optimal", "name": "Optimal", "country": "Lowest latency"}]
            with patch.dict(client["refresh_locations"].__globals__, {
                "locations_cache": lambda: cache,
                "service_request": lambda action: {"locations": locations} if action == "locations" else {},
            }):
                self.assertFalse(cache.exists())
                self.assertEqual(client["refresh_locations"](), locations)
                self.assertEqual(client["locations_json"](), locations)

    def test_guard_location_discovery_releases_bootstrap_access(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, dbus=ModuleType("dbus")):
            stage = Path(directory)
            shutil.copy(ROOT / "pia-vopono", stage)
            shutil.copy(ROOT / "guard/guard.py", stage)
            guard = runpy.run_path(str(stage / "guard.py"))
            catalog = guard["catalog"]
            bootstrap = MagicMock()
            with patch.dict(catalog.__globals__, {
                "allow_bootstrap": bootstrap,
                "resolve_pia": lambda host: ["192.0.2.1"],
                "fetch_regions": MagicMock(side_effect=guard["ERROR"]("catalog unavailable")),
            }):
                with self.assertRaises(guard["ERROR"]):
                    catalog()
            bootstrap.assert_called_with([])

    def test_control_accepts_only_the_desktop_socket_owner(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(sys.modules, dbus=ModuleType("dbus")):
            stage = Path(directory)
            for source in (ROOT / "pia-vopono", ROOT / "guard/guard.py", ROOT / "guard/control.py"):
                shutil.copy(source, stage)
            control = runpy.run_path(str(stage / "control.py"))
            main = control["main"]
            for owner, uid, expected in ((2001, 2001, True), (2001, 2002, False), (0, 0, False)):
                with self.subTest(owner=owner, uid=uid):
                    connection = MagicMock()
                    connection.__enter__.return_value = connection
                    connection.getsockopt.return_value = struct.pack("3i", 42, uid, uid)
                    socket_file = MagicMock()
                    socket_file.stat.return_value = SimpleNamespace(st_uid=owner)
                    parsed = MagicMock(return_value={"action": "status"})
                    fake_socket = SimpleNamespace(socket=lambda **kw: connection, SOL_SOCKET=1, SO_PEERCRED=17)
                    with patch.dict(main.__globals__, {
                        "socket": fake_socket, "CONTROL_SOCKET": socket_file, "read_request": parsed,
                    }):
                        main()
                    self.assertEqual(json.loads(connection.sendall.call_args.args[0])["ok"], expected)
                    self.assertEqual(parsed.called, expected)
