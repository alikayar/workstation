"""Synthetic stdio peer for client rejection, deadline and recovery contracts."""
import json
import sys


def send(value):
    print(json.dumps(value), flush=True)


for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request['method']
    if method == 'fixture/no-response':
        continue
    if method == 'fixture/callback':
        send({'jsonrpc': '2.0', 'id': 900, 'method': 'sampling/createMessage', 'params': {}})
        answer = json.loads(sys.stdin.readline())
        result = {'callback_rejected': answer.get('error', {}).get('code') == -32601}
    elif method == 'fixture/roots':
        send({'jsonrpc': '2.0', 'id': 901, 'method': 'roots/list', 'params': {}})
        result = json.loads(sys.stdin.readline())['result']
    elif method == 'tools/call' and request['params']['name'] == 'reject':
        result = {'isError': True, 'content': [{'type': 'text', 'text': 'Known fixture tool failure'}]}
    else:
        result = {'content': [{'type': 'text', 'text': 'Fixture recovered'}]}
    send({'jsonrpc': '2.0', 'id': request['id'], 'result': result})
