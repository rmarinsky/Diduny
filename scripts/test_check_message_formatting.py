"""The lightweight formatter check must honor the selected Apple toolchain."""
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch


class SelectedToolchainTests(unittest.TestCase):
    def test_uses_selected_compiler_and_macos_sdk_without_overriding_environment(self):
        selected_compiler = '/Selected Xcode/usr/bin/swiftc'
        selected_sdk = '/Selected Xcode/SDKs/MacOSX.sdk'
        with patch('subprocess.check_output', side_effect=[selected_compiler + '\n', selected_sdk + '\n']) as resolve, patch('subprocess.run') as run:
            runpy.run_path(str(Path(__file__).with_name('check-message-formatting.py')))
        self.assertEqual(resolve.call_count, 2, "Resolve the selected compiler and SDK")
        self.assertEqual(resolve.call_args_list[0].args[0], ['xcrun', '--find', 'swiftc'])
        self.assertEqual(resolve.call_args_list[1].args[0], ['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
        compile_call = run.call_args_list[0]
        command = compile_call.args[0]
        self.assertEqual(command[0], selected_compiler)
        self.assertEqual(command[command.index('-sdk') + 1], selected_sdk)
        self.assertNotIn('env', compile_call.kwargs)


if __name__ == '__main__':
    unittest.main()
