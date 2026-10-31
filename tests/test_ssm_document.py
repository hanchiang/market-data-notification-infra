"""The session document stays a fixed-port, stdio-mode Port document.

`"type": "LocalPortForwarding"` would make the Session Manager plugin open a local
listener, and every SSH ProxyCommand would hang; a parameter would let the caller choose
the port again."""
import json
import unittest

from support import REPO

DOCUMENT = REPO / 'instances' / 'ssm' / 'MarketDataNotification-SSH22.json'


class SessionDocumentTest(unittest.TestCase):
    def test_port_fixed_at_22_with_no_parameters_and_no_listener_type(self):
        document = json.loads(DOCUMENT.read_text())
        self.assertEqual(document['sessionType'], 'Port')
        self.assertEqual(document['properties'], {'portNumber': '22'})
        self.assertNotIn('parameters', document)
        self.assertEqual(set(document), {'schemaVersion', 'description', 'sessionType', 'properties'})

    def test_terraform_loads_this_file(self):
        access = (REPO / 'instances' / 'access.tf').read_text()
        self.assertIn('file("${path.module}/ssm/MarketDataNotification-SSH22.json")', access)


if __name__ == '__main__':
    unittest.main()
