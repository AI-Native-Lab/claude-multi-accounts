"""End-to-end tests for the claude-multi-accounts command against a fake Claude data folder.

The command runs for real; only Claude itself is pretend (CMA_FAKE_APP, see FakeClaude.swift).
Build first, then run from the macos folder:

    swift build --product claude-multi-accounts
    /usr/bin/python3 -m unittest discover -s Tests/cli -v

CMA_ENGINE points the tests at another build of the command.
"""

import json
import os
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ENGINE = Path(os.environ.get("CMA_ENGINE") or
              Path(__file__).resolve().parents[2] / ".build" / "debug" / "claude-multi-accounts")
UUID_A = "aaaaaaaa-0000-4000-8000-000000000001"
UUID_B = "bbbbbbbb-0000-4000-8000-000000000002"
UUID_C = "cccccccc-0000-4000-8000-000000000003"
FUTURE = (int(time.time()) + 30 * 86400 + 11644473600) * 1_000_000  # Chrome time


def write_cookies(path: Path, marker: str, signed_in: bool = True) -> None:
    path.unlink(missing_ok=True)
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT,"
               " encrypted_value BLOB, expires_utc INTEGER, has_expires INTEGER)")
    db.execute("INSERT INTO cookies VALUES ('.claude.ai', 'marker', ?, x'', ?, 1)", (marker, FUTURE))
    if signed_in:
        db.execute("INSERT INTO cookies VALUES ('.claude.ai', 'sessionKey', '', ?, ?, 1)",
                   (b"v10" + marker.encode(), FUTURE))
    db.commit()
    db.close()


def cookie_marker(path: Path) -> str:
    db = sqlite3.connect(path)
    try:
        return db.execute("SELECT value FROM cookies WHERE name = 'marker'").fetchone()[0]
    finally:
        db.close()


class SwapTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(ENGINE.exists(), f"{ENGINE} is missing: run `swift build` first")
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.claude = root / "Claude"
        self.claude.mkdir()
        self.home = root / "swap-home"
        self.app = root / "app-running"
        self.windows = root / "app-running.windows"
        self.trash = root / "Trash"
        self.app.touch()
        clean = {k: v for k, v in os.environ.items() if k not in ("CMA_CLAUDE_DIR", "CMA_HOME", "CMA_TRASH")}
        self.env = {**clean, "CMA_CLAUDE_DIR": str(self.claude), "CMA_HOME": str(self.home),
                    "CMA_FAKE_APP": str(self.app), "CMA_TRASH": str(self.trash)}
        self.sign_in("A", UUID_A)
        self.write_config({**self.config(), "locale": "en-US", "windowState": {"w": 1}})

    def tearDown(self):
        self.tmp.cleanup()

    # -- helpers

    def run_cli(self, *args, ok=True, **env):
        r = subprocess.run([str(ENGINE), *args], capture_output=True,
                           text=True, env={**self.env, **env}, timeout=60)
        if ok:
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout)
        return r

    def config(self, folder=None):
        path = (folder or self.claude) / "config.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def write_config(self, data, folder=None):
        ((folder or self.claude) / "config.json").write_text(json.dumps(data, indent="\t"))

    def sign_in(self, letter, uuid, folder=None):
        """What Claude leaves on disk after signing in to an account."""
        folder = folder or self.claude
        write_cookies(folder / "Cookies", letter)
        self.write_config({**self.config(folder), "oauth:tokenCache": f"{letter}-legacy",
                           "oauth:tokenCacheV2": f"{letter}-tokens", "lastKnownAccountUuid": uuid}, folder)

    def state(self):
        return json.loads(self.run_cli("list", "--json").stdout)

    def account(self, name):
        return next(a for a in self.state()["accounts"] if a["name"] == name)

    def open_windows(self):
        """The data folders of the open side-by-side windows, symbolic links resolved."""
        return sorted(str(Path(p.read_text()).resolve()) for p in self.windows.iterdir()) if self.windows.exists() else []

    def assert_live(self, letter, uuid, tokens=None):
        self.assertEqual(cookie_marker(self.claude / "Cookies"), letter)
        self.assertEqual(self.config()["oauth:tokenCacheV2"], tokens or f"{letter}-tokens")
        self.assertEqual(self.config()["lastKnownAccountUuid"], uuid)
        self.assertTrue(self.app.exists(), "Claude was not reopened")

    def two_accounts(self):
        """Work (A) in the main Claude, Personal (B) saved."""
        self.run_cli("rename", "current", "Work")
        self.run_cli("add")
        self.sign_in("B", UUID_B)
        self.run_cli("switch", "Work", "--name-current", "Personal")

    # -- switching the main Claude

    def test_full_cycle(self):
        s = self.state()
        self.assertTrue(s["signedIn"])
        self.assertEqual(s["current"], {"uuid": UUID_A, "name": None})

        self.run_cli("rename", "current", "Work")
        self.assertEqual([a["name"] for a in self.state()["accounts"]], ["Work"])
        self.assertIn("No other saved account", self.run_cli("switch", ok=False).stderr)

        out = self.run_cli("add").stdout
        self.assertIn("“Work” is saved", out)
        config = self.config()
        for key in ("oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"):
            self.assertNotIn(key, config)
        self.assertEqual(config["windowState"], {"w": 1})
        self.assertFalse((self.claude / "Cookies").exists())
        self.assertTrue(self.app.exists())
        self.assertFalse(self.state()["signedIn"])

        # The user signs in to B in the reopened app, which also changes a setting.
        self.sign_in("B", UUID_B)
        self.write_config({**self.config(), "locale": "fr-FR"})
        (self.claude / "Cookies-journal").write_bytes(b"stale journal")

        out = self.run_cli("switch", "--name-current", "Personal").stdout
        self.assertIn("Switched Claude to “Work”", out)
        self.assert_live("A", UUID_A)
        self.assertEqual(self.config()["locale"], "fr-FR")
        self.assertFalse((self.claude / "Cookies-journal").exists())

        s = self.state()
        self.assertEqual([(a["name"], a["active"], a["saved"]) for a in s["accounts"]],
                         [("Work", True, True), ("Personal", False, True)])

        self.run_cli("switch", "Personal")
        self.assert_live("B", UUID_B)
        self.assertIn("Already signed in", self.run_cli("switch", "2").stdout)

        self.run_cli("switch")  # next wraps around to Work
        self.assert_live("A", UUID_A)
        self.assertGreaterEqual(len(list((self.home / "backups").iterdir())), 3)

        self.run_cli("remove", "Personal", "--yes")
        self.assertEqual([a["name"] for a in self.state()["accounts"]], ["Work"])
        self.assertFalse((self.home / "accounts" / UUID_B).exists())
        self.assertEqual(len(list(self.trash.iterdir())), 1, "the folder should be in the Trash")
        self.assertIn("is signed in to the main Claude", self.run_cli("remove", "Work", "--yes", ok=False).stderr)

    def test_signed_out_state_never_overwrites_a_saved_account(self):
        self.two_accounts()
        self.run_cli("switch", "Personal")

        # Signed out of B inside the app: the cookie is gone but the uuid stays.
        write_cookies(self.claude / "Cookies", "B-dead", signed_in=False)
        self.run_cli("switch", "Work")
        self.assert_live("A", UUID_A)
        self.assertEqual(cookie_marker(self.home / "accounts" / UUID_B / "Cookies"), "B")

    def test_app_that_will_not_quit_is_left_alone(self):
        self.two_accounts()
        r = self.run_cli("switch", "Personal", ok=False, CMA_FAKE_APP_STUCK="1", CMA_QUIT_TIMEOUT="1")
        self.assertIn("didn't quit", r.stderr)
        self.assert_live("A", UUID_A)

    def test_switch_survives_its_caller_being_killed(self):
        # Quitting Claude kills a terminal running inside its Code tab.
        self.two_accounts()
        caller = subprocess.Popen(
            [str(ENGINE), "switch", "Personal"],
            env={**self.env, "CMA_FAKE_QUIT_DELAY": "1.5"}, start_new_session=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.7)
        os.killpg(caller.pid, signal.SIGKILL)
        caller.wait()
        deadline = time.time() + 15
        while time.time() < deadline:
            if self.app.exists() and self.config().get("lastKnownAccountUuid") == UUID_B:
                break
            time.sleep(0.2)
        self.assert_live("B", UUID_B)

    # -- side by side

    def test_side_by_side_window_keeps_the_only_copy_of_its_sign_in(self):
        self.two_accounts()
        folder_b = self.home / "accounts" / UUID_B
        self.assertTrue((folder_b / "auth.json").exists())

        sessions = self.claude / "claude-code-sessions" / UUID_B / "org"
        sessions.mkdir(parents=True)
        (sessions / "local_1.json").write_text("{}")

        self.assertIn("own Claude window", self.run_cli("open", "Personal").stdout)
        self.assertEqual(self.open_windows(), [str(folder_b.resolve())])
        # Its Code session list moved into the window's folder.
        self.assertFalse(sessions.exists())
        self.assertTrue((folder_b / "claude-code-sessions" / UUID_B / "org" / "local_1.json").exists())
        self.assertTrue(self.app.exists(), "the main Claude keeps running")
        self.assertEqual(self.account("Personal")["place"], "window")
        # The folder is now a data folder Claude can open: its keys moved into config.json.
        self.assertFalse((folder_b / "auth.json").exists())
        self.assertEqual(self.config(folder_b)["oauth:tokenCacheV2"], "B-tokens")
        self.assertEqual(self.config(folder_b)["locale"], "en-US")
        self.assertIn("front", self.run_cli("open", "2").stdout)
        self.assertEqual(len(self.open_windows()), 1)

        # While the window runs, its sign-in can't be copied anywhere.
        self.assertIn("own Claude window", self.run_cli("switch", "Personal", ok=False).stderr)
        self.assertIn("own Claude window", self.run_cli("remove", "Personal", "--yes", ok=False).stderr)
        self.assertIn("main Claude", self.run_cli("open", "Work").stdout)

        # The window refreshes its tokens; switching takes the newest ones.
        self.write_config({**self.config(folder_b), "oauth:tokenCacheV2": "B-rotated", "theme": "dark"}, folder_b)
        out = self.run_cli("switch", "Personal", "--close-window").stdout
        self.assertIn("Switched Claude to “Personal”", out)
        self.assertEqual(self.open_windows(), [])
        self.assert_live("B", UUID_B, tokens="B-rotated")
        self.assertTrue((sessions / "local_1.json").exists(), "the session list came back")
        self.assertNotIn("theme", self.config(), "only the sign-in moves")

        # And back: Work's sign-in goes to its folder, Personal's to its window folder.
        self.run_cli("switch", "Work")
        self.assert_live("A", UUID_A)
        self.assertEqual(self.config(folder_b)["oauth:tokenCacheV2"], "B-rotated")
        self.assertEqual(self.config(folder_b)["theme"], "dark", "the window's own settings stay")

        self.run_cli("open", "Personal")
        self.assertIn("Closed", self.run_cli("close", "Personal").stdout)
        self.assertEqual(self.open_windows(), [])

    def test_add_in_a_new_window(self):
        self.run_cli("rename", "current", "Work")
        out = self.run_cli("add", "--window", "--name", "Client").stdout
        self.assertIn("new Claude window", out)
        self.assertTrue(self.app.exists(), "the main Claude keeps running")
        [folder] = [Path(p) for p in self.open_windows()]
        self.assertTrue(folder.name.startswith("new-"))
        s = self.state()
        self.assertEqual([a["name"] for a in s["accounts"]], ["Work"])
        self.assertEqual([(w["name"], w["open"]) for w in s["newWindows"]], [("Client", True)])

        # The person signs in there; the account joins the list, open in its window.
        self.sign_in("C", UUID_C, folder)
        client = self.account("Client")
        self.assertEqual((client["uuid"], client["place"], str(Path(client["folder"]).resolve())),
                         (UUID_C, "window", str(folder)))
        self.assertEqual(self.state()["newWindows"], [])

        self.run_cli("close", "Client")
        self.assertEqual(self.account("Client")["place"], "saved")
        self.run_cli("switch", "Client")
        self.assert_live("C", UUID_C)
        self.assertEqual(self.account("Work")["place"], "saved")

    def test_an_account_signed_in_twice_blocks_switching(self):
        self.two_accounts()
        # Work is in the main Claude; someone also signs in to Work in a new window.
        self.run_cli("add", "--window")
        [folder] = [Path(p) for p in self.open_windows()]
        self.sign_in("A2", UUID_A, folder)
        work = self.account("Work")
        self.assertEqual((work["place"], work["window"], str(Path(work["folder"]).resolve())), ("main", True, str(folder)))
        self.assertEqual(len(list(self.trash.iterdir())), 1, "Work's earlier folder went to the Trash")

        r = self.run_cli("switch", "Personal", ok=False)
        self.assertIn("signed in both", r.stderr)
        self.assert_live("A", UUID_A)
        self.assertEqual(cookie_marker(folder / "Cookies"), "A2", "the window's sign-in is untouched")

        self.run_cli("close", "Work")
        self.run_cli("switch", "Personal")
        self.assert_live("B", UUID_B)
        self.assertEqual(cookie_marker(folder / "Cookies"), "A", "Work's main sign-in was saved to its folder")


if __name__ == "__main__":
    unittest.main()
