"""Exercise setup with isolated app data and network/runtime fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PLUGIN = Path(__file__).resolve().parents[1]
SHELL = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
MOCK_RUNTIME = r"""
. '__RUNTIME__'
function New-TestRuntime([string]$path, [string]$version) {
    return @{ executable = $path; version = $version; ready = $true; can_merge = $true }
}
function Test-Dogy([string]$candidate) {
    if ($candidate -eq $env:DOGY_TEST_OLD -and $env:DOGY_TEST_OLD_VERSION) {
        return New-TestRuntime $candidate $env:DOGY_TEST_OLD_VERSION
    }
    return $null
}
function Find-DogyRuntime($previous) {
    if ($env:DOGY_TEST_OLD_VERSION) { return Test-Dogy $env:DOGY_TEST_OLD }
    return $null
}
function Update-DogyRuntime($current) {
    [IO.File]::AppendAllText($env:DOGY_TEST_CALLS, 'update' + [Environment]::NewLine)
    if ($env:DOGY_TEST_OFFLINE -eq '1') { throw 'Offline fixture' }
    if ($current -and [version]$current.version -ge [version]$env:DOGY_TEST_RELEASE) {
        return $current
    }
    [IO.File]::WriteAllText($env:DOGY_TEST_NEW, 'verified fixture')
    return New-TestRuntime $env:DOGY_TEST_NEW $env:DOGY_TEST_RELEASE
}
"""


def run_case(base, name, old="1.0.2", release="1.1.1", offline=False,
             explicit=False, force=False, expected=None, updates=0):
    root = base / name
    fixture = root / "plugin"
    shutil.copytree(PLUGIN, fixture)
    scripts = fixture / "scripts"
    source = str(PLUGIN / "scripts/runtime.ps1").replace("'", "''")
    (scripts / "runtime.ps1").write_text(
        MOCK_RUNTIME.replace("__RUNTIME__", source), encoding="utf-8-sig")
    previous = root / "old.exe"
    previous.write_bytes(b"unchanged previous program")
    calls = root / "calls.txt"
    environment = dict(os.environ, LOCALAPPDATA=str(root / "appdata"),
                       USERPROFILE=str(root / "profile"), DOGY_TEST_OLD=str(previous),
                       DOGY_TEST_NEW=str(root / "new.exe"), DOGY_TEST_CALLS=str(calls),
                       DOGY_TEST_OLD_VERSION=old, DOGY_TEST_RELEASE=release,
                       DOGY_TEST_OFFLINE="1" if offline else "0")
    command = [str(SHELL), "-NoProfile", "-ExecutionPolicy", "Bypass",
               "-File", str(scripts / "setup.ps1")]
    if explicit:
        command.extend(["-ExePath", str(previous)])
    if force:
        command.append("-ForceDownload")
    result = subprocess.run(command, env=environment, capture_output=True,
                            text=True, encoding="utf-8", errors="replace", timeout=45)
    config = root / "appdata/MediaDownloader/Agent/runtime.json"
    assert previous.read_bytes() == b"unchanged previous program", name
    assert (len(calls.read_text().splitlines()) if calls.exists() else 0) == updates, name
    if expected is None:
        assert result.returncode != 0 and not config.exists(), (name, result.stdout, result.stderr)
    else:
        assert result.returncode == 0, (name, result.stdout, result.stderr)
        report = json.loads(result.stdout)
        record = json.loads(config.read_text(encoding="utf-8"))
        available = tuple(map(int, expected.split("."))) >= (1, 1, 0)
        assert report["ok"] and report["version"] == expected, (name, report)
        assert report["video_memory_available"] == available, (name, report)
        assert report["dense_frames_available"] == (tuple(map(int, expected.split("."))) >= (1, 1, 1)), (name, report)
        assert report["required_version"] == "1.1.1", (name, report)
        assert record["version"] == expected and record["plugin_version"] == "1.1.1", name
        if not available:
            assert "requires DOGY 1.1.0" in report["warning"] and result.stderr, name
        if offline:
            assert "update failed" in report["warning"], (name, report)
        if explicit or (offline and old):
            assert Path(record["executable"]) == previous, (name, record)
        for filename in ("bridge.cs", "mcp.ps1", "runtime.ps1", "refresh.ps1",
                         "release-source.json"):
            assert (config.parent / filename).is_file(), (name, filename)
    print(f"{name}: PASS")


def main():
    with tempfile.TemporaryDirectory(prefix="dogy-setup-test-") as temporary:
        base = Path(temporary)
        run_case(base, "old-default-upgrades", expected="1.1.1", updates=1)
        run_case(base, "previous-analysis-upgrades", old="1.1.0", expected="1.1.1", updates=1)
        run_case(base, "explicit-previous-analysis-kept", old="1.1.0", explicit=True, expected="1.1.0")
        run_case(base, "current-default-kept", old="1.1.1", expected="1.1.1")
        run_case(base, "newer-default-kept", old="1.2.0", expected="1.2.0")
        run_case(base, "offline-old-kept", offline=True, expected="1.0.2", updates=1)
        run_case(base, "offline-current-kept", old="1.1.1", offline=True, force=True,
                 expected="1.1.1", updates=1)
        run_case(base, "explicit-old-kept", explicit=True, expected="1.0.2")
        run_case(base, "explicit-invalid-fails", old="", explicit=True)
        run_case(base, "explicit-force-kept", explicit=True, force=True, expected="1.0.2")
        run_case(base, "missing-default-installs", old="", expected="1.1.1", updates=1)
        run_case(base, "missing-offline-fails", old="", offline=True, updates=1)
        run_case(base, "old-latest-limits", release="1.0.3", expected="1.0.3", updates=1)
        run_case(base, "force-newer-no-downgrade", old="1.2.0", force=True,
                 expected="1.2.0", updates=1)


if __name__ == "__main__":
    main()
