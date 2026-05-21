import sys
import os

# Add bin/ to path so tests can import _yappr_paths directly
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../bin"))
