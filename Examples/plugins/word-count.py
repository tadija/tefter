#!/usr/bin/env python3
"""Tefter protocol v1 example. No network, shell, or workspace access needed."""
import json
import sys

request = json.load(sys.stdin)
valid = request.get('version') == 1 and request.get('point') in ('command', 'hook') and request.get('name') == 'word-count'
print(json.dumps({'version': 1, 'id': request['id'], 'ok': valid,
                  'text': str(len(request.get('text', '').split())) if valid else 'Unsupported request'}))
