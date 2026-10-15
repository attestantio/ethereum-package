"""Import the hyphenated tool scripts in this directory as modules, for tests."""

import importlib.util
import pathlib


def load(script):
    path = pathlib.Path(__file__).resolve().parent / script
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
