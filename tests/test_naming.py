import unittest
from check_naming import has_old_name


class NamingTest(unittest.TestCase):
    def test_product_names(self):
        for text in ("# fixit", "Use fixit to correct typos", "fixit shell helper"):
            self.assertTrue(has_old_name(text), text)

    def test_internal_names(self):
        for text in ("src/fixit.zsh", "fixit-common.sh", "FIXIT_HOME", "~/.local/share/fixit", "# >>> fixit.zsh >>>"):
            self.assertFalse(has_old_name(text), text)
