# test_yappr_paths.py — tests for bin/_yappr_paths.py path resolution.
from pathlib import Path
import _yappr_paths as P


def test_config_home_is_path():
    assert isinstance(P.config_home(), Path)


def test_state_home_is_path():
    assert isinstance(P.state_home(), Path)


def test_runtime_dir_is_path():
    assert isinstance(P.runtime_dir(), Path)


def test_data_home_is_path():
    assert isinstance(P.data_home(), Path)


def test_config_home_respects_env(monkeypatch, tmp_path):
    monkeypatch.setenv("YAPPR_CONFIG_HOME", str(tmp_path / "cfg"))
    assert P.config_home() == tmp_path / "cfg"


def test_state_home_respects_env(monkeypatch, tmp_path):
    monkeypatch.setenv("YAPPR_STATE_HOME", str(tmp_path / "state"))
    assert P.state_home() == tmp_path / "state"


def test_runtime_dir_respects_env(monkeypatch, tmp_path):
    monkeypatch.setenv("YAPPR_RUNTIME_DIR", str(tmp_path / "rt"))
    assert P.runtime_dir() == tmp_path / "rt"


def test_root_is_repo_root():
    root = P.root()
    assert (root / "bin" / "yappr").exists(), f"expected repo root, got {root}"
    assert (root / "VERSION").exists()
